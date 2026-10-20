// swift-tools-version: 6.0
// Written by Claude Code; conversation transcript:
// llm/transcripts/transcript_2026-10-20_06-06_cf6a8f39-437b-4cd7-9962-fcfbb1efa030.md
import PackageDescription

let package = Package(
    name: "webcam-depth",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "webcam-depth",
            path: "Sources/webcam-depth",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreML"),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreMedia"),
                // Embed Info.plist so macOS shows the camera permission prompt for this tool.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", Context.packageDirectory + "/Info.plist",
                ]),
            ]
        )
    ]
)
