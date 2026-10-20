package dev.drullkus.amigara.depth;

import java.io.IOException;
import java.util.Locale;

/**
 * Starts a {@link DepthStreamServer} and prints frame rate and latency once per second.
 *
 * <p>Run it with {@code ./gradlew run}, then start the sidecar from {@code tools/webcam-depth} with
 * {@code swift run -c release webcam-depth}. The first argument overrides the port.
 *
 * <p>Each line shows: frames received in the last second, end-to-end latency from camera capture to
 * the end of the read (average and maximum), transport latency from the sidecar's write to the end
 * of the read, the share of pixels the mask marks as a person, and the mean depth inside the mask.
 *
 * <p>Written by Claude Code; conversation transcript: {@code llm/transcripts/transcript_2026-10-20_06-06_cf6a8f39-437b-4cd7-9962-fcfbb1efa030.md}.
 */
public final class DepthStreamDemo {

    private DepthStreamDemo() {
    }

    /** Per-second counters, guarded by {@code this}. */
    private static final class Stats {
        int frames;
        double endToEndSum;
        double endToEndMax;
        double transportSum;
        double coverageSum;
        double depthInMaskSum;
        int depthInMaskFrames;
        long lastSequence = -1;
        int gaps;
        int width;
        int height;

        synchronized void add(DepthFrame frame) {
            frames++;
            double e2e = frame.endToEndMillis();
            endToEndSum += e2e;
            endToEndMax = Math.max(endToEndMax, e2e);
            transportSum += frame.transportMillis();
            if (lastSequence >= 0 && frame.sequence() != lastSequence + 1) {
                gaps++;
            }
            lastSequence = frame.sequence();
            width = frame.width();
            height = frame.height();

            int pixels = frame.width() * frame.height();
            int inMask = 0;
            double depthSum = 0;
            byte[] mask = frame.mask();
            float[] depth = frame.depth();
            for (int i = 0; i < pixels; i++) {
                if ((mask[i] & 0xFF) >= 128) {
                    inMask++;
                    depthSum += depth[i];
                }
            }
            coverageSum += (double) inMask / pixels;
            if (inMask > 0) {
                depthInMaskSum += depthSum / inMask;
                depthInMaskFrames++;
            }
        }

        synchronized String drainLine(double seconds, boolean connected) {
            String line;
            if (frames == 0) {
                line = connected ? "0 fps | sidecar connected, no frames" : "0 fps | waiting for the sidecar";
            } else {
                line = String.format(Locale.ROOT,
                        "%.1f fps | %dx%d | latency capture->read avg %.1f ms max %.1f ms | transport avg %.2f ms | person %.1f%% of pixels | depth in mask %.3f | gaps %d",
                        frames / seconds, width, height,
                        endToEndSum / frames, endToEndMax,
                        transportSum / frames,
                        100.0 * coverageSum / frames,
                        depthInMaskFrames > 0 ? depthInMaskSum / depthInMaskFrames : Double.NaN,
                        gaps);
            }
            frames = 0;
            endToEndSum = 0;
            endToEndMax = 0;
            transportSum = 0;
            coverageSum = 0;
            depthInMaskSum = 0;
            depthInMaskFrames = 0;
            gaps = 0;
            return line;
        }
    }

    /**
     * Entry point.
     *
     * @param args optional port number; defaults to {@link DepthStreamServer#DEFAULT_PORT}
     */
    public static void main(String[] args) throws IOException, InterruptedException {
        int port = args.length > 0 ? Integer.parseInt(args[0]) : DepthStreamServer.DEFAULT_PORT;
        Stats stats = new Stats();
        try (DepthStreamServer server = new DepthStreamServer(port, stats::add)) {
            server.start();
            System.out.println("[depth] listening on port " + server.port() + "; start the sidecar with: swift run -c release webcam-depth");
            long last = System.nanoTime();
            while (true) {
                Thread.sleep(1000);
                long now = System.nanoTime();
                double seconds = (now - last) / 1e9;
                last = now;
                System.out.println(stats.drainLine(seconds, server.isConnected()));
            }
        }
    }
}
