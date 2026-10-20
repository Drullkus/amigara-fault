package dev.drullkus.amigara.depth;

/**
 * One frame from the depth sidecar: a person mask and a relative depth map of the same size.
 *
 * <p>Both planes are row-major with the top row first. The mask holds one unsigned byte per pixel
 * (0 = background, 255 = person). The depth plane holds one float per pixel in the range 0..1,
 * where a larger value means the pixel is closer to the camera. Depth is relative; it has no unit.
 *
 * <p>Written by Claude Code; conversation transcript: {@code llm/transcripts/transcript_2026-10-20_06-06_cf6a8f39-437b-4cd7-9962-fcfbb1efa030.md}.
 *
 * @param sequence      frame counter from the sidecar, starts at 0 and wraps at 2^32
 * @param captureMicros camera capture time, microseconds since the Unix epoch
 * @param sendMicros    time the sidecar wrote the frame, microseconds since the Unix epoch
 * @param receiveMicros time this process finished reading the frame, microseconds since the Unix epoch
 * @param width         width in pixels
 * @param height        height in pixels
 * @param mask          person confidence per pixel, {@code width * height} bytes, read as unsigned
 * @param depth         relative depth per pixel, {@code width * height} floats
 */
public record DepthFrame(
        long sequence,
        long captureMicros,
        long sendMicros,
        long receiveMicros,
        int width,
        int height,
        byte[] mask,
        float[] depth) {

    /** Returns the mask value at ({@code x}, {@code y}) as 0..255. */
    public int maskAt(int x, int y) {
        return mask[y * width + x] & 0xFF;
    }

    /** Returns the relative depth at ({@code x}, {@code y}). */
    public float depthAt(int x, int y) {
        return depth[y * width + x];
    }

    /** Time from camera capture to the end of the read in this process, in milliseconds. */
    public double endToEndMillis() {
        return (receiveMicros - captureMicros) / 1000.0;
    }

    /** Time from the sidecar's write to the end of the read in this process, in milliseconds. */
    public double transportMillis() {
        return (receiveMicros - sendMicros) / 1000.0;
    }
}
