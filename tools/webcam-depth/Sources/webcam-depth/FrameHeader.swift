import Foundation

/// Fixed 48-byte little-endian header that starts every frame on the wire.
///
/// Layout (byte offset, size, field):
/// - 0, 4: magic `AMGD` (bytes 0x41 0x4D 0x47 0x44)
/// - 4, 2: wire version, currently 1
/// - 6, 2: header length in bytes, currently 48
/// - 8, 4: frame sequence number
/// - 12, 8: capture time, microseconds since the Unix epoch
/// - 20, 8: send time, microseconds since the Unix epoch
/// - 28, 2: width in pixels
/// - 30, 2: height in pixels
/// - 32, 1: mask format, 1 = one unsigned byte per pixel (0..255 person confidence)
/// - 33, 1: depth format, 1 = one float32 per pixel (relative depth, larger = closer)
/// - 34, 2: reserved, zero
/// - 36, 4: mask plane length in bytes
/// - 40, 4: depth plane length in bytes
/// - 44, 4: reserved, zero
///
/// The mask plane follows the header. The depth plane follows the mask plane.
/// Both planes are row-major, top row first.
///
/// Written by Claude Code; conversation transcript:
/// llm/transcripts/transcript_2026-10-20_06-06_cf6a8f39-437b-4cd7-9962-fcfbb1efa030.md
enum FrameHeader {
    static let magic: [UInt8] = [0x41, 0x4D, 0x47, 0x44]
    static let version: UInt16 = 1
    static let length = 48
    static let maskFormatUInt8: UInt8 = 1
    static let depthFormatFloat32: UInt8 = 1

    /// Writes the header into the first 48 bytes of `buffer`.
    static func write(
        into buffer: UnsafeMutableRawBufferPointer,
        sequence: UInt32,
        captureMicros: Int64,
        sendMicros: Int64,
        width: Int,
        height: Int,
        maskBytes: Int,
        depthBytes: Int
    ) {
        precondition(buffer.count >= length)
        buffer[0] = magic[0]; buffer[1] = magic[1]; buffer[2] = magic[2]; buffer[3] = magic[3]
        buffer.storeBytes(of: version.littleEndian, toByteOffset: 4, as: UInt16.self)
        buffer.storeBytes(of: UInt16(length).littleEndian, toByteOffset: 6, as: UInt16.self)
        buffer.storeBytes(of: sequence.littleEndian, toByteOffset: 8, as: UInt32.self)
        buffer.storeBytes(of: captureMicros.littleEndian, toByteOffset: 12, as: Int64.self)
        buffer.storeBytes(of: sendMicros.littleEndian, toByteOffset: 20, as: Int64.self)
        buffer.storeBytes(of: UInt16(width).littleEndian, toByteOffset: 28, as: UInt16.self)
        buffer.storeBytes(of: UInt16(height).littleEndian, toByteOffset: 30, as: UInt16.self)
        buffer[32] = maskFormatUInt8
        buffer[33] = depthFormatFloat32
        buffer.storeBytes(of: UInt16(0), toByteOffset: 34, as: UInt16.self)
        buffer.storeBytes(of: UInt32(maskBytes).littleEndian, toByteOffset: 36, as: UInt32.self)
        buffer.storeBytes(of: UInt32(depthBytes).littleEndian, toByteOffset: 40, as: UInt32.self)
        buffer.storeBytes(of: UInt32(0), toByteOffset: 44, as: UInt32.self)
    }
}

/// Builds complete wire frames (header + mask plane + depth plane) into one reusable buffer.
///
/// Written by Claude Code; conversation transcript:
/// llm/transcripts/transcript_2026-10-20_06-06_cf6a8f39-437b-4cd7-9962-fcfbb1efa030.md
final class FrameEncoder {
    let width: Int
    let height: Int
    private var sequence: UInt32 = 0

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// Returns a new `Data` that holds one full frame. `depth` values are written as little-endian float32.
    func encode(mask: [UInt8], depth: [Float], captureMicros: Int64) -> Data {
        let pixels = width * height
        precondition(mask.count == pixels && depth.count == pixels)
        let maskBytes = pixels
        let depthBytes = pixels * MemoryLayout<Float>.size
        var data = Data(count: FrameHeader.length + maskBytes + depthBytes)
        let seq = sequence
        sequence &+= 1
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            FrameHeader.write(
                into: raw,
                sequence: seq,
                captureMicros: captureMicros,
                sendMicros: Clock.nowMicros(),
                width: width,
                height: height,
                maskBytes: maskBytes,
                depthBytes: depthBytes
            )
            mask.withUnsafeBytes { src in
                raw.baseAddress!.advanced(by: FrameHeader.length).copyMemory(from: src.baseAddress!, byteCount: maskBytes)
            }
            // Apple Silicon is little-endian, so a raw copy of the float plane is already in wire order.
            depth.withUnsafeBytes { src in
                raw.baseAddress!.advanced(by: FrameHeader.length + maskBytes).copyMemory(from: src.baseAddress!, byteCount: depthBytes)
            }
        }
        return data
    }
}

/// Wall-clock helpers shared by the capture and send paths.
///
/// Written by Claude Code; conversation transcript:
/// llm/transcripts/transcript_2026-10-20_06-06_cf6a8f39-437b-4cd7-9962-fcfbb1efa030.md
enum Clock {
    /// Microseconds since the Unix epoch.
    static func nowMicros() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000_000).rounded())
    }
}
