package com.qhpersonalteam.extdisplay

import android.content.res.Configuration
import android.graphics.Color
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.util.DisplayMetrics
import android.util.TypedValue
import android.view.Gravity
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Full-screen immersive Android client activity matching the iOS `ExtDisplayClient` experience:
 * auto-connects over USB-C (`127.0.0.1:50505`), displays the minimal waiting card before streaming,
 * and renders hardware-decoded video full-screen with multi-touch & stylus input once connected.
 */
class MainActivity : AppCompatActivity() {

    private lateinit var rootLayout: FrameLayout
    private lateinit var surfaceView: SurfaceView
    private lateinit var waitingOverlay: View
    private lateinit var statusPillText: TextView
    private lateinit var statusDotView: View

    private lateinit var decoder: VideoDecoder
    private lateinit var session: AndroidClientSession

    private var streamWidth: Int = 0
    private var streamHeight: Int = 0
    private val videoRect = RectF()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }

        decoder = VideoDecoder(
            onFirstFrameRendered = {
                runOnUiThread {
                    waitingOverlay.animate()
                        .alpha(0f)
                        .setDuration(180)
                        .withEndAction { waitingOverlay.visibility = View.GONE }
                        .start()
                }
            },
            onRequestKeyframe = {
                session.requestKeyframe()
            }
        )

        session = AndroidClientSession(
            decoder = decoder,
            onStateChanged = { state, config ->
                runOnUiThread {
                    if (config != null) {
                        streamWidth = config.width
                        streamHeight = config.height
                        updateSurfaceAspectFit()
                    }
                    when (state) {
                        AndroidClientSession.State.WAITING -> {
                            waitingOverlay.alpha = 1f
                            waitingOverlay.visibility = View.VISIBLE
                            statusPillText.text = "Auto-Connecting via USB-C…"
                            setStatusColor(Color.parseColor("#22D3EE"))
                        }
                        AndroidClientSession.State.CONNECTED -> {
                            statusPillText.text = "Connecting over USB-C…"
                            setStatusColor(Color.parseColor("#FB923C"))
                        }
                        AndroidClientSession.State.STREAMING -> {
                            waitingOverlay.visibility = View.GONE
                        }
                    }
                }
            }
        )

        buildUi()
        hideSystemBars()
        session.start()
    }

    override fun onResume() {
        super.onResume()
        hideSystemBars()
        rootLayout.post { reportScreenMetrics() }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        hideSystemBars()
        rootLayout.post {
            reportScreenMetrics()
            updateSurfaceAspectFit()
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        session.stop()
        decoder.releaseCodec()
    }

    private fun buildUi() {
        rootLayout = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
                reportScreenMetrics()
                updateSurfaceAspectFit()
            }
        }

        surfaceView = SurfaceView(this).apply {
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
                Gravity.CENTER
            )
            holder.addCallback(object : SurfaceHolder.Callback {
                override fun surfaceCreated(holder: SurfaceHolder) {
                    decoder.setSurface(holder.surface)
                }

                override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                    decoder.setSurface(holder.surface)
                }

                override fun surfaceDestroyed(holder: SurfaceHolder) {
                    decoder.setSurface(null)
                }
            })
        }

        val inputHandler = TouchInputHandler(
            videoRectProvider = { videoRect },
            sendInput = { event -> session.sendInput(event) }
        )
        rootLayout.setOnTouchListener(inputHandler)
        rootLayout.setOnHoverListener(inputHandler)

        waitingOverlay = buildWaitingOverlay()

        rootLayout.addView(surfaceView)
        rootLayout.addView(waitingOverlay)
        setContentView(rootLayout)
    }

    private fun buildWaitingOverlay(): View {
        val container = FrameLayout(this).apply {
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
            background = GradientDrawable(
                GradientDrawable.Orientation.TL_BR,
                intArrayOf(Color.parseColor("#0A0F1F"), Color.parseColor("#03050D"))
            )
        }

        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(36), dp(34), dp(36), dp(34))
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(28).toFloat()
                setColor(Color.argb(14, 255, 255, 255))
                setStroke(dp(1), Color.argb(32, 255, 255, 255))
            }
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER
            )
        }

        val iconView = ImageView(this).apply {
            setImageResource(R.drawable.ic_launcher_foreground)
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(22).toFloat()
                setColor(Color.parseColor("#080F22"))
            }
            layoutParams = LinearLayout.LayoutParams(dp(92), dp(92)).apply {
                bottomMargin = dp(20)
            }
        }

        val titleView = TextView(this).apply {
            text = "ExtDisplay"
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 30f)
            typeface = Typeface.create("sans-serif-rounded", Typeface.BOLD)
            gravity = Gravity.CENTER
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply {
                bottomMargin = dp(10)
            }
        }

        val statusPill = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(14), dp(7), dp(14), dp(7))
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(50).toFloat()
                setColor(Color.argb(18, 255, 255, 255))
                setStroke(dp(1), Color.argb(30, 255, 255, 255))
            }
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply {
                bottomMargin = dp(18)
            }
        }

        statusDotView = View(this).apply {
            layoutParams = LinearLayout.LayoutParams(dp(8), dp(8)).apply {
                rightMargin = dp(8)
            }
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.parseColor("#22D3EE"))
            }
        }

        statusPillText = TextView(this).apply {
            text = "Auto-Connecting via USB-C…"
            setTextColor(Color.argb(225, 255, 255, 255))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        }

        statusPill.addView(statusDotView)
        statusPill.addView(statusPillText)

        val usbBadge = TextView(this).apply {
            text = "USB-C Auto-Connect"
            setTextColor(Color.argb(180, 255, 255, 255))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            setPadding(dp(12), dp(6), dp(12), dp(6))
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(50).toFloat()
                setColor(Color.argb(16, 255, 255, 255))
            }
        }

        card.addView(iconView)
        card.addView(titleView)
        card.addView(statusPill)
        card.addView(usbBadge)
        container.addView(card)
        return container
    }

    private fun setStatusColor(color: Int) {
        statusDotView.background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(color)
        }
    }

    private fun reportScreenMetrics() {
        val dm: DisplayMetrics = resources.displayMetrics
        val w = if (rootLayout.width > 0) rootLayout.width else dm.widthPixels
        val h = if (rootLayout.height > 0) rootLayout.height else dm.heightPixels
        val ppi = ((dm.xdpi + dm.ydpi) * 0.5f).toDouble()
        val refreshRate = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            display?.refreshRate?.roundToInt() ?: 60
        } else {
            @Suppress("DEPRECATION")
            windowManager.defaultDisplay.refreshRate.roundToInt()
        }
        session.updateScreenMetrics(
            widthPx = w,
            heightPx = h,
            scale = dm.density.toDouble().coerceIn(1.5, 3.0),
            ppi = ppi,
            maxFps = refreshRate
        )
    }

    private fun updateSurfaceAspectFit() {
        val containerW = rootLayout.width.toFloat()
        val containerH = rootLayout.height.toFloat()
        if (containerW <= 0f || containerH <= 0f) return

        val contentW = if (streamWidth > 0) streamWidth.toFloat() else containerW
        val contentH = if (streamHeight > 0) streamHeight.toFloat() else containerH
        val scale = min(containerW / contentW, containerH / contentH)
        val fitW = (contentW * scale).roundToInt()
        val fitH = (contentH * scale).roundToInt()

        val left = (containerW - fitW) * 0.5f
        val top = (containerH - fitH) * 0.5f
        videoRect.set(left, top, left + fitW, top + fitH)

        val lp = surfaceView.layoutParams as FrameLayout.LayoutParams
        if (lp.width != fitW || lp.height != fitH) {
            lp.width = fitW
            lp.height = fitH
            lp.gravity = Gravity.CENTER
            surfaceView.layoutParams = lp
        }
    }

    private fun hideSystemBars() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        val controller = WindowInsetsControllerCompat(window, window.decorView)
        controller.hide(WindowInsetsCompat.Type.systemBars())
        controller.systemBarsBehavior =
            WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
    }

    private fun dp(value: Int): Int {
        return TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            value.toFloat(),
            resources.displayMetrics
        ).roundToInt()
    }
}

