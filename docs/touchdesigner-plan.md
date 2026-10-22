# TouchDesigner build plan

Written by Claude Code; conversation transcript: `llm/transcripts/transcript_2026-10-20_05-59_12b2b778-e37d-4136-8eec-8bb322f30bd6.md`.

This plan turns the objectives in `CLAUDE.md` into a TouchDesigner network. The owner made every decision below on 2026-10-19 and 2026-10-20.

## 1. Decisions

| Topic | Decision |
| --- | --- |
| Depth sensor | Xbox One Kinect v2 with a USB 3 PC adapter. Time of flight, 512x424 at 30 fps, 0.5 to 4.5 m rated, 70x60 degree field of view, 20 to 60 ms latency. |
| Sensor position | Next to the projector, facing the people. The silhouette then aligns to the projector with one homography. |
| Host | This Apple Silicon Mac, macOS 15 or newer. |
| Software | TouchDesigner 2025.x, Non-Commercial license. Every TOP is capped at 1280x1280, so the projector output is 1280x720. |
| Kinect driver | FreenectTD plugin (installer `.pkg`, needs TouchDesigner 2025 or newer). It bundles libfreenect2. The official Kinect operators are Windows only. |
| Fallback input | The webcam sidecar on branch `webcam-sidecar`, re-pointed to publish a Syphon texture. |
| Fiducials | Four ArUco markers from dictionary `DICT_4X4_50`, ids 0 to 3, one per corner, white on black. Drawn and detected with the OpenCV 4.8 that TouchDesigner bundles. |
| Projector correction | Automatic: `cv2.findHomography` from the detected markers drives a Corner Pin TOP. Stoner is the manual override. |
| Renderer of the holes | A separate viewing application renders the holes from the NDI stream and the fiducials. TouchDesigner renders the same look for preview and for an optional projector mode that follows one tracked viewer. |
| Hole look | Dark tunnel, depth-shaded walls, lines parallel and perpendicular to the depth axis, and a slider that thins and contorts the shape with depth. |
| Stream | NDI. |
| Repository layout | Thin `amigara.toe` plus one `td/<name>.tox` per subsystem. Python and GLSL live as files. |
| Attribution | Header comment in every Python and GLSL file, a `README` Text DAT in every `.tox`. |

## 2. Repository layout

```
amigara.toe                 thin shell: loads the five components, holds the projector Window COMP
td/depth.tox                Kinect or Syphon input, mask and depth in sensor space, head tracker
td/fiducials.tox            marker image, marker detection, calibration state
td/warp.tox                 homography, Corner Pin TOP, Stoner override
td/holes.tox                GLSL raymarch of the tunnel, viewer position switch
td/output.tox               calibration toggle, compositing, projector window, NDI Out
td/scripts/*.py             every Script TOP, CHOP, DAT and Execute DAT, synced by the DAT file parameter
td/shaders/*.glsl           every GLSL TOP and GLSL MAT
docs/touchdesigner-plan.md  this file
tools/webcam-depth/models/  the Core ML model, gitignored, fetched by the sidecar branch's script
Plugins/FreenectTOP.plugin  the FreenectTD plugin, gitignored, from its .pkg installer
```

Rules:

- Each `.tox` exposes its inputs and outputs as In TOP and Out TOP operators, so `amigara.toe` only wires components together.
- Each `.tox` has custom parameters on its component for everything a person tunes during a show. No magic numbers inside the network.
- Save a `.tox` from its component only; never save the whole `.toe` to update one subsystem.

## 3. Components

### 3.1 `depth.tox`

Inputs: none (hardware). Outputs: `mask` (one channel, 0 to 1), `depth` (one channel, 0 near to 1 far inside the working range), `rgb` (the Kinect color camera), `head` CHOP (viewer x, y, z in meters, plus `valid`).

