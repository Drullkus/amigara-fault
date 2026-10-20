import Darwin
import Foundation

/// Streams frames to the Java server over TCP. Reconnects every second while the server is down.
/// Only the newest frame waits for the socket; older unsent frames are dropped.
///
/// Written by Claude Code; conversation transcript:
/// llm/transcripts/transcript_2026-10-20_06-06_cf6a8f39-437b-4cd7-9962-fcfbb1efa030.md
final class FrameSender {
    let host: String
    let port: UInt16

    private let queue = DispatchQueue(label: "webcam-depth.sender", qos: .userInteractive)
    private let lock = NSLock()
    private var latest: Data?
    private var draining = false
    private var fd: Int32 = -1
    private var lastConnectAttempt: TimeInterval = 0
    private var reportedDown = false

    private(set) var sentFrames = 0
    private(set) var droppedFrames = 0

    var isConnected: Bool { fd >= 0 }

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
        signal(SIGPIPE, SIG_IGN)
    }

    /// Queues one frame. If a frame is still waiting, that older frame is dropped.
    func submit(_ frame: Data) {
        lock.lock()
        if latest != nil { droppedFrames += 1 }
        latest = frame
        let startDrain = !draining
        if startDrain { draining = true }
        lock.unlock()
        if startDrain {
            queue.async { self.drain() }
        }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let frame = latest else {
                draining = false
                lock.unlock()
                return
            }
            latest = nil
            lock.unlock()
            send(frame)
        }
    }

    private func send(_ frame: Data) {
        if fd < 0 {
            let now = Date().timeIntervalSince1970
            guard now - lastConnectAttempt >= 1 else {
                droppedFrames += 1
                return
            }
            lastConnectAttempt = now
            if !connect() {
                droppedFrames += 1
                if !reportedDown {
                    reportedDown = true
                    Log.line("waiting for a server on \(host):\(port)")
                }
                return
            }
            reportedDown = false
            Log.line("connected to \(host):\(port)")
        }
        let ok = frame.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        if ok {
            sentFrames += 1
        } else {
            Log.line("connection lost (\(String(cString: strerror(errno)))); reconnecting")
            close(fd)
            fd = -1
            droppedFrames += 1
        }
    }

    private func connect() -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let first = info else { return false }
        defer { freeaddrinfo(info) }
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            let s = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if s >= 0 {
                var one: Int32 = 1
                setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                if Darwin.connect(s, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0 {
                    fd = s
                    return true
                }
                close(s)
            }
            ai = a.pointee.ai_next
        }
        return false
    }
}

/// Minimal timestamped logging to standard error, so standard output stays free.
///
/// Written by Claude Code; conversation transcript:
/// llm/transcripts/transcript_2026-10-20_06-06_cf6a8f39-437b-4cd7-9962-fcfbb1efa030.md
enum Log {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func line(_ message: String) {
        FileHandle.standardError.write("[\(formatter.string(from: Date()))] \(message)\n".data(using: .utf8)!)
    }
}
