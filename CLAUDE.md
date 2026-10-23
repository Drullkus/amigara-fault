# Ghost of the Amigara Fault

Turn spatial depth into people-shaped holes in a wall.

## Objectives

- Completed within 12 hours.
- The user must learn TouchDesigner. Claude is permitted to instruct the user and otherwise are forbidden to wiring TD networks for the user.
  - The user has seniority as a technical artist:
    - Writing GLSL shaders for Minecraft, both on meshes and in post-processing.
    - Creating PBR textures.
    - Taming different kinds of noises into artistic output.
    - Nondestructive pixel art creation in Photoshop through layers, masks, blending, and smart filters.
- Generate a visual or spatial feed with silhouettes of people.
  - Device: Xbox One Kinect v2 (time of flight, 512x424 depth at 30 fps, 0.5 to 4.5 m) with a USB 3 PC adapter. Chosen on 2026-10-19 after the research in `llm/transcripts/`.
  - Read in TouchDesigner through the FreenectTD plugin.
  - Fallback input: the webcam sidecar on branch `webcam-sidecar-syphon` (Apple Vision person mask plus Depth Anything V2 depth). It publishes a Syphon texture named `webcam-depth`, 518x392 BGRA: red = mask, green = depth (larger is closer), blue = 0, alpha = 1. A Syphon Spout In TOP reads it.
  - Processed by TouchDesigner with a streamed NDI output.
- Projector that displays fiducials for viewing applications to align.
  - Only the white pixels for the fiducials. Otherwise brighter light causes shadows to be more prominent.
  - Unique fiducial for each corner: four ArUco 4x4 markers, ids 0 to 3, drawn and detected with the OpenCV that TouchDesigner bundles.
  - Server calibrates both silhouettes for alignment and projector for distortion: a camera sees the projected markers, `cv2.findHomography` drives a Corner Pin TOP, and Stoner is the manual override.
  - Calibration toggle for displaying silhouettes from projector.
- Displayed holes in the wall rendered based on the viewer's angle.
  - A separate viewing application renders the holes from the NDI stream and the fiducials. TouchDesigner renders the same look for preview and for an optional projector mode that follows one tracked viewer.
  - Look: a dark tunnel with depth-shaded walls, lines parallel and perpendicular to the depth axis as in Junji Ito's drawings, and a slider that thins and contorts the shape as the tunnel gets deeper.
  - Must tolerate some projected fiducials getting occluded.

The full plan is in `docs/touchdesigner-plan.md`.

## Tasks

If the user asks for a task from you, you are required to use AskUserQuestions to ensure that all details are exhaustively chosen by the user. Make the user decide everything. Leave nothing to assumption by you.

## Versions

- TouchDesigner 2025.x on macOS 15 or newer, Apple Silicon.
- TouchDesigner Non-Commercial license: every TOP is capped at 1280x1280, so the projector output is 1280x720.
- FreenectTD plugin (bundles libfreenect2) for the Kinect v2. The official Kinect operators are Windows only.
- TouchDesigner's bundled Python and OpenCV (`cv2`, including `cv2.aruco`). Do not install extra packages into TouchDesigner's Python.
- Branch `webcam-sidecar-syphon` holds the Swift 6 sidecar with the Syphon sender, plus the earlier Java 25 receiver as a record. Branch `webcam-sidecar` on origin is the TCP version. Do not merge either into `main`. Their `tools/webcam-depth/fetch-model.sh` and `fetch-syphon.sh` rebuild the gitignored model and Syphon framework.
- FreenectTD 1.0.1 is installed globally at `~/Library/Application Support/Derivative/TouchDesigner099/Plugins/FreenectTOP.plugin` by the `.pkg` installer of https://github.com/stosumarte/FreenectTD. A project-local copy would go in a gitignored `Plugins/` folder next to the `.toe`. Note the plugin version in the plan when it changes.

## Codebase conventions

- Documentation must be written in simple American English, following principles of ASD-STE100:
    - Unambiguous and instructive language.
    - Present tense and active tone.
- `amigara.toe` at the repository root is a thin shell. Each subsystem is a component saved as `td/<name>.tox`: `depth`, `fiducials`, `warp`, `holes`, `output`.
- Python lives in `td/scripts/` and GLSL in `td/shaders/`. Each DAT points at its file with the `file` parameter and syncs to it, so Git tracks readable code. Never keep code only inside a DAT.
- Each `.tox` contains a Text DAT named `README` that says what the component does and carries the attribution line below.
- Every Python file starts with a module docstring. Every GLSL file starts with a comment block.
- Claude cannot open `.toe` or `.tox` files. Claude writes the Python, GLSL and step-by-step wiring instructions; the owner builds and saves the networks in TouchDesigner by hand and reports what they see.
- TouchDesigner's `Backup/` folder and `CrashAutoSave.*` files are gitignored. Save a component with its `.tox` only after the owner confirms it works.

## AI attribution procedure

The repository owner cites AI-generated work, so every session Claude works in must follow these steps.

1. Transcripts live at `llm/transcripts/transcript_{start date, UTC}_{HH-MM, UTC}_{session uuid}.md` and are generated only by the owner, never on Claude's own initiative.
2. Generate one with `python3 llm/tools/claude_transcript_to_md.py` from the repo root; it picks the most recent session for this project and names the file itself.
3. A session may span several commits, so re-run the same command whenever the owner asks for an update and commit the changed transcript alongside the code; Git tracks its history.
4. Every file Claude creates or modifies gets the line `Written by Claude Code; conversation transcript: llm/transcripts/transcript-....md` using the repo-relative path (a file that already cites an earlier transcript keeps that line and gains one for the new session):
   - Java: a class-level Javadoc line `<p>Written by Claude Code; conversation transcript: {@code ...}.`
   - Python: in the module docstring. GLSL: in the leading comment block. Markdown: a line under the title.
   - `.tox`: in the `README` Text DAT of the component.
5. Find the path to cite before the transcript exists with `python3 llm/tools/claude_transcript_to_md.py --print-path`.
6. The desktop app sometimes resumes a conversation under a new session uuid; the tool detects this, renames the earlier transcript with `git mv`, and rewrites references in the project's text files, so check its output and stage the renamed file.
7. Do not add the owner's email, token usage, request IDs or Claude's reasoning to anything committed; the tool already strips them from transcripts.

## Transcript tool usage

- `python3 llm/tools/claude_transcript_to_md.py --list` lists the sessions recorded for this project with their uuid, start and end time, and opening prompt.
- `python3 llm/tools/claude_transcript_to_md.py` exports the latest session to `llm/transcripts/`.
- `--session <uuid prefix>` selects a specific session; `--file <path.jsonl>` exports a transcript file directly.
- `--print-path` prints the repo-relative output path without writing anything.
- `--include-results` embeds truncated tool output; `--max-chars N` changes the truncation limit (0 = unlimited); `-o <file>` or `-o -` overrides the destination.
- Sessions are read from `~/.claude/projects/<project path with slashes replaced by dashes>/*.jsonl`; the desktop app's `local_…` session handle is not a file name.
- A session that ran in a worktree is stored under the worktree's own folder name, for example `~/.claude/projects/-Users-drullkus-IdeaProjects-amigara-fault--claude-worktrees-<name>/<uuid>.jsonl`, so `--list` from the main checkout does not show it. Export it from the main checkout with `--file <that path>`, which still writes to `llm/transcripts/` here.
