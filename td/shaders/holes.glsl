// holes.glsl
// The Amigara Fault holes look: rings and stripes on a depth-shaded tunnel.
// Grown from holes_starter.glsl, which stays in the repository as the
// learning record.
//
// Input 0: a mask TOP. White (red >= 0.5) is the interior of a hole, black is
// the wall surface. The shader extrudes the mask into the wall along +z and
// marches a ray from the viewer's eye through each pixel. The first depth where
// the mask turns black is the tunnel wall. Wall pixels output alpha 0 so a later
// Over TOP can composite fiducials on top.
//
// Two line families mark the wall, as in Junji Ito's drawings:
//   - rings, perpendicular to the depth axis, at every uRingSpacing of depth;
//   - stripes, parallel to the depth axis. In perspective every line parallel
//     to the depth axis converges on the vanishing point, which is the eye
//     projected onto the wall plane, uEye.xy. So a stripe is a wedge of angle
//     around uEye.xy, and it reads as a straight line down the tunnel.
//
// All distances are in wall-width units: the wall spans x from 0 to 1 and
// y from 0 to 1 (UV space).
//
// Set these uniforms on the GLSL TOP's Vectors page:
//   uEye           vec3   viewer position, default (0.5, 0.5, -2.0)
//   uDepth         float  tunnel depth, default 1.5
//   uSteps         float  march steps, default 96, capped at 256
//   uFalloff       float  brightness exponent, default 1.5
//   uRingSpacing   float  distance between rings, default 0.1
//   uRingWidth     float  ring width as a fraction of the spacing, default 0.25
//   uParallelCount float  number of stripes around the tunnel, default 24
//   uStripeWidth   float  stripe width as a fraction of one wedge, default 0.2
//   uStripeLevel   float  stripe brightness relative to a ring, default 0.5
// Set Input Extend to Zero on the Common page so samples outside the frame
// read as wall.
//
// Written by Claude Code; conversation transcript: llm/transcripts/transcript_2026-10-22_01-04_7edac88c-db80-4ebd-a4f4-e455634fca2e.md
// Written by Claude Code; conversation transcript: llm/transcripts/transcript_2026-10-23_16-16_7fcf0baf-e62f-4209-ae8c-cd048c88884c.md

uniform vec3  uEye;
uniform float uDepth;
uniform float uSteps;
uniform float uFalloff;
uniform float uRingSpacing;
uniform float uRingWidth;
uniform float uParallelCount;
uniform float uStripeWidth;
uniform float uStripeLevel;

out vec4 fragColor;

// Projector light levels. Keep them low so the room stays dark.
const vec3 wallColor = vec3(1.0);
const vec3 lineColor = vec3(0.0);

const float TWO_PI = 6.28318530718;

// textureLod avoids implicit derivatives, which are undefined inside the
// divergent march loop and can fault the GPU on Metal.
bool isHole(vec2 uv)
{
    return textureLod(sTD2DInputs[0], uv, 0.0).r >= 0.5;
}

// Hard upper bound so the loop length is known at compile time.
const int MAX_STEPS = 256;

void main()
{
    vec2 uv = vUV.st;

    // Wall surface: transparent black.
    if (!isHole(uv)) {
        fragColor = vec4(0.0);
        return;
    }

    vec3 p = vec3(uv, 0.0);          // this pixel on the wall plane z = 0
    vec3 d = normalize(p - uEye);    // ray from the eye through the pixel
    d.z = max(d.z, 1e-4);            // the eye must be in front of the wall

    float depth   = max(uDepth, 1e-3);
    float spacing = max(uRingSpacing, 1e-3);
    float count   = max(uParallelCount, 1.0);
    int   steps   = clamp(int(uSteps), 1, MAX_STEPS);

    vec3 col = vec3(0.0);            // no hit: looking down the hole, dark
    for (int i = 1; i <= MAX_STEPS; i++) {
        if (i > steps) break;
        float z = depth * float(i) / float(steps);
        vec2 q = p.xy + d.xy * (z / d.z);   // ray position at this depth
        if (!isHole(q)) {
            float shade = pow(1.0 - z / depth, uFalloff);

            // Ring: a band of depth.
            float ring = step(fract(z / spacing), uRingWidth);

            // Stripe: a wedge of angle around the vanishing point. atan
            // returns -pi..pi; the fract keeps the wedge index periodic.
            float angle  = atan(q.y - uEye.y, q.x - uEye.x);
            float stripe = step(fract(angle * count / TWO_PI), uStripeWidth);

            // Rings win over stripes so the depth cue stays the brightest.
            float line = max(ring, stripe * uStripeLevel);
            col = mix(wallColor, lineColor, line) * shade;
            break;
        }
    }
    fragColor = TDOutputSwizzle(vec4(col, 1.0));
}
