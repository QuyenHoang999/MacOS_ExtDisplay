package com.qhpersonalteam.extdisplay

import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Exact wire-protocol implementation matching `ExtDisplayKit` on macOS (`Message.swift` & `FrameCodec.swift`).
 *
 * Every frame on the TCP stream is big-endian length-prefixed:
 * `[UInt32 BE length (1 + payload.size)][UInt8 MessageType][payload]`
 */
object ExtDisplayProtocol {
    const val PROTOCOL_VERSION = 1
    const val PORT = 50505
    const val MAX_FRAME_SIZE = 32 * 1024 * 1024

    // MessageType raw values
    const val MSG_HELLO: Byte = 1
    const val MSG_CONFIG: Byte = 2
    const val MSG_VIDEO_FORMAT: Byte = 3
    const val MSG_VIDEO_FRAME: Byte = 4
    const val MSG_INPUT: Byte = 5
    const val MSG_REQUEST_KEYFRAME: Byte = 6
    const val MSG_PING: Byte = 7
    const val MSG_PONG: Byte = 8
    const val MSG_BYE: Byte = 9

    data class Message(val type: Byte, val payload: ByteArray = ByteArray(0))

    data class Hello(
        val protocolVersion: Int = PROTOCOL_VERSION,
        val deviceName: String,
        val deviceModel: String,
        val nativeWidth: Int,
        val nativeHeight: Int,
        val scale: Double,
        val ppi: Double,
        val maxFPS: Int
    ) {
        fun toJsonBytes(): ByteArray {
            val obj = JSONObject().apply {
                put("protocolVersion", protocolVersion)
                put("deviceName", deviceName)
                put("deviceModel", deviceModel)
                put("nativeWidth", nativeWidth)
                put("nativeHeight", nativeHeight)
                put("scale", scale)
                put("ppi", ppi)
                put("maxFPS", maxFPS)
            }
            return obj.toString().toByteArray(Charsets.UTF_8)
        }
    }

    data class StreamConfig(
        val width: Int,
        val height: Int,
        val fps: Int,
        val codec: String,
        val pointsWide: Int,
        val pointsHigh: Int
    ) {
        val isHevc: Boolean get() = codec.equals("hevc", ignoreCase = true)

        companion object {
            fun fromJsonBytes(bytes: ByteArray): StreamConfig {
                val obj = JSONObject(String(bytes, Charsets.UTF_8))
                return StreamConfig(
                    width = obj.getInt("width"),
                    height = obj.getInt("height"),
                    fps = obj.getInt("fps"),
                    codec = obj.getString("codec"),
                    pointsWide = obj.getInt("pointsWide"),
                    pointsHigh = obj.getInt("pointsHigh")
                )
            }
        }
    }

    data class VideoFormat(
        val isHevc: Boolean,
        val nalLengthSize: Int,
        val parameterSets: List<ByteArray>
    ) {
        companion object {
            fun decode(payload: ByteArray): VideoFormat {
                val buf = ByteBuffer.wrap(payload).order(ByteOrder.BIG_ENDIAN)
                val isHevc = (buf.get().toInt() and 0xFF) == 1
                val nalLenSize = buf.get().toInt() and 0xFF
                val count = buf.get().toInt() and 0xFF
                val sets = ArrayList<ByteArray>(count)
                for (i in 0 until count) {
                    val len = buf.int
                    val ps = ByteArray(len)
                    buf.get(ps)
                    sets.add(ps)
                }
                return VideoFormat(isHevc, nalLenSize, sets)
            }
        }
    }

    data class VideoFrameHeader(
        val ptsMicros: Long,
        val isKeyframe: Boolean,
        val captureToSendMicros: Long,
        val dataOffset: Int
    ) {
        companion object {
            const val HEADER_SIZE = 13

            fun decode(payload: ByteArray): VideoFrameHeader {
                val buf = ByteBuffer.wrap(payload, 0, HEADER_SIZE).order(ByteOrder.BIG_ENDIAN)
                val pts = buf.long
                val flags = buf.get().toInt() and 0xFF
                val c2s = buf.int.toLong() and 0xFFFFFFFFL
                return VideoFrameHeader(
                    ptsMicros = pts,
                    isKeyframe = (flags and 1) != 0,
                    captureToSendMicros = c2s,
                    dataOffset = HEADER_SIZE
                )
            }
        }
    }

    object InputKind {
        const val DOWN: Byte = 0
        const val MOVE: Byte = 1
        const val UP: Byte = 2
        const val HOVER: Byte = 3
        const val SCROLL: Byte = 4
        const val RIGHT_CLICK: Byte = 5
        const val CANCEL: Byte = 6
    }

    object InputPointer {
        const val FINGER: Byte = 0
        const val PENCIL: Byte = 1
        const val MOUSE: Byte = 2
    }

    data class InputEvent(
        val kind: Byte,
        val pointer: Byte,
        val x: Float,
        val y: Float,
        val pressure: Float = 1f,
        val dx: Float = 0f,
        val dy: Float = 0f
    ) {
        fun encode(): ByteArray {
            val buf = ByteBuffer.allocate(24).order(ByteOrder.BIG_ENDIAN)
            buf.put(kind)
            buf.put(pointer)
            buf.putShort(0)
            buf.putFloat(x)
            buf.putFloat(y)
            buf.putFloat(pressure)
            buf.putFloat(dx)
            buf.putFloat(dy)
            return buf.array()
        }
    }

    fun readMessage(input: DataInputStream): Message {
        val length = input.readInt()
        if (length < 1 || length > MAX_FRAME_SIZE) {
            throw EOFException("Invalid frame length: $length")
        }
        val type = input.readByte()
        val payload = ByteArray(length - 1)
        if (payload.isNotEmpty()) {
            input.readFully(payload)
        }
        return Message(type, payload)
    }

    @Synchronized
    fun writeMessage(output: DataOutputStream, type: Byte, payload: ByteArray = ByteArray(0)) {
        output.writeInt(payload.size + 1)
        output.writeByte(type.toInt())
        if (payload.isNotEmpty()) {
            output.write(payload)
        }
        output.flush()
    }
}

