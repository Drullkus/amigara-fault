import AVFoundation
import CoreMedia
import Foundation

/// Opens one webcam and delivers BGRA pixel buffers with a wall-clock capture time.
///
/// Written by Claude Code; conversation transcript:
/// llm/transcripts/transcript_2026-10-20_06-06_cf6a8f39-437b-4cd7-9962-fcfbb1efa030.md
final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Called on the capture queue for every frame. The second value is the capture time in microseconds since the Unix epoch.
    var onFrame: ((CVPixelBuffer, Int64) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "webcam-depth.capture", qos: .userInteractive)
    private let output = AVCaptureVideoDataOutput()
    private let device: AVCaptureDevice

    /// Lists every video device macOS can see, in discovery order.
    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    /// Finds the first device whose localized name contains `nameFragment` (case-insensitive).
    static func device(matching nameFragment: String) -> AVCaptureDevice? {
        devices().first { $0.localizedName.localizedCaseInsensitiveContains(nameFragment) }
    }

    /// Asks macOS for camera access and blocks until the user answers. Returns true when access is granted.
    static func requestAccess() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .video) { ok in
                granted = ok
                semaphore.signal()
            }
            semaphore.wait()
            return granted
        case .denied:
            Log.line("camera access is denied for this process (TCC status: denied)")
            return false
        case .restricted:
            Log.line("camera access is restricted by policy (TCC status: restricted)")
            return false
        @unknown default:
            return false
        }
    }

    /// Picks the device format closest to `preferredWidth` x `preferredHeight` that can run at `preferredFPS`, and locks the frame rate.
    private static func selectFormat(on device: AVCaptureDevice, preferredWidth: Int32, preferredHeight: Int32, preferredFPS: Double) throws {
        var best: (format: AVCaptureDevice.Format, range: AVFrameRateRange)?
        var bestScore = Int32.max
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            // Take the slowest range that still reaches the preferred rate, so the camera is not pushed past it.
            let candidates = format.videoSupportedFrameRateRanges.filter { $0.maxFrameRate >= preferredFPS - 0.01 }
            guard let range = candidates.min(by: { $0.maxFrameRate < $1.maxFrameRate }) else { continue }
            // Prefer uncompressed or YUV formats over MJPEG so no decode step is needed.
            let subType = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            let penalty: Int32 = subType == kCMVideoCodecType_JPEG ? 10_000 : 0
            let score = abs(dims.width - preferredWidth) + abs(dims.height - preferredHeight) + penalty
            if score < bestScore {
                bestScore = score
                best = (format, range)
            }
        }
        guard let chosen = best else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = chosen.format
        // Use the range's own durations; the device rejects a hand-built 1/30 that is not exactly in a range.
        device.activeVideoMinFrameDuration = chosen.range.minFrameDuration
        device.activeVideoMaxFrameDuration = chosen.range.minFrameDuration
    }

    init(device: AVCaptureDevice) throws {
        self.device = device
        super.init()
        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CameraError.cannotAddInput(device.localizedName)
        }
        session.addInput(input)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            throw CameraError.cannotAddOutput
        }
        session.addOutput(output)
        session.commitConfiguration()
    }

    private var frameCount = 0
    private var droppedCount = 0

    func start() {
        NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            Log.line("capture session runtime error: \(error?.localizedDescription ?? "unknown")")
        }
        NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { note in
            Log.line("capture session interrupted: \(note.userInfo ?? [:])")
        }
        session.startRunning()
        // On macOS the session preset picks the device format when the session starts, so the
        // preferred format must be applied after that.
        do {
            try Camera.selectFormat(on: device, preferredWidth: 640, preferredHeight: 480, preferredFPS: 30)
        } catch {
            Log.line("could not set the camera format: \(error)")
        }
        Log.line("capture session running: \(session.isRunning); format: \(formatDescription)")
        // Watchdog: say so when the camera goes quiet.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        var lastSeen = 0
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.frameCount == lastSeen {
                Log.line("no camera frames in the last 3 s (total \(self.frameCount), dropped \(self.droppedCount))")
            }
            lastSeen = self.frameCount
        }
        timer.activate()
        watchdog = timer
    }

    private var watchdog: DispatchSourceTimer?

    private var formatDescription: String {
        guard let input = session.inputs.first as? AVCaptureDeviceInput else { return "none" }
        let f = input.device.activeFormat
        let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        let fps = input.device.activeVideoMinFrameDuration.seconds > 0 ? 1 / input.device.activeVideoMinFrameDuration.seconds : 0
        return "\(dims.width)x\(dims.height) @ \(fps) fps, \(f.formatDescription.mediaSubType)"
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        droppedCount += 1
    }

    func stop() {
        session.stopRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameCount += 1
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // The presentation time stamp is on the host clock. Convert it to wall time so the
        // receiver can subtract it from its own wall clock to get end-to-end latency.
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let wallNow = Date().timeIntervalSince1970
        let captureWall = wallNow - (hostNow - pts)
        onFrame?(pixelBuffer, Int64((captureWall * 1_000_000).rounded()))
    }
}

/// Errors raised while opening a camera.
///
/// Written by Claude Code; conversation transcript:
/// llm/transcripts/transcript_2026-10-20_06-06_cf6a8f39-437b-4cd7-9962-fcfbb1efa030.md
enum CameraError: Error, CustomStringConvertible {
    case cannotAddInput(String)
    case cannotAddOutput

    var description: String {
        switch self {
        case .cannotAddInput(let name): return "cannot use camera \(name) as a capture input"
        case .cannotAddOutput: return "cannot add a video data output to the capture session"
        }
    }
}
