// swift-tools-version: 6.0
// Written by Claude Code; conversation transcript:
// llm/transcripts/transcript_2026-10-20_06-06_cf6a8f39-437b-4cd7-9962-fcfbb1efa030.md
// Written by Claude Code; conversation transcript:
// llm/transcripts/transcript_2026-10-20_07-18_eb73890b-4f17-4ace-abdd-6dda67cd169b.md
import PackageDescription

// Syphon.framework is built by fetch-syphon.sh into Frameworks/ (gitignored). Upstream has no
// Swift package, so both executables find it through -F at compile time and -rpath at run time.
let frameworksDir = Context.packageDirectory + "/Frameworks"
let syphonSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .unsafeFlags(["-F", frameworksDir]),
]
let syphonLinkerSettings: [LinkerSetting] = [
    .linkedFramework("Syphon"),
    .linkedFramework("Metal"),
    .unsafeFlags(["-F", frameworksDir, "-Xlinker", "-rpath", "-Xlinker", frameworksDir]),
]

let package = Package(
    name: "webcam-depth",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "webcam-depth",
            path: "Sources/webcam-depth",
            swiftSettings: syphonSwiftSettings,
            linkerSettings: syphonLinkerSettings + [
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
        ),
        // A small Syphon client that shows the "webcam-depth" texture in a window, for checks
        // on a Mac without TouchDesigner.
        .executableTarget(
            name: "webcam-depth-view",
            path: "Sources/webcam-depth-view",
            swiftSettings: syphonSwiftSettings,
            linkerSettings: syphonLinkerSettings + [
                .linkedFramework("AppKit"),
                .linkedFramework("MetalKit"),
                .linkedFramework("CoreImage"),
            ]
        ),
    ]
)
