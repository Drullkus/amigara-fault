import Accelerate
import CoreML
import CoreVideo
import Foundation
import Vision

/// One processed frame: a person mask and a smoothed relative depth map at the output size.
///
/// Written by Claude Code; conversation transcript:
/// llm/transcripts/transcript_2026-10-20_06-06_cf6a8f39-437b-4cd7-9962-fcfbb1efa030.md
struct ProcessedFrame {
    /// Person confidence, 0..255, one byte per pixel, row-major.
    var mask: [UInt8]
    /// Relative depth, 0..1, larger = closer, one float per pixel, row-major.
    var depth: [Float]
    /// Time spent in Vision + Core ML for this frame, in milliseconds.
    var inferenceMillis: Double
    /// Part of `inferenceMillis` spent in person segmentation.
    var segmentationMillis: Double
    /// Part of `inferenceMillis` spent in the depth model.
    var depthMillis: Double
}

/// Runs Vision person segmentation and Depth Anything V2 on each camera frame, then smooths depth with an EMA.
///
/// Written by Claude Code; conversation transcript:
/// llm/transcripts/transcript_2026-10-20_06-06_cf6a8f39-437b-4cd7-9962-fcfbb1efa030.md
final class DepthPipeline {
    let width: Int
    let height: Int
    /// EMA weight of the newest frame. 1 disables smoothing.
    let alpha: Float

    private let depthRequest: VNCoreMLRequest
    private let segmentationRequest: VNGeneratePersonSegmentationRequest
    private let depthQueue = DispatchQueue(label: "webcam-depth.depth", qos: .userInteractive)
    private var smoothed: [Float]?
    private var scratchDepth: [Float]
    private var scratchMask: [UInt8]

