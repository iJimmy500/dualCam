package com.sigmadrive.dualcam.render

import android.graphics.Bitmap
import android.graphics.RectF
import android.graphics.SurfaceTexture
import android.opengl.EGLSurface
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.view.Surface
import com.sigmadrive.dualcam.model.*
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Owns the GL thread. Both camera feeds arrive as SurfaceTexture frames, get
 * composited by [CompositorRenderer], and are fanned out to the on-screen
 * preview, the active video encoder surfaces, and one-shot photo readbacks —
 * the Android counterpart of the iOS app's Core Image merge loop.
 */
class RenderPipeline {

    /** Static description of one camera feed's buffers. */
    data class FeedInfo(
        val bufferWidth: Int,
        val bufferHeight: Int,
        val rotationDegrees: Int,   // CW rotation that makes the buffer upright
        val isFront: Boolean,
    )

    /** Everything the compositor needs to lay out a frame. */
    data class Style(
        val layoutMode: LayoutMode = LayoutMode.PIP,
        val pipShape: PipShape = PipShape.ROUNDED_RECT,
        val frameStyle: PipFrameStyle = PipFrameStyle.GLASS,
        val frameColor: PipFrameColor = PipFrameColor.WHITE,
        val spotlightSplit: SpotlightSplit = SpotlightSplit.STANDARD,
        val spotlightGap: SpotlightGap = SpotlightGap.THIN,
        val pip: PipTransform = PipTransform(),
        val mirrorFront: Boolean = true,
        val swapped: Boolean = false,
        val debugRotationOffsetA: Int = 0,
        val debugRotationOffsetB: Int = 0,
        val debugExtraMirrorA: Boolean = false,
        val debugExtraMirrorB: Boolean = false,
    )

    private class RawEncoder(var eglSurface: EGLSurface, val width: Int, val height: Int)

    private lateinit var thread: HandlerThread
    private lateinit var handler: Handler
    private val mainHandler = Handler(Looper.getMainLooper())

    private val egl = EglCore()
    private val renderer = CompositorRenderer()

    private var surfaceTextureA: SurfaceTexture? = null   // background camera by default
    private var surfaceTextureB: SurfaceTexture? = null   // pip camera by default
    private val stMatrixA = FloatArray(16)
    private val stMatrixB = FloatArray(16)
    private var hasFrameA = false
    private var hasFrameB = false
    private var lastTimestampNs = 0L

    private var bootstrapSurface: EGLSurface? = null
    private var displaySurface: EGLSurface? = null
    private var encoderSurface: EGLSurface? = null
    private var encoderWidth = 0
    private var encoderHeight = 0
    private var rawEncoderA: RawEncoder? = null
    private var rawEncoderB: RawEncoder? = null
    private var photoSurface: EGLSurface? = null
    private var photoSurfaceWidth = 0
    private var photoSurfaceHeight = 0

    private data class FeedBitmapRequest(val isA: Boolean, val callback: (Bitmap) -> Unit)
    private val feedBitmapRequests = mutableListOf<FeedBitmapRequest>()
    private var feedPhotoSurface: EGLSurface? = null
    private var feedPhotoWidth = 0
    private var feedPhotoHeight = 0

    @Volatile private var feedA: FeedInfo? = null
    @Volatile private var feedB: FeedInfo? = null
    @Volatile var style = Style()

    private var canvasWidth = 1080
    private var canvasHeight = 1920
    private var photoRequest: ((Bitmap) -> Unit)? = null

    private var frameCount = 0
    private var fpsWindowStart = 0L
    var onFps: ((Int) -> Unit)? = null

    /** Starts the GL thread and hands back the two camera target surfaces. */
    fun start(onSurfacesReady: (background: Surface, pip: Surface) -> Unit) {
        thread = HandlerThread("dualcam-render").also { it.start() }
        handler = Handler(thread.looper)
        handler.post {
            egl.setup()
            bootstrapSurface = egl.createPbufferSurface(1, 1)
            egl.makeCurrent(bootstrapSurface!!)
            renderer.setup()

            val stA = SurfaceTexture(renderer.oesTextureBackground)
            val stB = SurfaceTexture(renderer.oesTexturePip)
            surfaceTextureA = stA
            surfaceTextureB = stB
            stA.setOnFrameAvailableListener({ onFrame(it, isA = true) }, handler)
            stB.setOnFrameAvailableListener({ onFrame(it, isA = false) }, handler)
            val a = Surface(stA)
            val b = Surface(stB)
            mainHandler.post { onSurfacesReady(a, b) }
        }
    }

