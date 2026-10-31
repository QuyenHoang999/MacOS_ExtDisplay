package com.qhpersonalteam.extdisplay

import android.graphics.RectF
import android.view.MotionEvent
import android.view.View
import kotlin.math.max
import kotlin.math.min

/**
 * Translates Android touch, multi-touch scroll, and stylus/S-Pen hover events into
 * normalized (0..1) `ExtDisplayProtocol.InputEvent` packets matching `TouchInputView.swift`.
 */
class TouchInputHandler(
    private val videoRectProvider: () -> RectF,
    private val sendInput: (ExtDisplayProtocol.InputEvent) -> Unit
) : View.OnTouchListener, View.OnHoverListener {

    private var prevScrollX = 0f
    private var prevScrollY = 0f
    private var isTwoFingerScrolling = false

    override fun onTouch(v: View, event: MotionEvent): Boolean {
        val rect = videoRectProvider()
        if (rect.width() <= 0f || rect.height() <= 0f) return true

        val pointerType = when (event.getToolType(0)) {
            MotionEvent.TOOL_TYPE_STYLUS -> ExtDisplayProtocol.InputPointer.PENCIL
            MotionEvent.TOOL_TYPE_MOUSE -> ExtDisplayProtocol.InputPointer.MOUSE
            else -> ExtDisplayProtocol.InputPointer.FINGER
        }

        // Two-finger pan -> macOS smooth scroll wheel
        if (event.pointerCount >= 2) {
            val avgX = (event.getX(0) + event.getX(1)) * 0.5f
            val avgY = (event.getY(0) + event.getY(1)) * 0.5f
            val (nx, ny) = normalize(avgX, avgY, rect)

            when (event.actionMasked) {
                MotionEvent.ACTION_POINTER_DOWN -> {
                    isTwoFingerScrolling = true
                    prevScrollX = avgX
                    prevScrollY = avgY
                }
                MotionEvent.ACTION_MOVE -> {
                    if (isTwoFingerScrolling) {
                        val dx = (avgX - prevScrollX) / rect.width()
                        val dy = (avgY - prevScrollY) / rect.height()
                        prevScrollX = avgX
                        prevScrollY = avgY
                        sendInput(
                            ExtDisplayProtocol.InputEvent(
                                kind = ExtDisplayProtocol.InputKind.SCROLL,
                                pointer = ExtDisplayProtocol.InputPointer.FINGER,
                                x = nx,
                                y = ny,
                                pressure = 1f,
                                dx = dx,
                                dy = dy
                            )
                        )
                    }
                }
                MotionEvent.ACTION_POINTER_UP, MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    isTwoFingerScrolling = false
                }
            }
            return true
        }

        if (isTwoFingerScrolling) {
            if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) {
                isTwoFingerScrolling = false
            }
            return true
        }

        val (nx, ny) = normalize(event.x, event.y, rect)
        val pressure = event.pressure.coerceIn(0.05f, 1f)

        val kind = when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> ExtDisplayProtocol.InputKind.DOWN
            MotionEvent.ACTION_MOVE -> ExtDisplayProtocol.InputKind.MOVE
            MotionEvent.ACTION_UP -> ExtDisplayProtocol.InputKind.UP
            MotionEvent.ACTION_CANCEL -> ExtDisplayProtocol.InputKind.CANCEL
            else -> return true
        }

        sendInput(
            ExtDisplayProtocol.InputEvent(
                kind = kind,
                pointer = pointerType,
                x = nx,
                y = ny,
                pressure = pressure
            )
        )
        return true
    }

    override fun onHover(v: View, event: MotionEvent): Boolean {
        val rect = videoRectProvider()
        if (rect.width() <= 0f || rect.height() <= 0f) return false

        val pointerType = if (event.getToolType(0) == MotionEvent.TOOL_TYPE_STYLUS) {
            ExtDisplayProtocol.InputPointer.PENCIL
        } else {
            ExtDisplayProtocol.InputPointer.MOUSE
        }
        val (nx, ny) = normalize(event.x, event.y, rect)
        sendInput(
            ExtDisplayProtocol.InputEvent(
                kind = ExtDisplayProtocol.InputKind.HOVER,
                pointer = pointerType,
                x = nx,
                y = ny,
                pressure = 0f
            )
        )
        return true
    }

    private fun normalize(x: Float, y: Float, rect: RectF): Pair<Float, Float> {
        val nx = ((x - rect.left) / rect.width()).coerceIn(0f, 1f)
        val ny = ((y - rect.top) / rect.height()).coerceIn(0f, 1f)
        return Pair(nx, ny)
    }
}