    /// Loads the Core ML model at `modelURL` (an `.mlpackage` or an already compiled `.mlmodelc`).
    /// A compiled copy is cached next to the package so later starts are fast.
    init(modelURL: URL, width: Int, height: Int, alpha: Float, quality: VNGeneratePersonSegmentationRequest.QualityLevel) throws {
        self.width = width
        self.height = height
        self.alpha = alpha
        self.scratchDepth = [Float](repeating: 0, count: width * height)
        self.scratchMask = [UInt8](repeating: 0, count: width * height)

        let compiledURL = try DepthPipeline.compiledModelURL(for: modelURL)
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine  // Keep depth on the Neural Engine; with .all Core ML moved it to the GPU after about 30 s and it slowed from 32 ms to 80 ms.
        let model = try MLModel(contentsOf: compiledURL, configuration: config)
        let visionModel = try VNCoreMLModel(for: model)
        depthRequest = VNCoreMLRequest(model: visionModel)
        depthRequest.imageCropAndScaleOption = .scaleFill

        segmentationRequest = VNGeneratePersonSegmentationRequest()
        segmentationRequest.qualityLevel = quality
        segmentationRequest.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    /// Runs both requests on `pixelBuffer` and returns the mask and the smoothed depth.
    func process(_ pixelBuffer: CVPixelBuffer) throws -> ProcessedFrame {
        // The depth model runs on the Neural Engine and the segmentation mostly on the GPU, so the
        // two requests overlap well. Run depth on a second thread and wait for both.
        let started = DispatchTime.now().uptimeNanoseconds
        var depthError: Error?
        var depthNanos: UInt64 = 0
        let group = DispatchGroup()
        depthQueue.async(group: group) { [depthRequest] in
            let t0 = DispatchTime.now().uptimeNanoseconds
            do {
                try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:]).perform([depthRequest])
            } catch {
                depthError = error
            }
            depthNanos = DispatchTime.now().uptimeNanoseconds - t0
        }
        let segmentationStarted = DispatchTime.now().uptimeNanoseconds
        try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:]).perform([segmentationRequest])
        let segmentationMillis = Double(DispatchTime.now().uptimeNanoseconds - segmentationStarted) / 1_000_000
        group.wait()
        if let depthError { throw depthError }
        let depthMillis = Double(depthNanos) / 1_000_000
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000

        guard let maskBuffer = (segmentationRequest.results?.first as? VNPixelBufferObservation)?.pixelBuffer else {
            throw PipelineError.noResult("person segmentation")
        }
        guard let depthBuffer = (depthRequest.results?.first as? VNPixelBufferObservation)?.pixelBuffer else {
            throw PipelineError.noResult("depth")
        }

        try DepthPipeline.copyMask(from: maskBuffer, into: &scratchMask, width: width, height: height)
        try DepthPipeline.copyDepth(from: depthBuffer, into: &scratchDepth, width: width, height: height)

        if var previous = smoothed, alpha < 1 {
            // previous = alpha * current + (1 - alpha) * previous
            var a = alpha
            var b = 1 - alpha
            let n = vDSP_Length(previous.count)
            scratchDepth.withUnsafeBufferPointer { cur in
                previous.withUnsafeMutableBufferPointer { prev in
                    vDSP_vsmsma(cur.baseAddress!, 1, &a, prev.baseAddress!, 1, &b, prev.baseAddress!, 1, n)
                }
            }
            smoothed = previous
        } else {
            smoothed = scratchDepth
        }

        return ProcessedFrame(mask: scratchMask, depth: smoothed!, inferenceMillis: elapsed, segmentationMillis: segmentationMillis, depthMillis: depthMillis)
    }

    // MARK: - Pixel buffer conversion

    /// Scales a one-byte-per-pixel mask to the output size.
    private static func copyMask(from buffer: CVPixelBuffer, into out: inout [UInt8], width: Int, height: Int) throws {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else {
            throw PipelineError.unexpectedFormat("mask", CVPixelBufferGetPixelFormatType(buffer))
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var src = vImage_Buffer(
            data: CVPixelBufferGetBaseAddress(buffer),
            height: vImagePixelCount(CVPixelBufferGetHeight(buffer)),
            width: vImagePixelCount(CVPixelBufferGetWidth(buffer)),
            rowBytes: CVPixelBufferGetBytesPerRow(buffer)
        )
        try out.withUnsafeMutableBufferPointer { dstPtr in
            var dst = vImage_Buffer(data: dstPtr.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
            let err = vImageScale_Planar8(&src, &dst, nil, vImage_Flags(kvImageNoFlags))
            if err != kvImageNoError { throw PipelineError.vImage(err) }
        }
    }

    /// Converts the model's depth image (BGRA, 8-bit gray, half or float planar) to float 0..1 at the output size.
    private static func copyDepth(from buffer: CVPixelBuffer, into out: inout [Float], width: Int, height: Int) throws {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let srcW = CVPixelBufferGetWidth(buffer)
        let srcH = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let format = CVPixelBufferGetPixelFormatType(buffer)

        // Step 1: get a planar float image at the source size.
        var planar = [Float](repeating: 0, count: srcW * srcH)
        try planar.withUnsafeMutableBufferPointer { dstPtr in
            var dst = vImage_Buffer(data: dstPtr.baseAddress, height: vImagePixelCount(srcH), width: vImagePixelCount(srcW), rowBytes: srcW * 4)
            switch format {
            case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB, kCVPixelFormatType_32RGBA:
                // The Core ML image output stores the same gray value in every color channel. Read one channel.
                let channel = format == kCVPixelFormatType_32ARGB ? 1 : 0
                for y in 0..<srcH {
                    let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                    let dstRow = dstPtr.baseAddress!.advanced(by: y * srcW)
                    for x in 0..<srcW {
                        dstRow[x] = Float(row[x * 4 + channel]) * (1.0 / 255.0)
                    }
                }
            case kCVPixelFormatType_OneComponent8:
                var src = vImage_Buffer(data: base, height: vImagePixelCount(srcH), width: vImagePixelCount(srcW), rowBytes: rowBytes)
                let err = vImageConvert_Planar8toPlanarF(&src, &dst, 1, 0, vImage_Flags(kvImageNoFlags))
                if err != kvImageNoError { throw PipelineError.vImage(err) }
            case kCVPixelFormatType_OneComponent16Half, kCVPixelFormatType_DepthFloat16, kCVPixelFormatType_DisparityFloat16:
                var src = vImage_Buffer(data: base, height: vImagePixelCount(srcH), width: vImagePixelCount(srcW), rowBytes: rowBytes)
                let err = vImageConvert_Planar16FtoPlanarF(&src, &dst, vImage_Flags(kvImageNoFlags))
                if err != kvImageNoError { throw PipelineError.vImage(err) }
            case kCVPixelFormatType_OneComponent32Float, kCVPixelFormatType_DepthFloat32, kCVPixelFormatType_DisparityFloat32:
                for y in 0..<srcH {
                    let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
                    dstPtr.baseAddress!.advanced(by: y * srcW).update(from: row, count: srcW)
                }
            default:
                throw PipelineError.unexpectedFormat("depth", format)
            }
        }

        // Step 2: scale to the output size when the model size differs from the requested size.
        if srcW == width && srcH == height {
            out = planar
        } else {
            try planar.withUnsafeMutableBufferPointer { srcPtr in
                try out.withUnsafeMutableBufferPointer { dstPtr in
                    var src = vImage_Buffer(data: srcPtr.baseAddress, height: vImagePixelCount(srcH), width: vImagePixelCount(srcW), rowBytes: srcW * 4)
                    var dst = vImage_Buffer(data: dstPtr.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                    let err = vImageScale_PlanarF(&src, &dst, nil, vImage_Flags(kvImageNoFlags))
                    if err != kvImageNoError { throw PipelineError.vImage(err) }
                }
            }
        }
    }

    // MARK: - Model compilation cache

    private static func compiledModelURL(for modelURL: URL) throws -> URL {
        if modelURL.pathExtension == "mlmodelc" {
            return modelURL
        }
        let cacheURL = modelURL.deletingPathExtension().appendingPathExtension("mlmodelc")
        let fm = FileManager.default
        if fm.fileExists(atPath: cacheURL.path), try isNewer(cacheURL, than: modelURL) {
            return cacheURL
        }
        let tmp = try MLModel.compileModel(at: modelURL)
        if fm.fileExists(atPath: cacheURL.path) {
            try fm.removeItem(at: cacheURL)
        }
        try fm.moveItem(at: tmp, to: cacheURL)
        return cacheURL
    }

    private static func isNewer(_ a: URL, than b: URL) throws -> Bool {
        let fm = FileManager.default
        let da = try fm.attributesOfItem(atPath: a.path)[.modificationDate] as? Date ?? .distantPast
        let db = try fm.attributesOfItem(atPath: b.appendingPathComponent("Data/com.apple.CoreML/model.mlmodel").path)[.modificationDate] as? Date ?? .distantFuture
        return da >= db
    }
}

/// Errors raised by the processing pipeline.
///
/// Written by Claude Code; conversation transcript:
/// llm/transcripts/transcript_2026-10-20_06-06_cf6a8f39-437b-4cd7-9962-fcfbb1efa030.md
enum PipelineError: Error, CustomStringConvertible {
    case noResult(String)
    case unexpectedFormat(String, OSType)
    case vImage(vImage_Error)

    var description: String {
        switch self {
        case .noResult(let what): return "no \(what) result from Vision"
        case .unexpectedFormat(let what, let type): return "unexpected \(what) pixel format \(String(format: "0x%08x", type))"
        case .vImage(let code): return "vImage error \(code)"
        }
    }
}
