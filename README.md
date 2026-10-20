# Ghost of the Amigara Fault

Turn spatial depth into people-shaped holes in a wall. Do not enter the hole.

Or you else will smack into the wall like Wile E. Coyote.

## Webcam fallback input

`tools/webcam-depth` is a macOS sidecar that streams a person mask and a relative depth map from
the webcam to the Java server over TCP. See `tools/webcam-depth/README.md` for the run command,
the flags and the wire format. The Java side lives in `dev.drullkus.amigara.depth`.
