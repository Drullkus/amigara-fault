package dev.drullkus.amigara.depth;

import java.io.BufferedInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketException;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.Consumer;
import org.jspecify.annotations.Nullable;

/**
 * Listens on a TCP port for the depth sidecar and keeps the newest frame.
 *
 * <p>One sidecar connects at a time. When the sidecar disconnects, the server waits for the next
 * connection. {@link #latest()} always returns the newest complete frame, so a render loop can poll
 * it at its own rate. An optional listener runs on the reader thread for every frame; keep it fast.
 *
 * <p>Written by Claude Code; conversation transcript: {@code llm/transcripts/transcript_2026-10-20_06-06_cf6a8f39-437b-4cd7-9962-fcfbb1efa030.md}.
 */
public final class DepthStreamServer implements AutoCloseable {

    /** Port the sidecar connects to when started with its defaults. */
    public static final int DEFAULT_PORT = 47011;

    private final ServerSocket serverSocket;
    private final @Nullable Consumer<DepthFrame> listener;
    private final AtomicReference<@Nullable DepthFrame> latest = new AtomicReference<>();
    private final AtomicLong framesReceived = new AtomicLong();
    private final Thread acceptThread;
    private volatile boolean connected;
    private volatile boolean closed;

    /**
     * Binds the port but does not accept yet. Call {@link #start()}.
     *
     * @param port     TCP port to listen on, on every local address
     * @param listener called on the reader thread for each frame, or null
     */
    public DepthStreamServer(int port, @Nullable Consumer<DepthFrame> listener) throws IOException {
        this.serverSocket = new ServerSocket(port);
        this.listener = listener;
        this.acceptThread = Thread.ofPlatform().name("depth-stream-accept").daemon(true).unstarted(this::acceptLoop);
    }

    /** Starts accepting connections on a background thread. */
    public void start() {
        acceptThread.start();
    }

    /** The newest complete frame, or null before the first frame arrives. */
    public @Nullable DepthFrame latest() {
        return latest.get();
    }

    /** Count of frames received since start, over all connections. */
    public long framesReceived() {
        return framesReceived.get();
    }

    /** True while a sidecar is connected. */
    public boolean isConnected() {
        return connected;
    }

    /** Port this server listens on. */
    public int port() {
        return serverSocket.getLocalPort();
    }

    private void acceptLoop() {
        while (!closed) {
            try (Socket socket = serverSocket.accept()) {
                socket.setTcpNoDelay(true);
                socket.setReceiveBufferSize(4 << 20);
                System.err.println("[depth] sidecar connected from " + socket.getRemoteSocketAddress());
                connected = true;
                readLoop(new BufferedInputStream(socket.getInputStream(), 1 << 20));
            } catch (SocketException e) {
                if (closed) {
                    return;
                }
                System.err.println("[depth] socket error: " + e.getMessage());
            } catch (IOException e) {
                System.err.println("[depth] sidecar disconnected: " + e.getMessage());
            } finally {
                connected = false;
            }
        }
    }

    private void readLoop(InputStream in) throws IOException {
        DepthFrameCodec codec = new DepthFrameCodec();
        while (!closed) {
            DepthFrame frame = codec.read(in);
            latest.set(frame);
            framesReceived.incrementAndGet();
            if (listener != null) {
                listener.accept(frame);
            }
        }
    }

    /** Stops accepting, drops the current connection and frees the port. */
    @Override
    public void close() throws IOException {
        closed = true;
        serverSocket.close();
    }
}
