import AppKit
import CoreImage
import Metal
import MetalKit
import Syphon

// A small Syphon client for checks without TouchDesigner. It opens one window, connects to the
// first Syphon server named "webcam-depth" (or the name given as the only argument), draws every
// frame it receives, and shows the texture size and frame rate in the window title.
//
// Written by Claude Code; conversation transcript:
// llm/transcripts/transcript_2026-10-20_07-18_eb73890b-4f17-4ace-abdd-6dda67cd169b.md

/// Draws the newest Syphon frame scaled to fit the view, with Core Image doing the resize.
///
/// Written by Claude Code; conversation transcript:
/// llm/transcripts/transcript_2026-10-20_07-18_eb73890b-4f17-4ace-abdd-6dda67cd169b.md
final class FrameView: MTKView {
    private let commandQueue: MTLCommandQueue
    private let context: CIContext
    private let lock = NSLock()
    private var texture: MTLTexture?

    init(device: MTLDevice) {
        commandQueue = device.makeCommandQueue()!
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        super.init(frame: NSRect(x: 0, y: 0, width: 518, height: 392), device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false
        isPaused = true
        enableSetNeedsDisplay = true
    }

    required init(coder: NSCoder) { fatalError("not used") }

    /// Called from Syphon's frame thread. Stores the texture and asks for a redraw on the main thread.
    func show(_ newTexture: MTLTexture) {
        lock.lock()
        texture = newTexture
        lock.unlock()
        DispatchQueue.main.async { self.needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        lock.lock()
        let source = texture
        lock.unlock()
        guard let source, let drawable = currentDrawable, let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        // Metal textures have their origin at the top left and Core Image at the bottom left,
        // so flip once to keep the picture upright.
        var image = CIImage(mtlTexture: source, options: nil)!.oriented(.downMirrored)
        let target = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        let scale = min(target.width / image.extent.width, target.height / image.extent.height)
        let offset = CGPoint(x: (target.width - image.extent.width * scale) / 2, y: (target.height - image.extent.height * scale) / 2)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: offset.x, y: offset.y)))
        context.render(image, to: drawable.texture, commandBuffer: commandBuffer, bounds: CGRect(origin: .zero, size: target), colorSpace: CGColorSpaceCreateDeviceRGB())
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

/// Owns the window and the Syphon client. Reconnects when the server appears or restarts.
///
/// Written by Claude Code; conversation transcript:
/// llm/transcripts/transcript_2026-10-20_07-18_eb73890b-4f17-4ace-abdd-6dda67cd169b.md
final class Viewer: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let serverName: String
    let device: MTLDevice
    let window: NSWindow
    let view: FrameView
    private var client: SyphonMetalClient?
    private var frames = 0
    private var lastSize = (0, 0)
    private var timer: Timer?

    init(serverName: String) {
        self.serverName = serverName
        device = MTLCreateSystemDefaultDevice()!
        view = FrameView(device: device)
        window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "webcam-depth-view: waiting for \"\(serverName)\""
        window.contentView = view
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = NotificationCenter.default
        for name in [NSNotification.Name.SyphonServerAnnounce, .SyphonServerUpdate, .SyphonServerRetire] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.connect() }
        }
        connect()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateTitle() }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    /// Connects to the first server with the wanted name, or drops the client when the server is gone.
    private func connect() {
        let servers = SyphonServerDirectory.shared().servers(matchingName: serverName, appName: nil)
        guard let description = servers.first else {
            client?.stop()
            client = nil
            window.title = "webcam-depth-view: waiting for \"\(serverName)\""
            return
        }
        let uuid = description[SyphonServerDescriptionUUIDKey] as? String
        if let client, client.serverDescription[SyphonServerDescriptionUUIDKey] as? String == uuid {
            return
        }
        client?.stop()
        client = SyphonMetalClient(serverDescription: description, device: device, options: nil) { [weak self] client in
            guard let self, let texture = client.newFrameImage() else { return }
            self.frames += 1
            self.lastSize = (texture.width, texture.height)
            self.view.show(texture)
        }
        let app = description[SyphonServerDescriptionAppNameKey] as? String ?? "?"
        window.title = "webcam-depth-view: \(app) - \(serverName)"
    }

    private func updateTitle() {
        guard client != nil else { return }
        window.title = "webcam-depth-view: \(serverName) \(lastSize.0)x\(lastSize.1) @ \(frames) fps"
        frames = 0
    }
}

let name = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "webcam-depth"
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let viewer = Viewer(serverName: name)
app.delegate = viewer
app.activate(ignoringOtherApps: true)
app.run()
