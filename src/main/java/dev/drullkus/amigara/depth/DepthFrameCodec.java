package dev.drullkus.amigara.depth;

import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.time.Instant;

/**
 * Reads frames in the sidecar's wire format from a stream.
 *
 * <p>Every frame starts with a fixed 48-byte little-endian header:
 * <pre>
 * offset size field
 *  0     4   magic "AMGD"
 *  4     2   wire version, 1
 *  6     2   header length, 48
 *  8     4   sequence number
 * 12     8   capture time, microseconds since the Unix epoch
 * 20     8   send time, microseconds since the Unix epoch
 * 28     2   width
 * 30     2   height
 * 32     1   mask format, 1 = one unsigned byte per pixel
 * 33     1   depth format, 1 = one float32 per pixel
 * 34     2   reserved
 * 36     4   mask plane length in bytes
 * 40     4   depth plane length in bytes
 * 44     4   reserved
 * </pre>
 * The mask plane follows the header and the depth plane follows the mask plane.
 *
 * <p>Written by Claude Code; conversation transcript: {@code llm/transcripts/transcript_2026-10-20_06-06_cf6a8f39-437b-4cd7-9962-fcfbb1efa030.md}.
 */
public final class DepthFrameCodec {

    /** Header length in bytes. */
    public static final int HEADER_LENGTH = 48;
    /** The four magic bytes "AMGD" read as a little-endian int. */
    public static final int MAGIC = 'A' | ('M' << 8) | ('G' << 16) | ('D' << 24);
    /** Wire version this codec understands. */
    public static final int VERSION = 1;
    /** Mask format code for one unsigned byte per pixel. */
    public static final int MASK_FORMAT_U8 = 1;
    /** Depth format code for one little-endian float32 per pixel. */
    public static final int DEPTH_FORMAT_F32 = 1;

    private final byte[] headerBytes = new byte[HEADER_LENGTH];
    private final ByteBuffer header = ByteBuffer.wrap(headerBytes).order(ByteOrder.LITTLE_ENDIAN);

    /**
     * Reads one frame. Blocks until the full frame has arrived.
     *
     * @throws EOFException when the stream ends before a full frame has arrived
     * @throws IOException  on a read error or a malformed header
     */
    public DepthFrame read(InputStream in) throws IOException {
        readFully(in, headerBytes, HEADER_LENGTH);
        header.clear();
        int magic = header.getInt();
        if (magic != MAGIC) {
            throw new IOException("bad magic 0x" + Integer.toHexString(magic) + "; the sidecar and this codec disagree on the wire format");
        }
        int version = header.getShort() & 0xFFFF;
        int headerLength = header.getShort() & 0xFFFF;
        if (version != VERSION || headerLength != HEADER_LENGTH) {
            throw new IOException("unsupported wire version " + version + " with header length " + headerLength);
        }
        long sequence = header.getInt() & 0xFFFFFFFFL;
        long captureMicros = header.getLong();
        long sendMicros = header.getLong();
        int width = header.getShort() & 0xFFFF;
        int height = header.getShort() & 0xFFFF;
        int maskFormat = header.get() & 0xFF;
        int depthFormat = header.get() & 0xFF;
        header.getShort();
        int maskBytes = header.getInt();
        int depthBytes = header.getInt();
        if (maskFormat != MASK_FORMAT_U8 || depthFormat != DEPTH_FORMAT_F32) {
            throw new IOException("unsupported plane formats mask=" + maskFormat + " depth=" + depthFormat);
        }
        int pixels = width * height;
        if (maskBytes != pixels || depthBytes != pixels * Float.BYTES) {
            throw new IOException("plane lengths " + maskBytes + "/" + depthBytes + " do not match " + width + "x" + height);
        }

        byte[] mask = new byte[maskBytes];
        readFully(in, mask, maskBytes);
        byte[] depthRaw = new byte[depthBytes];
        readFully(in, depthRaw, depthBytes);
        float[] depth = new float[pixels];
        ByteBuffer.wrap(depthRaw).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer().get(depth);

        return new DepthFrame(sequence, captureMicros, sendMicros, nowMicros(), width, height, mask, depth);
    }

    /** Microseconds since the Unix epoch on this machine's wall clock. */
    public static long nowMicros() {
        Instant now = Instant.now();
        return now.getEpochSecond() * 1_000_000L + now.getNano() / 1_000L;
    }

    private static void readFully(InputStream in, byte[] dst, int length) throws IOException {
        int off = 0;
        while (off < length) {
            int n = in.read(dst, off, length - off);
            if (n < 0) {
                throw new EOFException("stream ended after " + off + " of " + length + " bytes");
            }
            off += n;
        }
    }
}
