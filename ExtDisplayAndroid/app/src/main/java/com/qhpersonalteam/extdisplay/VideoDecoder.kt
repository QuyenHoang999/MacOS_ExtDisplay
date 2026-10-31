package com.qhpersonalteam.extdisplay

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.view.Surface
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Hardware-accelerated low-latency HEVC / H.264 decoder rendering directly into a `Surface`.
 * Converts 4-byte length-prefixed VideoToolbox NAL units into Annex-B (`0x00 0x00 0x00 0x01`)
 * for Android's `MediaCodec`.
 */
class VideoDecoder(
    private val onFirstFrameRendered: () -> Unit,
    private val onRequestKeyframe: () -> Unit
) {
    private var codec: MediaCodec? = null
    private var surface: Surface? = null
    private var streamWidth: Int = 1920
    private var streamHeight: Int = 1080
    private var currentFormat: ExtDisplayProtocol.VideoFormat? = null
    private var hasRenderedFirstFrame = false
    private var needsKeyframe = true
    private val bufferInfo = MediaCodec.BufferInfo()

    @Synchronized
    fun setSurface(newSurface: Surface?) {
        surface = newSurface
        if (newSurface != null && currentFormat != null) {
            reconfigureCodec()
            onRequestKeyframe()
        } else if (newSurface == null) {
            releaseCodec()
        }
    }

    @Synchronized
    fun updateStreamSize(width: Int, height: Int) {
        if (width > 0 && height > 0) {
            streamWidth = width
            streamHeight = height
        }
    }

    @Synchronized
    fun configure(format: ExtDisplayProtocol.VideoFormat) {
        currentFormat = format
        if (surface != null) {
            reconfigureCodec()
        }
    }

    @Synchronized
    private fun reconfigureCodec() {
        val fmt = currentFormat ?: return
        val targetSurface = surface ?: return
        if (!targetSurface.isValid) return

        releaseCodec()

        try {
            val mime = if (fmt.isHevc) MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC
            val mediaFormat = MediaFormat.createVideoFormat(mime, streamWidth, streamHeight)

            // Combine VPS/SPS/PPS parameter sets with Annex-B start codes into csd-0
            val csdOut = ByteArrayOutputStream(256)
            val startCode = byteArrayOf(0, 0, 0, 1)
            for (ps in fmt.parameterSets) {
                csdOut.write(startCode)
                csdOut.write(ps)
            }
            mediaFormat.setByteBuffer("csd-0", ByteBuffer.wrap(csdOut.toByteArray()))

            // Request hardware low-latency & real-time priority
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                mediaFormat.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
            mediaFormat.setInteger(MediaFormat.KEY_PRIORITY, 0)
            mediaFormat.setInteger(MediaFormat.KEY_OPERATING_RATE, 120)

            val mc = MediaCodec.createDecoderByType(mime)
            mc.configure(mediaFormat, targetSurface, null, 0)
            mc.start()
            codec = mc
            needsKeyframe = true
        } catch (e: Exception) {
            releaseCodec()
            onRequestKeyframe()
        }
    }

    @Synchronized
    fun decodeFrame(payload: ByteArray) {
        if (payload.size <= ExtDisplayProtocol.VideoFrameHeader.HEADER_SIZE) return
        val header = ExtDisplayProtocol.VideoFrameHeader.decode(payload)

        if (needsKeyframe && !header.isKeyframe) {
            onRequestKeyframe()
            return
        }

        val mc = codec ?: run {
            onRequestKeyframe()
            return
        }
        val fmt = currentFormat ?: return

        try {
            val inputIndex = mc.dequeueInputBuffer(4_000)
            if (inputIndex < 0) {
                drainOutput(mc)
                needsKeyframe = true
                onRequestKeyframe()
                return
            }

            val inputBuf = mc.getInputBuffer(inputIndex) ?: return
            inputBuf.clear()

            val bytesWritten = writeLengthPrefixedNalsAsAnnexB(
                src = payload,
                offset = header.dataOffset,
                nalLengthSize = fmt.nalLengthSize,
                dst = inputBuf
            )
            if (bytesWritten <= 0) {
                mc.queueInputBuffer(inputIndex, 0, 0, 0, 0)
                return
            }

            val flags = if (header.isKeyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
            mc.queueInputBuffer(inputIndex, 0, bytesWritten, header.ptsMicros, flags)
            needsKeyframe = false

            drainOutput(mc)
        } catch (e: Exception) {
            needsKeyframe = true
            reconfigureCodec()
            onRequestKeyframe()
        }
    }

    private fun drainOutput(mc: MediaCodec) {
        while (true) {
            val outIndex = mc.dequeueOutputBuffer(bufferInfo, 0)
            if (outIndex >= 0) {
                mc.releaseOutputBuffer(outIndex, true)
                if (!hasRenderedFirstFrame) {
                    hasRenderedFirstFrame = true
                    onFirstFrameRendered()
                }
            } else if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                // Output format updated; continue draining
            } else {
                break
            }
        }
    }

    private fun writeLengthPrefixedNalsAsAnnexB(
        src: ByteArray,
        offset: Int,
        nalLengthSize: Int,
        dst: ByteBuffer
    ): Int {
        var pos = offset
        val end = src.size
        var total = 0
        val wrap = ByteBuffer.wrap(src).order(ByteOrder.BIG_ENDIAN)

        while (pos + nalLengthSize <= end) {
            val nalLen = when (nalLengthSize) {
                4 -> wrap.getInt(pos)
                2 -> wrap.getShort(pos).toInt() and 0xFFFF
                1 -> src[pos].toInt() and 0xFF
                else -> wrap.getInt(pos)
            }
            pos += nalLengthSize
            if (nalLen <= 0 || pos + nalLen > end) break
            if (dst.remaining() < 4 + nalLen) break

            dst.put(0)
            dst.put(0)
            dst.put(0)
            dst.put(1)
            dst.put(src, pos, nalLen)
            pos += nalLen
            total += 4 + nalLen
        }
        return total
    }

    @Synchronized
    fun reset() {
        hasRenderedFirstFrame = false
        needsKeyframe = true
        currentFormat = null
        releaseCodec()
    }

    @Synchronized
    fun releaseCodec() {
        try {
            codec?.stop()
        } catch (_: Exception) {
        }
        try {
            codec?.release()
        } catch (_: Exception) {
        }
        codec = null
    }
}

