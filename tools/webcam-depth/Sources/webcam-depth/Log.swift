import Foundation

/// Minimal timestamped logging to standard error, so standard output stays free.
///
/// Written by Claude Code; conversation transcript:
/// llm/transcripts/transcript_2026-10-20_06-06_cf6a8f39-437b-4cd7-9962-fcfbb1efa030.md
/// Written by Claude Code; conversation transcript:
/// llm/transcripts/transcript_2026-10-20_07-18_eb73890b-4f17-4ace-abdd-6dda67cd169b.md
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
