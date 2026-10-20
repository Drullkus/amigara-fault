# webcam-depth

A macOS sidecar that turns the Mac's webcam into a per-pixel person mask and relative depth map,
and publishes both as one Syphon texture named `webcam-depth`. It is the zero-hardware fallback
input for the TouchDesigner project until the Kinect v2 is wired in.

Written by Claude Code; conversation transcript:
`llm/transcripts/transcript_2026-10-20_06-06_cf6a8f39-437b-4cd7-9962-fcfbb1efa030.md`.
Written by Claude Code; conversation transcript:
`llm/transcripts/transcript_2026-10-20_07-18_eb73890b-4f17-4ace-abdd-6dda67cd169b.md`.

## What it does

1. Opens the webcam with AVFoundation at 640x480, 30 fps (BGRA frames).
2. For every frame, runs two Vision requests in parallel:
   - `VNGeneratePersonSegmentationRequest` for the silhouette (one byte per pixel, 0..255).
   - Depth Anything V2 Small (Apple's Core ML build) through `VNCoreMLRequest` for relative depth.
3. Smooths the depth map with a per-pixel exponential moving average
   (`new = alpha * current + (1 - alpha) * previous`, alpha 0.5 by default).
4. Packs mask and depth into one 518x392 BGRA8 Metal texture and publishes it on a
   `SyphonMetalServer` named `webcam-depth`. Two textures rotate, so the CPU fills one while the
   GPU copies the other.

Measured on an M2 Max with the C920: 29 to 30 fps, about 33 ms of inference per frame
(mask about 18 ms and depth about 32 ms, overlapped).

## Requirements

- macOS 15 or newer on Apple Silicon, Xcode 26 or newer with its Metal toolchain
  (`xcodebuild -downloadComponent MetalToolchain` installs the toolchain once).
- The Core ML model in `models/` (gitignored). Fetch it once:

```bash
tools/webcam-depth/fetch-model.sh
```

- `Syphon.framework` in `Frameworks/` (gitignored). Upstream Syphon has no Swift package and no
  release with its Metal classes, so this script clones the pinned commit `f476167` and builds
  the framework with `xcodebuild`:

```bash
tools/webcam-depth/fetch-syphon.sh
```

`Package.swift` points both executables at `Frameworks/` with `-F` and `-rpath`.

## Run

```bash
cd tools/webcam-depth && swift run -c release webcam-depth
```

The first start compiles the model and takes about 10 s. macOS asks for camera access once.
Run it from a terminal app, not from a sandboxed shell, or the camera prompt cannot appear.

Options:

| Flag | Default | Meaning |
| --- | --- | --- |
| `--camera <name fragment>` | `C920` | Camera to open, matched against the device name. |
| `--size <w>x<h>` | `518x392` | Size of the published texture. |
| `--alpha <0..1>` | `0.5` | EMA weight of the newest depth frame. `1` disables smoothing. |
| `--quality fast\|balanced\|accurate` | `balanced` | Vision person segmentation quality. |
| `--model <path>` | `models/DepthAnythingV2SmallF16.mlpackage` | Depth model. |
| `--list-cameras` | | Print the cameras macOS can see and exit. |
| `--list-formats` | | Print the chosen camera's formats and exit. |

Once per second it logs the frame rate, the inference time split into mask and depth, the
number of frames published, and whether a Syphon client is attached. Ctrl-C retires the Syphon
server before the process exits.

## Syphon texture

Server name: `webcam-depth`. Syphon clients list it as `webcam-depth - webcam-depth`
(application name, then server name).

The texture is 518x392 by default, `MTLPixelFormatBGRA8Unorm`, with the top row first
(published with `flipped = false`). Syphon's Metal path is 8 bits per channel, so depth has 256
levels.

| Channel | Content |
| --- | --- |
| Red | Person mask, 0 to 1 (255 = person). |
| Green | Relative depth, 0 to 1, larger is closer. |
| Blue | 0. |
| Alpha | 1. |

Depth has no unit and the scale can drift from frame to frame; use it for ordering, not for
meters.

In TouchDesigner, add a Syphon Spout In TOP and pick `webcam-depth - webcam-depth` as the sender.
Read the red channel for the silhouette and the green channel for depth, for example with a
Reorder TOP or in a GLSL TOP. If the picture is upside down, add a Flip TOP.

## Check without TouchDesigner

`webcam-depth-view` is a small Syphon client in the same package. It opens one window, draws
the `webcam-depth` texture as it arrives, and shows the texture size and frame rate in the title.
A person shows in yellow (red mask over green depth) on a green depth field.

```bash
cd tools/webcam-depth && swift run -c release webcam-depth-view
```

Pass another server name as the only argument to view a different Syphon server.

## History

The first version of this sidecar sent the frames over TCP to a Java receiver with a 48-byte
header. That receiver (`src/main/java/dev/drullkus/amigara/depth/`), its Gradle files and the
Docker files at the repository root stay on this branch as a record. Nothing feeds them any more.