1. One FreenectTD TOP, because the plugin allows one operator per machine. Render Select TOPs read index 1 (depth) and index 2 (point cloud); index 0 is RGB. Turn on depth registration so the depth lands in the RGB camera's pixel grid.
2. A Syphon Spout In TOP set to the sender `webcam-depth` is the fallback. It carries the mask in red and the depth in green.
3. A Switch TOP with the custom parameter `Source` (Kinect, Webcam) picks one.
4. Custom parameters `Near` and `Far` in meters (defaults 2.5 and 6.5) clip the working range. A Threshold TOP between them makes the mask. A Level TOP maps the range to 0 to 1 for the `depth` output.
5. Denoise: a Blur TOP with a small radius, then a Threshold TOP again, then a Cache TOP with a 2-frame hold so dropped Kinect frames do not flicker the mask.
6. Head tracker: a Blob Track TOP on the mask. For the largest blob, take the topmost pixel of the blob's column as the head. Sample `depth` there for z. Convert pixel to meters with the Kinect v2 depth intrinsics (focal length about 365 px, center about 256, 212 for the 512x424 image; use the RGB intrinsics when registration is on). Output `head` CHOP with x, y, z and `valid`. A Lag CHOP smooths it.

Smoke test: a person at 4 m shows as a solid white blob in `mask` and a mid-gray value in `depth`.

### 3.2 `fiducials.tox`

Inputs: `rgb` from `depth.tox`. Outputs: `markers` TOP (1280x720, black with four white markers), `corners` DAT (table: id, x0, y0 ... x3, y3, age in frames), `status` CHOP (visible count, calibrated flag).

1. `scripts/fiducials_draw.py` in a Script TOP draws the markers once at start and on parameter change. It uses `cv2.aruco.getPredefinedDictionary(cv2.aruco.DICT_4X4_50)` and `cv2.aruco.generateImageMarker(dictionary, id, side)`. Custom parameters: `Side` in pixels (default 120), `Margin` from the edge (default 40). Marker 0 sits top left, 1 top right, 2 bottom right, 3 bottom left. Every pixel outside the markers is black, so the projector adds no light there.
2. `scripts/fiducials_detect.py` in a Script DAT runs `cv2.aruco.ArucoDetector(dictionary, cv2.aruco.DetectorParameters()).detectMarkers(gray)` on the `rgb` frame every N frames (custom parameter `Interval`, default 5). It writes the four corners of each detected marker to the `corners` table and resets that row's `age` to 0. Rows for markers that are not detected keep their last corners and their `age` grows by one each run.
3. Occlusion rule: a marker is usable while `age` is below `MaxAge` (custom parameter, default 150 runs). A calibration is valid when at least 2 markers are usable, which gives 8 point pairs. With only 1 usable marker the component keeps the last valid homography and sets `calibrated` to 0. The viewing application follows the same rule.

Smoke test: with the markers projected on the wall and the Kinect looking at the wall, the `corners` table lists ids 0 to 3 with `age` 0 and the `status` CHOP shows 4 visible.

### 3.3 `warp.tox`

Inputs: `corners` DAT, any content TOP. Outputs: `warped` TOP in projector space.

1. `scripts/warp_homography.py` in a Script CHOP computes `H` from camera pixels to projector pixels with `cv2.findHomography(camera_points, projector_points, cv2.RANSAC)`, using every corner of every usable marker. The projector points are known from the `Side` and `Margin` parameters of `fiducials.tox`.
2. The wall rectangle: four custom parameters `WallTL`, `WallTR`, `WallBR`, `WallBL` in camera pixels, set once by clicking in a viewer of `rgb`. Default: the whole camera frame. The script maps those four points through `H` and writes the results to the pin points of a Corner Pin TOP. Content drawn into that rectangle lands straight on the wall.
3. Silhouette alignment uses the same `H`, because the Kinect's RGB camera is the calibration camera and the registered depth already sits in RGB pixels. A second Corner Pin TOP (or the same one on a second input) warps `mask` and `depth` into projector space.
4. Stoner from the palette sits after the Corner Pin TOP with the custom toggle `ManualOverride`. Its grid starts as identity and the owner drags points if the automatic result is off.
5. `Freeze` toggle: stops updating `H` so a crowd in front of the markers cannot drift the calibration during the show.

Smoke test: project a white rectangle through `warp.tox`; its edges line up with the wall rectangle the owner picked, within a pixel or two in the camera view.

### 3.4 `holes.tox`

Inputs: `mask` and `depth` in projector space, `head` CHOP. Output: `holes` TOP, 1280x720.

One GLSL TOP running `shaders/holes.glsl`. For every output pixel:

