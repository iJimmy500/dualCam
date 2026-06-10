package com.sigmadrive.dualcam.render

import android.graphics.Bitmap
import android.graphics.BlurMaskFilter
import android.graphics.Canvas
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.RectF
import androidx.compose.ui.graphics.toArgb
import com.sigmadrive.dualcam.model.LayoutMode
import com.sigmadrive.dualcam.model.PipFrameColor
import com.sigmadrive.dualcam.model.PipFrameStyle
import com.sigmadrive.dualcam.model.PipShape

/**
 * Offline counterpart to [CompositorRenderer]'s live PiP/Spotlight layouts,
 * used by delayed dual capture: [bg] and [pip] are full-canvas, aspect-filled
 * single-feed bitmaps (same size) captured a few seconds apart, and are
 * combined here into the same styled layout the live preview shows.
 */
object DelayedDualComposer {

    fun compose(bg: Bitmap, pip: Bitmap, style: RenderPipeline.Style): Bitmap {
        val w = bg.width
        val h = bg.height
        val out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        val px = w / 390f

        when (style.layoutMode) {
            LayoutMode.PIP -> {
                canvas.drawBitmap(bg, 0f, 0f, null)
                val pw = style.pip.width * w
                val ph = if (style.pipShape == PipShape.CIRCLE) pw else pw * 4f / 3f
                val cx = style.pip.cx * w
                val cy = style.pip.cy * h
                val rect = RectF(cx - pw / 2, cy - ph / 2, cx + pw / 2, cy + ph / 2)
                val radius = if (style.pipShape == PipShape.CIRCLE) pw / 2 else 20f * px
                val isCircle = style.pipShape == PipShape.CIRCLE
                val path = roundedPath(rect, radius, isCircle)
                drawAspectFill(canvas, pip, rect, path)
                drawFrame(canvas, rect, radius, isCircle, style.frameStyle, style.frameColor, w)
            }

            LayoutMode.SPOTLIGHT -> {
                val gap = style.spotlightGap.dp * px
                val mainH = (h - gap) * style.spotlightSplit.mainFraction
                val corner = if (gap > 0f) 18f * px else 0f
                val topRect = RectF(0f, 0f, w.toFloat(), mainH)
                val bottomRect = RectF(0f, mainH + gap, w.toFloat(), h.toFloat())
                drawAspectFill(canvas, bg, topRect, roundedPath(topRect, corner, false))
                drawAspectFill(canvas, pip, bottomRect, roundedPath(bottomRect, corner, false))
            }
        }
        return out
    }

    private fun roundedPath(rect: RectF, radius: Float, circle: Boolean): Path = Path().apply {
        if (circle) addOval(rect, Path.Direction.CW)
        else addRoundRect(rect, radius, radius, Path.Direction.CW)
    }

    /** Aspect-fill draws [src] into [dst], clipped to [clip]. */
    private fun drawAspectFill(canvas: Canvas, src: Bitmap, dst: RectF, clip: Path) {
        val srcRatio = src.width.toFloat() / src.height
        val dstRatio = dst.width() / dst.height()
        val srcRect = if (srcRatio > dstRatio) {
            val cropW = (src.height * dstRatio).toInt().coerceIn(1, src.width)
            val x = (src.width - cropW) / 2
            Rect(x, 0, x + cropW, src.height)
        } else {
            val cropH = (src.width / dstRatio).toInt().coerceIn(1, src.height)
            val y = (src.height - cropH) / 2
            Rect(0, y, src.width, y + cropH)
        }
        canvas.save()
        canvas.clipPath(clip)
        canvas.drawBitmap(src, srcRect, dst, Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG))
        canvas.restore()
    }

    /** Draws the PiP border/glow, mirroring the styles in CompositorRenderer's shader. */
    private fun drawFrame(
        canvas: Canvas, rect: RectF, radius: Float, circle: Boolean,
        frameStyle: PipFrameStyle, frameColor: PipFrameColor, canvasWidth: Int,
    ) {
        if (frameStyle == PipFrameStyle.NONE) return
        val s = canvasWidth / 1080f
        val argb = frameColor.color.toArgb()

        fun expanded(amount: Float): Path {
            val r = RectF(rect.left - amount, rect.top - amount, rect.right + amount, rect.bottom + amount)
            return roundedPath(r, radius + amount, circle)
        }

        fun stroke(path: Path, width: Float, strokeAlpha: Int = 255, blurRadius: Float = 0f) {
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                strokeWidth = width
                color = argb
                alpha = strokeAlpha
                if (blurRadius > 0f) maskFilter = BlurMaskFilter(blurRadius, BlurMaskFilter.Blur.NORMAL)
            }
            canvas.drawPath(path, paint)
        }

        when (frameStyle) {
            PipFrameStyle.NONE -> {}
            PipFrameStyle.SOLID -> stroke(roundedPath(rect, radius, circle), 3f * s)
            PipFrameStyle.THICK -> stroke(roundedPath(rect, radius, circle), 8f * s)
            PipFrameStyle.DOUBLE -> {
                stroke(roundedPath(rect, radius, circle), 3f * s)
                stroke(expanded(7f * s), 3f * s)
            }
            PipFrameStyle.DASHED -> {
                val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    style = Paint.Style.STROKE
                    strokeWidth = 4f * s
                    color = argb
                    pathEffect = DashPathEffect(floatArrayOf(10f * s, 8f * s), 0f)
                }
                canvas.drawPath(roundedPath(rect, radius, circle), paint)
            }
            PipFrameStyle.GLASS -> stroke(roundedPath(rect, radius, circle), 10f * s, strokeAlpha = 100)
            PipFrameStyle.GLOW -> {
                stroke(expanded(2f * s), 6f * s, strokeAlpha = 140, blurRadius = 14f * s)
                stroke(roundedPath(rect, radius, circle), 3f * s)
            }
            PipFrameStyle.NEON -> {
                stroke(expanded(2f * s), 8f * s, strokeAlpha = 180, blurRadius = 10f * s)
                stroke(roundedPath(rect, radius, circle), 4f * s)
            }
        }
    }
}