    fun setCanvasSize(width: Int, height: Int) = handler.post {
        canvasWidth = width
        canvasHeight = height
    }

    fun setFeeds(background: FeedInfo, pip: FeedInfo) = handler.post {
        feedA = background
        feedB = pip
        surfaceTextureA?.setDefaultBufferSize(background.bufferWidth, background.bufferHeight)
        surfaceTextureB?.setDefaultBufferSize(pip.bufferWidth, pip.bufferHeight)
        hasFrameA = false
        hasFrameB = false
    }

    fun setDisplaySurface(surface: Surface?) = handler.post {
        displaySurface?.let { egl.releaseSurface(it) }
        displaySurface = surface?.let { egl.createWindowSurface(it) }
    }

    fun attachEncoder(surface: Surface, width: Int, height: Int) = handler.post {
        encoderSurface = egl.createWindowSurface(surface)
        encoderWidth = width
        encoderHeight = height
    }

    fun attachRawEncoders(
        surfaceA: Surface, widthA: Int, heightA: Int,
        surfaceB: Surface, widthB: Int, heightB: Int,
    ) = handler.post {
        rawEncoderA = RawEncoder(egl.createWindowSurface(surfaceA), widthA, heightA)
        rawEncoderB = RawEncoder(egl.createWindowSurface(surfaceB), widthB, heightB)
    }

    fun detachEncoders() = handler.post {
        encoderSurface?.let { egl.releaseSurface(it) }
        encoderSurface = null
        rawEncoderA?.let { egl.releaseSurface(it.eglSurface) }
        rawEncoderB?.let { egl.releaseSurface(it.eglSurface) }
        rawEncoderA = null
        rawEncoderB = null
    }

    /** Captures the next composited frame as a Bitmap (delivered on main thread). */
    fun requestPhoto(callback: (Bitmap) -> Unit) = handler.post {
        photoRequest = callback
    }

    /**
     * Captures a single feed (background or pip), aspect-filled to the full
     * canvas with no compositing, as a Bitmap (delivered on main thread).
     * Used for delayed dual capture, where each camera is photographed
     * separately and composited offline afterwards.
     */
    fun requestFeedBitmap(isA: Boolean, callback: (Bitmap) -> Unit) = handler.post {
        feedBitmapRequests.add(FeedBitmapRequest(isA, callback))
    }

    fun updateStyle(new: Style) {
        style = new
    }

    fun stop() {
        if (!::handler.isInitialized) return
        handler.post {
            surfaceTextureA?.release()
            surfaceTextureB?.release()
            surfaceTextureA = null
            surfaceTextureB = null
            detachEncodersLocked()
            displaySurface?.let { egl.releaseSurface(it) }
            photoSurface?.let { egl.releaseSurface(it) }
            feedPhotoSurface?.let { egl.releaseSurface(it) }
            bootstrapSurface?.let { egl.releaseSurface(it) }
            renderer.release()
            egl.release()
            thread.quitSafely()
        }
    }

    private fun detachEncodersLocked() {
        encoderSurface?.let { egl.releaseSurface(it) }
        encoderSurface = null
        rawEncoderA?.let { egl.releaseSurface(it.eglSurface) }
        rawEncoderB?.let { egl.releaseSurface(it.eglSurface) }
        rawEncoderA = null
        rawEncoderB = null
    }

    // MARK: Frame handling (render thread)

    private fun onFrame(st: SurfaceTexture, isA: Boolean) {
        // The texture is bound to the shared context; any current surface works.
        val anchor = displaySurface ?: bootstrapSurface ?: return
        egl.makeCurrent(anchor)
        try {
            st.updateTexImage()
        } catch (_: RuntimeException) {
            return // released mid-frame
        }
        if (isA) {
            st.getTransformMatrix(stMatrixA)
            hasFrameA = true
        } else {
            st.getTransformMatrix(stMatrixB)
            hasFrameB = true
        }

        // Drive output at the rate of whichever camera is currently full-screen.
        val backgroundIsA = !style.swapped
        if (isA == backgroundIsA) {
            lastTimestampNs = st.timestamp
            renderAll()
        }
    }

