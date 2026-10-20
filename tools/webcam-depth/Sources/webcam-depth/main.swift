import AVFoundation
import CoreMedia
import Foundation
import Vision

// Entry point of the webcam-depth sidecar.
//
// Written by Claude Code; conversation transcript:
// llm/transcripts/transcript_2026-10-20_06-06_cf6a8f39-437b-4cd7-9962-fcfbb1efa030.md
// Written by Claude Code; conversation transcript:
// llm/transcripts/transcript_2026-10-20_07-18_eb73890b-4f17-4ace-abdd-6dda67cd169b.md

/// Name of the Syphon server. TouchDesigner lists it as "webcam-depth - webcam-depth" (app name, then server name).
let syphonServerName = "webcam-depth"

/// Command-line options with their defaults.
///
/// Written by Claude Code; conversation transcript:
/// llm/transcripts/transcript_2026-10-20_06-06_cf6a8f39-437b-4cd7-9962-fcfbb1efa030.md
/// Written by Claude Code; conversation transcript:
/// llm/transcripts/transcript_2026-10-20_07-18_eb73890b-4f17-4ace-abdd-6dda67cd169b.md
struct Options {
    var camera = "C920"
    var width = 518
    var height = 392
    var alpha: Float = 0.5
    var quality: VNGeneratePersonSegmentationRequest.QualityLevel = .balanced
    var model: String = {
        // Default: models/DepthAnythingV2SmallF16.mlpackage next to this package.
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return packageRoot.appendingPathComponent("models/DepthAnythingV2SmallF16.mlpackage").path
    }()
    var listCameras = false
    var listFormats = false

    static let usage = """
    usage: webcam-depth [options]
      --camera <name fragment>   camera to open, matched against the device name (default: C920)
      --size <w>x<h>             published texture size (default: 518x392, the model's native size)
      --alpha <0..1>             EMA weight of the newest depth frame; 1 disables smoothing (default: 0.5)
      --quality fast|balanced|accurate   Vision person segmentation quality (default: balanced)
      --model <path>             .mlpackage or .mlmodelc to use for depth
      --list-cameras             print the cameras macOS can see and exit
      --list-formats             print the formats of the chosen camera and exit
      --help                     print this text
    """

    static func parse(_ args: [String]) throws -> Options {
        var o = Options()
        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < args.count else { throw OptionError.missingValue(flag) }
            return args[i]
        }
        while i < args.count {
            let a = args[i]
            switch a {
            case "--camera": o.camera = try value(a)
            case "--size":
                let parts = try value(a).lowercased().split(separator: "x")
                guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0, w < 65536, h < 65536 else {
                    throw OptionError.badValue(a)
                }
                o.width = w; o.height = h
            case "--alpha":
                guard let f = Float(try value(a)), f > 0, f <= 1 else { throw OptionError.badValue(a) }
                o.alpha = f
            case "--quality":
                switch try value(a) {
                case "fast": o.quality = .fast
                case "balanced": o.quality = .balanced
                case "accurate": o.quality = .accurate
                default: throw OptionError.badValue(a)
                }
            case "--model": o.model = try value(a)
            case "--list-cameras": o.listCameras = true
            case "--list-formats": o.listFormats = true
            case "--help", "-h":
                print(usage)
                exit(0)
            default:
                throw OptionError.unknown(a)
            }
            i += 1
        }
        return o
    }
}

/// Errors raised while parsing the command line.
///
/// Written by Claude Code; conversation transcript:
/// llm/transcripts/transcript_2026-10-20_06-06_cf6a8f39-437b-4cd7-9962-fcfbb1efa030.md
/// Written by Claude Code; conversation transcript:
/// llm/transcripts/transcript_2026-10-20_07-18_eb73890b-4f17-4ace-abdd-6dda67cd169b.md
enum OptionError: Error, CustomStringConvertible {
    case missingValue(String)
    case badValue(String)
    case unknown(String)

