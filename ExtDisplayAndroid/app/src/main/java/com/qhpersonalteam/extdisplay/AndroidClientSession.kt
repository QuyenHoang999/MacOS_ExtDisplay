package com.qhpersonalteam.extdisplay

import android.os.Build
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Listens on `127.0.0.1:50505` for `ExtDisplayHost` over USB-C (`adb` tunnel) and drives
 * the handshake, video stream, and touch input pipeline.
 */
class AndroidClientSession(
    private val decoder: VideoDecoder,
    private val onStateChanged: (State, ExtDisplayProtocol.StreamConfig?) -> Unit
) {
    enum class State {
        WAITING,
        CONNECTED,
        STREAMING
    }

    private val running = AtomicBoolean(false)
    private var serverSocket: ServerSocket? = null
    private var activeSocket: Socket? = null
    private var outputStream: DataOutputStream? = null
    private val writerExecutor = Executors.newSingleThreadExecutor()

    @Volatile
    private var latestHello: ExtDisplayProtocol.Hello? = null

    fun start() {
        if (running.getAndSet(true)) return
        Thread({ acceptLoop() }, "ExtDisplay-AcceptLoop").apply {
            isDaemon = true
            start()
        }
    }

    fun stop() {
        running.set(false)
        try {
            activeSocket?.close()
        } catch (_: Exception) {
        }
        try {
            serverSocket?.close()
        } catch (_: Exception) {
        }
    }

    fun updateScreenMetrics(widthPx: Int, heightPx: Int, scale: Double, ppi: Double, maxFps: Int) {
        if (widthPx <= 0 || heightPx <= 0) return
        val model = "${Build.MANUFACTURER.replaceFirstChar { it.uppercase() }} ${Build.MODEL}".trim()
        val hello = ExtDisplayProtocol.Hello(
            deviceName = Build.MODEL.ifEmpty { "Android Display" },
            deviceModel = model,
            nativeWidth = widthPx,
            nativeHeight = heightPx,
            scale = scale.coerceAtLeast(1.0),
            ppi = ppi.coerceIn(120.0, 600.0),
            maxFPS = if (maxFps >= 90) 120 else 60
        )
        val changed = latestHello != hello
        latestHello = hello
        if (changed) {
            sendAsync(ExtDisplayProtocol.MSG_HELLO, hello.toJsonBytes())
        }
    }

    fun sendInput(event: ExtDisplayProtocol.InputEvent) {
        sendAsync(ExtDisplayProtocol.MSG_INPUT, event.encode())
    }

    fun requestKeyframe() {
        sendAsync(ExtDisplayProtocol.MSG_REQUEST_KEYFRAME)
    }

    private fun sendAsync(type: Byte, payload: ByteArray = ByteArray(0)) {
        val out = outputStream ?: return
        writerExecutor.execute {
            try {
                ExtDisplayProtocol.writeMessage(out, type, payload)
            } catch (_: Exception) {
            }
        }
    }

    private fun acceptLoop() {
        while (running.get()) {
            try {
                val server = ServerSocket(ExtDisplayProtocol.PORT, 1, InetAddress.getByName("127.0.0.1")).apply {
                    reuseAddress = true
                }
                serverSocket = server

                while (running.get()) {
                    onStateChanged(State.WAITING, null)
                    val client = server.accept()
                    client.tcpNoDelay = true
                    client.keepAlive = true
                    handleClient(client)
                }
            } catch (_: Exception) {
                if (running.get()) {
                    try {
                        Thread.sleep(1000)
                    } catch (_: InterruptedException) {
                        break
                    }
                }
            } finally {
                try {
                    serverSocket?.close()
                } catch (_: Exception) {
                }
                serverSocket = null
            }
        }
    }

    private fun handleClient(socket: Socket) {
        activeSocket = socket
        val input = DataInputStream(BufferedInputStream(socket.getInputStream(), 256 * 1024))
        val output = DataOutputStream(BufferedOutputStream(socket.getOutputStream(), 64 * 1024))
        outputStream = output

        onStateChanged(State.CONNECTED, null)

        // Immediately send Hello so ExtDisplayHost creates the CGVirtualDisplay
        latestHello?.let { hello ->
            sendAsync(ExtDisplayProtocol.MSG_HELLO, hello.toJsonBytes())
        }

        try {
            while (running.get() && !socket.isClosed) {
                val msg = ExtDisplayProtocol.readMessage(input)
                when (msg.type) {
                    ExtDisplayProtocol.MSG_CONFIG -> {
                        val cfg = ExtDisplayProtocol.StreamConfig.fromJsonBytes(msg.payload)
                        decoder.updateStreamSize(cfg.width, cfg.height)
                        onStateChanged(State.CONNECTED, cfg)
                    }
                    ExtDisplayProtocol.MSG_VIDEO_FORMAT -> {
                        val fmt = ExtDisplayProtocol.VideoFormat.decode(msg.payload)
                        decoder.configure(fmt)
                    }
                    ExtDisplayProtocol.MSG_VIDEO_FRAME -> {
                        decoder.decodeFrame(msg.payload)
                    }
                    ExtDisplayProtocol.MSG_PING -> {
                        sendAsync(ExtDisplayProtocol.MSG_PONG, msg.payload)
                    }
                    ExtDisplayProtocol.MSG_BYE -> {
                        break
                    }
                }
            }
        } catch (_: Exception) {
        } finally {
            outputStream = null
            activeSocket = null
            try {
                socket.close()
            } catch (_: Exception) {
            }
            decoder.reset()
            onStateChanged(State.WAITING, null)
        }
    }
}

