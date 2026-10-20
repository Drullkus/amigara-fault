import Accelerate
import Foundation
import Metal
import Syphon

/// Publishes each processed frame as one BGRA8 Metal texture on a Syphon server.
///
/// Channel layout of the published texture (Syphon's Metal path is 8 bits per channel):
/// - red: person mask, 0..255
/// - green: relative depth, 0..255, larger = closer
/// - blue: 0
/// - alpha: 255
///
/// Rows run top to bottom, so the texture is published with `flipped: false`.
///
/// Written by Claude Code; conversation transcript:
/// llm/transcripts/transcript_2026-10-20_07-18_eb73890b-4f17-4ace-abdd-6dda67cd169b.md
final class SyphonPublisher {
    let name: String
    let width: Int
    let height: Int

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let server: SyphonMetalServer
    /// Two textures in rotation: the GPU may still copy one while the CPU fills the other.
    private let textures: [MTLTexture]
    private let inFlight: DispatchSemaphore
    private var next = 0

    // Planar scratch buffers for the BGRA interleave.
    private var depthScaled: [Float]
    private var depth8: [UInt8]
    private var zeros: [UInt8]
    private var opaque: [UInt8]
    private var pixels: [UInt8]

    private(set) var publishedFrames = 0
    var hasClients: Bool { server.hasClients }

    init(name: String, width: Int, height: Int) throws {
        self.name = name
        self.width = width
        self.height = height
        guard let device = MTLCreateSystemDefaultDevice() else { throw PublisherError.noMetalDevice }
        guard let queue = device.makeCommandQueue() else { throw PublisherError.noCommandQueue }
        // The Objective-C initializer is declared non-null but returns nil when Syphon cannot load
        // its Metal shader library, so test the raw pointer instead of an optional.
        let server = SyphonMetalServer(name: name, device: device, options: nil)
        guard unsafeBitCast(server, to: UInt.self) != 0 else {
            throw PublisherError.serverFailed(name)
        }
        self.device = device
        self.commandQueue = queue
        self.server = server

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        var textures: [MTLTexture] = []
        for _ in 0..<2 {
            guard let t = device.makeTexture(descriptor: descriptor) else { throw PublisherError.noTexture }
            textures.append(t)
        }
        self.textures = textures
        self.inFlight = DispatchSemaphore(value: textures.count)

        let count = width * height
        depthScaled = [Float](repeating: 0, count: count)
        depth8 = [UInt8](repeating: 0, count: count)
        zeros = [UInt8](repeating: 0, count: count)
        opaque = [UInt8](repeating: 255, count: count)
        pixels = [UInt8](repeating: 0, count: count * 4)
    }

    /// Packs `mask` and `depth` into the next texture and publishes it. Blocks only while both
    /// textures are still being copied by the GPU, which does not happen at camera rates.
    func publish(mask: [UInt8], depth: [Float]) throws {
        let count = width * height
        precondition(mask.count == count && depth.count == count)
        let n = vDSP_Length(count)

        // depth 0..1 -> 0..255, clipped, rounded to the nearest byte.
        var scale: Float = 255
        var low: Float = 0
        var high: Float = 255
        depth.withUnsafeBufferPointer { src in
            depthScaled.withUnsafeMutableBufferPointer { dst in
                vDSP_vsmul(src.baseAddress!, 1, &scale, dst.baseAddress!, 1, n)
                vDSP_vclip(dst.baseAddress!, 1, &low, &high, dst.baseAddress!, 1, n)
            }
        }
        depthScaled.withUnsafeBufferPointer { src in
            depth8.withUnsafeMutableBufferPointer { dst in
                vDSP_vfixru8(src.baseAddress!, 1, dst.baseAddress!, 1, n)
            }
        }

        // Interleave four planes. vImage writes them in argument order, so passing
        // (blue, green, red, alpha) gives BGRA bytes in memory.
        let w = vImagePixelCount(width)
        let h = vImagePixelCount(height)
        try pixels.withUnsafeMutableBufferPointer { dst in
            try mask.withUnsafeBufferPointer { maskPtr in
                try depth8.withUnsafeBufferPointer { depthPtr in
                    try zeros.withUnsafeBufferPointer { zeroPtr in
                        try opaque.withUnsafeBufferPointer { onePtr in
                            var blue = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: zeroPtr.baseAddress), height: h, width: w, rowBytes: width)
                            var green = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: depthPtr.baseAddress), height: h, width: w, rowBytes: width)
                            var red = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: maskPtr.baseAddress), height: h, width: w, rowBytes: width)
                            var alpha = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: onePtr.baseAddress), height: h, width: w, rowBytes: width)
                            var out = vImage_Buffer(data: dst.baseAddress, height: h, width: w, rowBytes: width * 4)
                            let err = vImageConvert_Planar8toARGB8888(&blue, &green, &red, &alpha, &out, vImage_Flags(kvImageNoFlags))
                            if err != kvImageNoError { throw PublisherError.vImage(err) }
                        }
                    }
                }
            }
        }

        inFlight.wait()
        let texture = textures[next]
        next = (next + 1) % textures.count
        pixels.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: width * 4)
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlight.signal()
            throw PublisherError.noCommandBuffer
        }
        server.publishFrameTexture(texture, on: commandBuffer, imageRegion: NSRect(x: 0, y: 0, width: width, height: height), flipped: false)
        commandBuffer.addCompletedHandler { [inFlight] _ in inFlight.signal() }
        commandBuffer.commit()
        publishedFrames += 1
    }

    /// Takes the server off the Syphon directory. Clients see it retire at once instead of timing out.
    func stop() {
        server.stop()
    }
}

/// Errors raised while setting up or feeding the Syphon server.
///
/// Written by Claude Code; conversation transcript:
/// llm/transcripts/transcript_2026-10-20_07-18_eb73890b-4f17-4ace-abdd-6dda67cd169b.md
enum PublisherError: Error, CustomStringConvertible {
    case noMetalDevice
    case noCommandQueue
    case noCommandBuffer
    case noTexture
    case serverFailed(String)
    case vImage(vImage_Error)

    var description: String {
        switch self {
        case .noMetalDevice: return "no Metal device"
        case .noCommandQueue: return "cannot make a Metal command queue"
        case .noCommandBuffer: return "cannot make a Metal command buffer"
        case .noTexture: return "cannot make the output texture"
        case .serverFailed(let name): return "cannot start the Syphon server \"\(name)\""
        case .vImage(let code): return "vImage error \(code)"
        }
    }
}