1. Place the wall at z = 0 in meters, with the pixel's wall position from the output size and the custom parameter `WallWidth` in meters. The eye `E` comes from the viewer position (section 4). Default is 3 m straight in front of the wall center.
2. If `mask` at the pixel is below 0.5, the pixel is wall: output black.
3. Otherwise march along the ray from the pixel into the wall, from z = 0 to z = `TunnelDepth` (custom parameter, default 2 m) in `Steps` steps (default 96). At depth z, transform the sample position around the silhouette's centroid:
   - thin: scale by `1 - Thin * (z / TunnelDepth)`;
   - contort: offset x by `Contort * sin(z * ContortFrequency)` and rotate by `Contort * z * TwistRate`.
   The centroid comes from an Analyze TOP on `mask`. `Thin` and `Contort` are the sliders the owner asked for; `Thin` at 0 and `Contort` at 0 give a straight tunnel.
4. The first z where the transformed sample of `mask` drops below 0.5 is the hit on the tunnel wall. If no step hits, output black (the tunnel's end is dark).
5. Shade the hit:
   - brightness `1 - z / TunnelDepth`, raised to `Falloff` (default 1.5);
   - perpendicular lines: a ring where `fract(z / RingSpacing) < RingWidth` (defaults 0.1 m and 0.25);
   - parallel lines: a stripe where `fract(angle * ParallelCount / (2 pi)) < StripeWidth`, with `angle` the direction from the centroid to the hit's cross-section position (defaults 48 and 0.3);
   - lines are drawn in `LineColor` (default light gray); the rest of the wall is `WallColor` (default a dark gray). Both are projector light levels, so keep them low.
6. Output alpha is 1 inside the hole and 0 on the wall, so `output.tox` can composite markers on top.

The viewing application copies this algorithm; the shader file is the specification. Keep the parameter names identical on both sides.

Smoke test: with a test mask (a Circle TOP), the preview shows a round tunnel with rings and stripes, which skews when `head` moves left and right.

### 3.5 `output.tox`

Inputs: `markers`, `mask`, `depth`, `holes`. Outputs: the projector window and the NDI stream.

1. A Switch TOP with custom parameter `Mode`:
   - `Fiducials`: only the markers (the show default when a viewing application renders).
   - `Calibrate`: markers plus the warped `mask` at a low level, so the owner sees whether the silhouette lands on the person. This is the calibration toggle from the objectives.
   - `Holes`: markers composited over `holes` (the tracked-viewer projector mode).
2. The markers always composite last with an Over TOP so a hole never covers a fiducial.
3. A Window COMP at 1280x720 on the projector display, borderless, always on top. Keep the Non-Commercial cap in mind: do not ask for 1920x1080.
4. An NDI Out TOP named `amigara` sends one RGBA 1280x720 stream: red = `mask`, green = `depth`, blue = 0, alpha = `mask`, all in projector space. An OSC Out CHOP on port 47012 sends `status` (visible markers, calibrated flag) and `head` ten times a second for viewing applications that want them.

Smoke test: an NDI monitor app on a phone on the same Wi-Fi shows the mask within about 100 ms of a person's movement.

## 4. Viewer tracking

The owner asked how the projector mode can know the viewer's angle. `holes.tox` takes the viewer position from a Switch CHOP with the custom parameter `ViewerSource`:

1. `Fixed`: three custom parameters in meters. Use this for preview and for a single known seat.
2. `Kinect`: the `head` CHOP from `depth.tox`. The nearest person is the viewer. This needs no extra device, but the viewer must stand inside the Kinect's view, so for the projector mode the Kinect must see both the people at the wall and the viewer. With the Kinect next to the projector, the viewer is usually behind the Kinect. Mount the Kinect a step behind the projector, or accept that only the people at the wall can be viewers.
3. `OSC`: an OSC In CHOP on port 47013 receiving `/viewer x y z` from a viewing application. The application already sees the four markers, so `cv2.solvePnP` on their corners with the marker side in meters gives the phone's position relative to the wall. This is the most accurate source and costs nothing extra once the application exists.

The projector can serve only one viewer at a time. Everyone else sees a skewed tunnel, which is why the viewing application stays the primary renderer.

## 5. Calibration procedure

1. Set `output.tox` `Mode` to `Fiducials`. Point the projector at the wall and focus it.
2. Place the Kinect next to the projector, facing the wall, and start `depth.tox` with `Source` = Kinect. Check that `rgb` shows all four markers.
3. In `fiducials.tox`, wait until `status` shows 4 visible. Raise `Side` if a marker is too small for the camera to detect at this distance.
4. In `warp.tox`, click the four wall corners in the `rgb` viewer to set `WallTL` to `WallBL`. The Corner Pin TOP updates at once.
5. Set `Mode` to `Calibrate`. Stand at the wall. The gray silhouette must cover your body. If it is offset, confirm that depth registration is on in `depth.tox`; if it is slightly off, turn on `ManualOverride` and drag Stoner's points.
6. Set `Near` and `Far` so that only people at the wall appear in `mask`.
7. Turn on `Freeze` in `warp.tox`. Set `Mode` back to `Fiducials` (or `Holes` for the projector mode).

## 6. Build order for the 12 hours

| Hours | Work | Done when |
| --- | --- | --- |
| 0 to 1 | Install TouchDesigner 2025 and the FreenectTD `.pkg`. Create `amigara.toe` and the five empty components with In and Out TOPs. Commit the layout. | The toe opens with no errors. |
| 1 to 2 | `fiducials.tox` drawing. Project the markers. | The wall shows four markers and nothing else. |
| 2 to 4 | `fiducials.tox` detection and `warp.tox`, using the Mac webcam as the camera until the Kinect arrives. | A projected rectangle lands straight on the wall. |
| 4 to 6 | `holes.tox` shader with a test mask and the `Fixed` viewer. | Rings, stripes, thin and contort sliders all work in preview. |
| 6 to 7 | `output.tox`: modes, projector window, NDI Out, OSC Out. | A phone shows the NDI stream. |
| 7 to 9 | `depth.tox` with the Kinect. Smoke-test the sensor first with `Protonect cpu -noviewer` from a libfreenect2 build, then in FreenectTD. | A person at 4 m is a clean mask. |
| 9 to 10 | Calibration procedure end to end. | The silhouette covers the person on the wall. |
| 10 to 12 | Rehearsal, parameter tuning, saving every `.tox`, transcript export by the owner. | Everything is committed. |

If the Kinect fails on this Mac (section 7), spend hours 7 to 9 on the Syphon rewrite of the sidecar instead.

## 7. Risks

1. **libfreenect2 on Apple Silicon.** Issue OpenKinect/libfreenect2#1211 (August 2026, M4) reports the Kinect v2 enumerating and then failing to start with `LIBUSB_ERROR_TIMEOUT`. FreenectTD claims Kinect v2 support on Apple Silicon. Test on arrival with a libfreenect2 build before trusting the plugin. Mitigations: try every USB port and a powered USB 3 hub; run the sidecar fallback; or run libfreenect2 on any Linux or Windows machine with USB 3 and send the depth to this Mac over NDI.
2. **The adapter's Windows label.** The adapter is a USB 3 hub with a 12 V supply; the operating system list on the box describes Microsoft's SDK, not the hardware. libfreenect2 on macOS and Linux uses this same adapter.
3. **1280x1280 cap.** Keep every TOP at 1280x720 or smaller. The projector upscales.
4. **One FreenectTD operator per machine.** All Kinect streams come from one TOP through Render Select TOPs. Never add a second FreenectTD TOP.
5. **Dark room.** The markers must be bright enough for the Kinect's RGB camera. Raise `Side`, not projector brightness, because stray light makes shadows.
6. **`cv2.aruco` API.** TouchDesigner bundles OpenCV 4.8, which uses the `ArucoDetector` class and `generateImageMarker`, not the older `drawMarker` and `detectMarkers` module functions. Confirm with `print(cv2.__version__)` in a Text DAT on first launch.

## 8. Fallback sidecar (branch `webcam-sidecar-syphon`)

Done on 2026-10-20. The sidecar publishes a Syphon server named `webcam-depth`: one 518x392 BGRA texture per frame, red = person mask, green = smoothed relative depth (larger is closer), blue = 0, alpha = 1, at 29 fps on an M2 Max. `depth.tox` reads it with a Syphon Spout In TOP set to that sender.

To run it, check out the branch, then:

```bash
tools/webcam-depth/fetch-model.sh
```

```bash
tools/webcam-depth/fetch-syphon.sh
```

```bash
cd tools/webcam-depth && swift run -c release webcam-depth
```

Start it from a Terminal panel tab, not from a sandboxed shell, or macOS cannot show the camera prompt. The TCP version stays on branch `webcam-sidecar` on origin. Neither branch is merged into `main`.