    private fun renderAll() {
        if (!hasFrameA || feedA == null || feedB == null) return

        displaySurface?.let { surf ->
            egl.makeCurrent(surf)
            drawScene(egl.surfaceWidth(surf), egl.surfaceHeight(surf))
            egl.swapBuffers(surf)
            tickFps()
        }

        encoderSurface?.let { surf ->
            egl.makeCurrent(surf)
            drawScene(encoderWidth, encoderHeight)
            egl.setPresentationTime(surf, lastTimestampNs)
            egl.swapBuffers(surf)
        }

        rawEncoderA?.let { drawRaw(it, isA = true) }
        rawEncoderB?.let { drawRaw(it, isA = false) }

        photoRequest?.let { callback ->
            photoRequest = null
            if (photoSurface != null &&
                (photoSurfaceWidth != canvasWidth || photoSurfaceHeight != canvasHeight)
            ) {
                egl.releaseSurface(photoSurface!!)
                photoSurface = null
            }
            val surf = photoSurface ?: egl.createPbufferSurface(canvasWidth, canvasHeight).also {
                photoSurface = it
                photoSurfaceWidth = canvasWidth
                photoSurfaceHeight = canvasHeight
            }
            egl.makeCurrent(surf)
            drawScene(canvasWidth, canvasHeight)
            val bitmap = readPixels(canvasWidth, canvasHeight)
            mainHandler.post { callback(bitmap) }
        }

        if (feedBitmapRequests.isNotEmpty()) {
            val pending = feedBitmapRequests.toList()
            feedBitmapRequests.clear()
            if (feedPhotoSurface != null &&
                (feedPhotoWidth != canvasWidth || feedPhotoHeight != canvasHeight)
            ) {
                egl.releaseSurface(feedPhotoSurface!!)
                feedPhotoSurface = null
            }
            val surf = feedPhotoSurface ?: egl.createPbufferSurface(canvasWidth, canvasHeight).also {
                feedPhotoSurface = it
                feedPhotoWidth = canvasWidth
                feedPhotoHeight = canvasHeight
            }
            val s = style
            for (req in pending) {
                val feed = (if (req.isA) feedA else feedB) ?: continue
                if (!req.isA && !hasFrameB) continue
                egl.makeCurrent(surf)
                renderer.beginFrame(canvasWidth, canvasHeight)
                renderer.drawCamera(
                    textureId = if (req.isA) renderer.oesTextureBackground else renderer.oesTexturePip,
                    stMatrix = if (req.isA) stMatrixA else stMatrixB,
                    srcWidth = feed.bufferWidth, srcHeight = feed.bufferHeight,
                    rotationDegrees = effRotation(req.isA, s),
                    mirror = effMirror(req.isA, feed.isFront && s.mirrorFront, s),
                    dstRect = RectF(0f, 0f, canvasWidth.toFloat(), canvasHeight.toFloat()),
                    canvasWidth = canvasWidth, canvasHeight = canvasHeight,
                )
                val bitmap = readPixels(canvasWidth, canvasHeight)
                mainHandler.post { req.callback(bitmap) }
            }
        }
    }

    /**
     * SurfaceTexture's transform matrix already corrects for sensor rotation,
     * so the manual rotation defaults to identity (0). [feed.rotationDegrees]
     * is informational only; per-camera debug offsets remain available for
     * devices that need a different correction.
     */
    private fun effRotation(isA: Boolean, s: Style): Int {
        val offset = if (isA) s.debugRotationOffsetA else s.debugRotationOffsetB
        return ((offset % 360) + 360) % 360
    }

    private fun effMirror(isA: Boolean, mirror: Boolean, s: Style): Boolean {
        val extra = if (isA) s.debugExtraMirrorA else s.debugExtraMirrorB
        return mirror xor extra
    }

    private fun drawRaw(enc: RawEncoder, isA: Boolean) {
        val feed = (if (isA) feedA else feedB) ?: return
        if (!isA && !hasFrameB) return
        val s = style
        egl.makeCurrent(enc.eglSurface)
        renderer.beginFrame(enc.width, enc.height)
        renderer.drawCamera(
            textureId = if (isA) renderer.oesTextureBackground else renderer.oesTexturePip,
            stMatrix = if (isA) stMatrixA else stMatrixB,
            srcWidth = feed.bufferWidth, srcHeight = feed.bufferHeight,
            rotationDegrees = effRotation(isA, s),
            mirror = effMirror(isA, feed.isFront && s.mirrorFront, s),
            dstRect = RectF(0f, 0f, enc.width.toFloat(), enc.height.toFloat()),
            canvasWidth = enc.width, canvasHeight = enc.height,
        )
        egl.setPresentationTime(enc.eglSurface, lastTimestampNs)
        egl.swapBuffers(enc.eglSurface)
    }

