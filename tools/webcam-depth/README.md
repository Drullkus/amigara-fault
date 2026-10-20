# webcam-depth

A macOS sidecar that turns the Mac's webcam into a per-pixel person mask and relative depth map,
and streams both to the Java server over TCP on localhost. It is the zero-hardware fallback input
for the wall renderer until a real depth camera is wired in.

Written by Claude Code; conversation transcript:
`llm/transcripts/transcript_2026-10-20_06-06_cf6a8f39-437b-4cd7-9962-fcfbb1efa030.md`.

## What it does

1. Opens the webcam with AVFoundation at 640x480, 30 fps (BGRA frames).
2. For every frame, runs two Vision requests in parallel:
   - `VNGeneratePersonSegmentationRequest` for the silhouette (one byte per pixel, 0..255).
   - Depth Anything V2 Small (Apple's Core ML build) through `VNCoreMLRequest` for relative depth.
3. Smooths the depth map with a per-pixel exponential moving average
   (`new = alpha * current + (1 - alpha) * previous`, alpha 0.5 by default).
4. Encodes mask and depth at 518x392 (the model's native size) behind a fixed 48-byte header and
   writes the frame to the server socket. If the server is down it reconnects every second.
   If the socket is slower than the camera, only the newest frame waits; older ones are dropped.

Measured on an M2 Max with the C920: 29 to 30 fps, about 33 ms of inference per frame
(mask about 18 ms and depth about 32 ms, overlapped), and about 100 ms from camera capture
to the end of the read on the Java side, of which under 1 ms is the socket.

## Requirements

- macOS 15 or newer on Apple Silicon, Xcode 26 (Swift 6) command-line tools.
- The Core ML model in `models/` (gitignored). Fetch it once:

```bash
tools/webcam-depth/fetch-model.sh
```

## Run

Start the Java server first or second; the order does not matter.

```bash
cd tools/webcam-depth && swift run -c release webcam-depth
```

The first start compiles the model and takes about 10 s. macOS asks for camera access once.
Run it from a terminal app, not from a sandboxed shell, or the camera prompt cannot appear.

Options:

| Flag | Default | Meaning |
| --- | --- | --- |
| `--camera <name fragment>` | `C920` | Camera to open, matched against the device name. |
| `--host <host>` | `127.0.0.1` | Server host. |
| `--port <port>` | `47011` | Server TCP port. |
| `--size <w>x<h>` | `518x392` | Output size of both planes. |
| `--alpha <0..1>` | `0.5` | EMA weight of the newest depth frame. `1` disables smoothing. |
| `--quality fast\|balanced\|accurate` | `balanced` | Vision person segmentation quality. |
| `--model <path>` | `models/DepthAnythingV2SmallF16.mlpackage` | Depth model. |
| `--list-cameras` | | Print the cameras macOS can see and exit. |
| `--list-formats` | | Print the chosen camera's formats and exit. |

Once per second it logs the frame rate, the inference time split into mask and depth, and the
number of frames sent and dropped.

## Wire format

Every frame is a 48-byte little-endian header, then the mask plane, then the depth plane.

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 4 | Magic `AMGD` (bytes `41 4D 47 44`) |
| 4 | 2 | Wire version, `1` |
| 6 | 2 | Header length, `48` |
| 8 | 4 | Frame sequence number, starts at 0 |
| 12 | 8 | Capture time, microseconds since the Unix epoch |
| 20 | 8 | Send time, microseconds since the Unix epoch |
| 28 | 2 | Width in pixels |
| 30 | 2 | Height in pixels |
| 32 | 1 | Mask format, `1` = one unsigned byte per pixel |
| 33 | 1 | Depth format, `1` = one float32 per pixel |
| 34 | 2 | Reserved, zero |
| 36 | 4 | Mask plane length in bytes (`width * height`) |
| 40 | 4 | Depth plane length in bytes (`width * height * 4`) |
| 44 | 4 | Reserved, zero |

Both planes are row-major with the top row first. Mask values are person confidence, 0 to 255.
Depth values are relative, 0 to 1, and a larger value means closer to the camera. Depth has no
unit and the scale can drift from frame to frame; use it for ordering, not for meters.

The Java side reads this with `dev.drullkus.amigara.depth.DepthFrameCodec` and
`DepthStreamServer`. The demo `DepthStreamDemo` prints frame rate and latency:

```bash
./gradlew run
```

## Docker

The sidecar cannot run in a container: it needs the Mac's webcam, Vision and Core ML.
The Java receiver can. The `Dockerfile` and `docker-compose.yml` at the repository root build
the receiver on `eclipse-temurin:25-jdk`, run it on `eclipse-temurin:25-jre`, and publish port
47011 to the host, so the sidecar on the Mac connects to `localhost:47011` as usual.

```bash
docker compose up --build
```
