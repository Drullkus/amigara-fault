# Ghost of the Amigara Fault

Turn spatial depth into people-shaped holes in a wall.

## Objectives

- Completed within 12 hours.
- Generate a visual or spatial feed with silhouettes of people.
  - Device not chosen yet.
  - Processed by a server with a streamed output.
- Projector that displays fiducials for viewing applications to align.
  - Only the white pixels for the fiducials. Otherwise brighter light causes shadows to be more prominent.
  - Unique fiducial for each corner.
  - Server calibrates both silhouettes for alignment and projector for distortion.
  - Calibration toggle for displaying silhouettes from projector.
- Displayed holes in the wall rendered based on the viewer's angle.
  - Rendered using LWJGL.
  - Must tolerate some projected fiducials getting occluded.

## Tasks

If the user asks for a task from you, you are required to use AskUserQuestions to ensure that all details are exhaustively chosen by the user. Make the user decide everything. Leave nothing to assumption by you.

## Versions

- Java 25 toolchain with Gradle
- LWJGL 3.4.3
- OpenGL 4.1
- Dear ImGui v1.93.0

## Codebase conventions

- Documentation must be written in simple American English, following principles of ASD-STE100:
    - Unambiguous and instructive language.
    - Present tense and active tone.
- Every package must be annotated with `@org.jspecify.annotations.NullMarked`.

## AI attribution procedure

The repository owner cites AI-generated work, so every session Claude works in must follow these steps.

1. Transcripts live at `llm/transcripts/transcript_{start date, UTC}_{HH-MM, UTC}_{session uuid}.md` and are generated only by the owner, never on Claude's own initiative.
2. Generate one with `python3 llm/tools/claude_transcript_to_md.py` from the repo root; it picks the most recent session for this project and names the file itself.
3. A session may span several commits, so re-run the same command whenever the owner asks for an update and commit the changed transcript alongside the code; Git tracks its history.
4. Every class Claude creates or modifies gets a class-level Javadoc line `<p>Written by Claude Code; conversation transcript: {@code llm/transcripts/transcript-....md}.` using the repo-relative path (a modified class that already cites an earlier transcript keeps that line and gains one for the new session).
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