    private fun drawScene(w: Int, h: Int) {
        val s = style
        val (bgTex, bgMatrix, bgFeed) = if (s.swapped)
            Triple(renderer.oesTexturePip, stMatrixB, feedB!!)
        else
            Triple(renderer.oesTextureBackground, stMatrixA, feedA!!)
        val (pipTex, pipMatrix, pipFeed) = if (s.swapped)
            Triple(renderer.oesTextureBackground, stMatrixA, feedA!!)
        else
            Triple(renderer.oesTexturePip, stMatrixB, feedB!!)
        val pipReady = if (s.swapped) hasFrameA else hasFrameB
        val bgIsA = !s.swapped
        val pipIsA = s.swapped

        renderer.beginFrame(w, h)
        val px = w / 390f  // ~1dp on a typical phone, used for iOS-point-based metrics

        when (s.layoutMode) {
            LayoutMode.PIP -> {
                renderer.drawCamera(
                    bgTex, bgMatrix, bgFeed.bufferWidth, bgFeed.bufferHeight,
                    effRotation(bgIsA, s), effMirror(bgIsA, bgFeed.isFront && s.mirrorFront, s),
                    RectF(0f, 0f, w.toFloat(), h.toFloat()), w, h,
                )
                if (pipReady) {
                    val pw = s.pip.width * w
                    val ph = if (s.pipShape == PipShape.CIRCLE) pw else pw * 4f / 3f
                    val cx = s.pip.cx * w
                    val cy = s.pip.cy * h
                    val rect = RectF(cx - pw / 2, cy - ph / 2, cx + pw / 2, cy + ph / 2)
                    val radius = if (s.pipShape == PipShape.CIRCLE) pw / 2 else 20f * px
                    val c = s.frameColor.color
                    val glowPad =
                        if (s.frameStyle == PipFrameStyle.GLOW || s.frameStyle == PipFrameStyle.NEON)
                            28f * px else 0f
                    renderer.drawCamera(
                        pipTex, pipMatrix, pipFeed.bufferWidth, pipFeed.bufferHeight,
                        effRotation(pipIsA, s), effMirror(pipIsA, pipFeed.isFront && s.mirrorFront, s),
                        rect, w, h,
                        mask = CompositorRenderer.Mask(
                            radius, s.frameStyle, c.red, c.green, c.blue, c.alpha
                        ),
                        glowPadPx = glowPad,
                    )
                }
            }

            LayoutMode.SPOTLIGHT -> {
                val gap = s.spotlightGap.dp * px
                val mainH = (h - gap) * s.spotlightSplit.mainFraction
                val corner = if (gap > 0f) 18f * px else 0f
                fun pane(rect: RectF, tex: Int, m: FloatArray, feed: FeedInfo, isA: Boolean) {
                    renderer.drawCamera(
                        tex, m, feed.bufferWidth, feed.bufferHeight,
                        effRotation(isA, s), effMirror(isA, feed.isFront && s.mirrorFront, s),
                        rect, w, h,
                        mask = CompositorRenderer.Mask(
                            corner, PipFrameStyle.NONE, 0f, 0f, 0f, 0f
                        ),
                    )
                }
                pane(RectF(0f, 0f, w.toFloat(), mainH), bgTex, bgMatrix, bgFeed, bgIsA)
                if (pipReady) {
                    pane(RectF(0f, mainH + gap, w.toFloat(), h.toFloat()), pipTex, pipMatrix, pipFeed, pipIsA)
                }
            }
        }
    }

    private fun readPixels(w: Int, h: Int): Bitmap {
        val buffer = ByteBuffer.allocateDirect(w * h * 4).order(ByteOrder.nativeOrder())
        GLES20.glReadPixels(0, 0, w, h, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, buffer)
        buffer.rewind()
        val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        bitmap.copyPixelsFromBuffer(buffer)
        // GL reads bottom-up; flip to image orientation
        val matrix = android.graphics.Matrix().apply { postScale(1f, -1f) }
        val flipped = Bitmap.createBitmap(bitmap, 0, 0, w, h, matrix, false)
        bitmap.recycle()
        return flipped
    }

    private fun tickFps() {
        frameCount++
        val now = System.nanoTime()
        if (now - fpsWindowStart >= 1_000_000_000L) {
            val fps = frameCount
            frameCount = 0
            fpsWindowStart = now
            onFps?.let { cb -> mainHandler.post { cb(fps) } }
        }
    }
}