    var description: String {
        switch self {
        case .missingValue(let f): return "\(f) needs a value"
        case .badValue(let f): return "bad value for \(f)"
        case .unknown(let f): return "unknown option \(f)"
        }
    }
}

func run() -> Int32 {
    let options: Options
    do {
        options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
    } catch {
        Log.line("\(error)")
        print(Options.usage)
        return 2
    }

    if options.listCameras {
        for d in Camera.devices() {
            print("\(d.localizedName)  [\(d.uniqueID)]")
        }
        return 0
    }

    guard Camera.requestAccess() else {
        Log.line("camera access denied. Allow it in System Settings > Privacy & Security > Camera.")
        return 1
    }
    guard let device = Camera.device(matching: options.camera) else {
        Log.line("no camera matches \"\(options.camera)\". Cameras: \(Camera.devices().map(\.localizedName).joined(separator: ", "))")
        return 1
    }

    if options.listFormats {
        for f in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let rates = f.videoSupportedFrameRateRanges.map { String(format: "%.0f", $0.maxFrameRate) }.joined(separator: ",")
            print("\(dims.width)x\(dims.height) \(f.formatDescription.mediaSubType) fps \(rates)")
        }
        return 0
    }

    let pipeline: DepthPipeline
    let camera: Camera
    do {
        Log.line("loading model \(options.model)")
        pipeline = try DepthPipeline(modelURL: URL(fileURLWithPath: options.model), width: options.width, height: options.height, alpha: options.alpha, quality: options.quality)
        camera = try Camera(device: device)
    } catch {
        Log.line("startup failed: \(error)")
        return 1
    }

    let publisher: SyphonPublisher
    do {
        publisher = try SyphonPublisher(name: syphonServerName, width: options.width, height: options.height)
    } catch {
        Log.line("Syphon setup failed: \(error)")
        return 1
    }

    // Per-second statistics, updated on the capture queue only.
    var captured = 0
    var processed = 0
    var inferenceTotal = 0.0
    var segmentationTotal = 0.0
    var depthTotal = 0.0
    var lastReport = Date()
    var lastPublished = 0

    camera.onFrame = { pixelBuffer, _ in
        captured += 1
        do {
            let frame = try pipeline.process(pixelBuffer)
            processed += 1
            inferenceTotal += frame.inferenceMillis
            segmentationTotal += frame.segmentationMillis
            depthTotal += frame.depthMillis
            try publisher.publish(mask: frame.mask, depth: frame.depth)
        } catch {
            Log.line("frame failed: \(error)")
        }
        let now = Date()
        let dt = now.timeIntervalSince(lastReport)
        if dt >= 1 {
            let fps = Double(processed) / dt
            let n = Double(max(processed, 1))
            let published = publisher.publishedFrames - lastPublished
            Log.line(String(format: "%.1f fps | infer %.1f ms (mask %.1f + depth %.1f) | published %d | %@",
                            fps, inferenceTotal / n, segmentationTotal / n, depthTotal / n, published,
                            publisher.hasClients ? "clients attached" : "no clients"))
            captured = 0; processed = 0; inferenceTotal = 0; segmentationTotal = 0; depthTotal = 0; lastReport = now; lastPublished = publisher.publishedFrames
        }
    }

    Log.line("camera \(device.localizedName), Syphon server \"\(syphonServerName)\" \(options.width)x\(options.height) BGRA8 (red mask, green depth), alpha \(options.alpha)")
    camera.start()
    // Retire the Syphon server on Ctrl-C so clients see it go instead of waiting on a dead one.
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    interrupt.setEventHandler {
        Log.line("stopping")
        publisher.stop()
        exit(0)
    }
    interrupt.activate()
    // dispatchMain never returns. Keep the camera, pipeline and publisher alive for the life of
    // the process; Swift would otherwise release them right after their last use above.
    withExtendedLifetime((camera, pipeline, publisher, interrupt)) {
        dispatchMain()
    }
}

exit(run())
