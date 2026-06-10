package com.sigmadrive.dualcam.render

import android.graphics.RectF
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.Matrix
import com.sigmadrive.dualcam.model.PipFrameStyle
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

/**
 * GLES2 compositor: draws camera OES textures aspect-filled into rectangles on
 * the output canvas, with an SDF-based mask for the PiP window (rounded rect or
 * circle) and the border styles from the iOS app (solid/thick/double/dashed/
 * glass/glow/neon) evaluated in the fragment shader.
 */
class CompositorRenderer {

    data class Mask(
        val radiusPx: Float,
        val style: PipFrameStyle,
        val r: Float, val g: Float, val b: Float, val a: Float,
    )

    private var program = 0
    private var aPos = 0
    private var aTex = 0
    private var uTexMatrix = 0
    private var uSizePx = 0
    private var uRadiusPx = 0
    private var uPadPx = 0
    private var uStyle = 0
    private var uBorderColor = 0
    private var uPxScale = 0
    private var uMasked = 0

    private val posBuffer: FloatBuffer = floatBufferOf(8)
    private val texBuffer: FloatBuffer = floatBufferOf(8).apply {
        // Local quad coords, origin at the top-left of the destination rect, y down.
        put(floatArrayOf(0f, 0f, 0f, 1f, 1f, 0f, 1f, 1f)).position(0)
    }

    var oesTextureBackground = 0; private set
    var oesTexturePip = 0; private set

    private val scratchA = FloatArray(16)
    private val scratchC = FloatArray(16)

    fun setup() {
        program = buildProgram(VERTEX_SHADER, FRAGMENT_SHADER)
        aPos = GLES20.glGetAttribLocation(program, "aPos")
        aTex = GLES20.glGetAttribLocation(program, "aTex")
        uTexMatrix = GLES20.glGetUniformLocation(program, "uTexMatrix")
        uSizePx = GLES20.glGetUniformLocation(program, "uSizePx")
        uRadiusPx = GLES20.glGetUniformLocation(program, "uRadiusPx")
        uPadPx = GLES20.glGetUniformLocation(program, "uPadPx")
        uStyle = GLES20.glGetUniformLocation(program, "uStyle")
        uBorderColor = GLES20.glGetUniformLocation(program, "uBorderColor")
        uPxScale = GLES20.glGetUniformLocation(program, "uPxScale")
        uMasked = GLES20.glGetUniformLocation(program, "uMasked")

        val ids = IntArray(2)
        GLES20.glGenTextures(2, ids, 0)
        for (id in ids) {
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, id)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        }
        oesTextureBackground = ids[0]
        oesTexturePip = ids[1]
    }

    fun beginFrame(canvasWidth: Int, canvasHeight: Int) {
        GLES20.glViewport(0, 0, canvasWidth, canvasHeight)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
    }

    /**
     * Draws one camera feed aspect-filled into [dstRect] (canvas pixels, origin
     * top-left). [rotationDegrees] is the clockwise rotation that makes the
     * sensor buffer upright; [mirror] flips the upright image horizontally.
     * When [mask] is set, the rect is shaped/bordered; [glowPadPx] expands the
     * quad so glow styles can bleed outside the window.
     */
    fun drawCamera(
        textureId: Int,
        stMatrix: FloatArray,
        srcWidth: Int,
        srcHeight: Int,
        rotationDegrees: Int,
        mirror: Boolean,
        dstRect: RectF,
        canvasWidth: Int,
        canvasHeight: Int,
        mask: Mask? = null,
        glowPadPx: Float = 0f,
    ) {
        val pad = if (mask != null) glowPadPx else 0f
        val quad = RectF(
            dstRect.left - pad, dstRect.top - pad,
            dstRect.right + pad, dstRect.bottom + pad
        )

        // Vertex positions: TL, BL, TR, BR in NDC (canvas y-down → NDC y-up)
        val x0 = 2f * quad.left / canvasWidth - 1f
        val x1 = 2f * quad.right / canvasWidth - 1f
        val y0 = 1f - 2f * quad.top / canvasHeight
        val y1 = 1f - 2f * quad.bottom / canvasHeight
        posBuffer.put(floatArrayOf(x0, y0, x0, y1, x1, y0, x1, y1)).position(0)

        GLES20.glUseProgram(program)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)

        GLES20.glUniformMatrix4fv(
            uTexMatrix, 1, false,
            texCoordMatrix(stMatrix, srcWidth, srcHeight, rotationDegrees, mirror, dstRect, pad), 0
        )

        if (mask != null) {
            GLES20.glUniform1i(uMasked, 1)
            GLES20.glUniform2f(uSizePx, quad.width(), quad.height())
            GLES20.glUniform1f(uRadiusPx, mask.radiusPx)
            GLES20.glUniform1f(uPadPx, pad)
            GLES20.glUniform1i(uStyle, mask.style.ordinal)
            GLES20.glUniform4f(uBorderColor, mask.r, mask.g, mask.b, mask.a)
            GLES20.glUniform1f(uPxScale, canvasWidth / 1080f)
            GLES20.glEnable(GLES20.GL_BLEND)
            GLES20.glBlendFunc(GLES20.GL_SRC_ALPHA, GLES20.GL_ONE_MINUS_SRC_ALPHA)
        } else {
            GLES20.glUniform1i(uMasked, 0)
            GLES20.glDisable(GLES20.GL_BLEND)
        }

        GLES20.glEnableVertexAttribArray(aPos)
        GLES20.glVertexAttribPointer(aPos, 2, GLES20.GL_FLOAT, false, 0, posBuffer)
        GLES20.glEnableVertexAttribArray(aTex)
        GLES20.glVertexAttribPointer(aTex, 2, GLES20.GL_FLOAT, false, 0, texBuffer)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glDisableVertexAttribArray(aPos)
        GLES20.glDisableVertexAttribArray(aTex)
        GLES20.glDisable(GLES20.GL_BLEND)
    }

    /**
     * Builds the texture-coordinate matrix. Chain applied to the quad's local
     * coords (origin top-left, y down): pad inset → mirror → aspect-fill crop →
     * sensor rotation → y-flip into GL convention → SurfaceTexture transform.
     */
    private fun texCoordMatrix(
        stMatrix: FloatArray,
        srcWidth: Int,
        srcHeight: Int,
        rotationDegrees: Int,
        mirror: Boolean,
        contentRect: RectF,
        pad: Float,
    ): FloatArray {
        // Pad inset: expanded-quad local → content-rect local
        val ew = contentRect.width() + 2 * pad
        val eh = contentRect.height() + 2 * pad
        var m = affine(
            ew / contentRect.width(), 0f, -pad / contentRect.width(),
            0f, eh / contentRect.height(), -pad / contentRect.height()
        )

        if (mirror) m = mul(affine(-1f, 0f, 1f, 0f, 1f, 0f), m)

        // Aspect-fill crop in upright-source space. Camera2 buffers from these
        // sensors arrive landscape (e.g. 1920x1080) but the canvas is portrait,
        // and SurfaceTexture's transform matrix already accounts for the
        // sensor rotation — so the crop should always treat the buffer as
        // portrait (dimensions swapped), independent of [rotationDegrees].
        val upW = srcHeight.toFloat()
        val upH = srcWidth.toFloat()
        val scale = maxOf(contentRect.width() / upW, contentRect.height() / upH)
        val kx = contentRect.width() / scale / upW
        val ky = contentRect.height() / scale / upH
        m = mul(affine(kx, 0f, 0.5f - kx * 0.5f, 0f, ky, 0.5f - ky * 0.5f), m)

        // Upright coords → sensor-buffer coords (inverse of the CW rotation)
        val rot = when ((rotationDegrees % 360 + 360) % 360) {
            90 -> affine(0f, 1f, 0f, -1f, 0f, 1f)
            180 -> affine(-1f, 0f, 1f, 0f, -1f, 1f)
            270 -> affine(0f, -1f, 1f, 1f, 0f, 0f)
            else -> affine(1f, 0f, 0f, 0f, 1f, 0f)
        }
        m = mul(rot, m)

        // Top-left y-down → GL bottom-left convention, then SurfaceTexture matrix
        m = mul(affine(1f, 0f, 0f, 0f, -1f, 1f), m)
        Matrix.multiplyMM(scratchC, 0, stMatrix, 0, m, 0)
        return scratchC.copyOf()
    }

    /** Column-major 4x4 from a 2D affine: s = a·x + b·y + c, t = d·x + e·y + f */
    private fun affine(a: Float, b: Float, c: Float, d: Float, e: Float, f: Float): FloatArray {
        val m = FloatArray(16)
        m[0] = a; m[1] = d
        m[4] = b; m[5] = e
        m[10] = 1f
        m[12] = c; m[13] = f
        m[15] = 1f
        return m
    }

    private fun mul(lhs: FloatArray, rhs: FloatArray): FloatArray {
        Matrix.multiplyMM(scratchA, 0, lhs, 0, rhs, 0)
        return scratchA.copyOf()
    }

    fun release() {
        if (program != 0) GLES20.glDeleteProgram(program)
        program = 0
        if (oesTextureBackground != 0) {
            GLES20.glDeleteTextures(2, intArrayOf(oesTextureBackground, oesTexturePip), 0)
        }
        oesTextureBackground = 0
        oesTexturePip = 0
    }

    private fun buildProgram(vertexSrc: String, fragmentSrc: String): Int {
        fun compile(type: Int, src: String): Int {
            val shader = GLES20.glCreateShader(type)
            GLES20.glShaderSource(shader, src)
            GLES20.glCompileShader(shader)
            val ok = IntArray(1)
            GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, ok, 0)
            check(ok[0] != 0) { "Shader compile failed: ${GLES20.glGetShaderInfoLog(shader)}" }
            return shader
        }

        val vs = compile(GLES20.GL_VERTEX_SHADER, vertexSrc)
        val fs = compile(GLES20.GL_FRAGMENT_SHADER, fragmentSrc)
        val prog = GLES20.glCreateProgram()
        GLES20.glAttachShader(prog, vs)
        GLES20.glAttachShader(prog, fs)
        GLES20.glLinkProgram(prog)
        val ok = IntArray(1)
        GLES20.glGetProgramiv(prog, GLES20.GL_LINK_STATUS, ok, 0)
        check(ok[0] != 0) { "Program link failed: ${GLES20.glGetProgramInfoLog(prog)}" }
        GLES20.glDeleteShader(vs)
        GLES20.glDeleteShader(fs)
        return prog
    }

    private fun floatBufferOf(capacity: Int): FloatBuffer =
        ByteBuffer.allocateDirect(capacity * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()

    companion object {
        private const val VERTEX_SHADER = """
attribute vec4 aPos;
attribute vec2 aTex;
uniform mat4 uTexMatrix;
varying vec2 vTexCoord;
varying vec2 vLocal;
void main() {
    gl_Position = aPos;
    vLocal = aTex;
    vTexCoord = (uTexMatrix * vec4(aTex, 0.0, 1.0)).xy;
}
"""

        // uStyle matches PipFrameStyle.ordinal:
        // 0 none, 1 solid, 2 thick, 3 double, 4 dashed, 5 glass, 6 glow, 7 neon
        private const val FRAGMENT_SHADER = """
#extension GL_OES_EGL_image_external : require
precision mediump float;
uniform samplerExternalOES uTex;
varying vec2 vTexCoord;
varying vec2 vLocal;
uniform vec2 uSizePx;
uniform float uRadiusPx;
uniform float uPadPx;
uniform int uStyle;
uniform vec4 uBorderColor;
uniform float uPxScale;
uniform int uMasked;

float sdRoundRect(vec2 p, vec2 halfSize, float r) {
    vec2 q = abs(p) - halfSize + vec2(r);
    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

float ring(float d, float center, float halfW, float aa) {
    return 1.0 - smoothstep(halfW - aa, halfW + aa, abs(d - center));
}

void main() {
    vec4 cam = texture2D(uTex, vTexCoord);
    if (uMasked == 0) {
        gl_FragColor = vec4(cam.rgb, 1.0);
        return;
    }

    vec2 p = (vLocal - 0.5) * uSizePx;
    vec2 halfSize = uSizePx * 0.5 - vec2(uPadPx);
    float d = sdRoundRect(p, halfSize, uRadiusPx);
    float aa = 1.2;
    float inside = 1.0 - smoothstep(-aa, aa, d);

    vec4 bc = uBorderColor;
    float ringA = 0.0;
    float s = uPxScale;
    if (uStyle == 1) {
        ringA = ring(d, -1.5 * s, 1.5 * s, aa);
    } else if (uStyle == 2) {
        ringA = ring(d, -4.0 * s, 4.0 * s, aa);
    } else if (uStyle == 3) {
        ringA = max(ring(d, -1.5 * s, 1.5 * s, aa), ring(d, -7.5 * s, 1.5 * s, aa));
    } else if (uStyle == 4) {
        float ang = atan(p.y, p.x) / 6.2831853 + 0.5;
        float dash = step(0.5, fract(ang * 24.0));
        ringA = ring(d, -2.0 * s, 2.0 * s, aa) * dash;
    } else if (uStyle == 5) {
        bc = vec4(1.0, 1.0, 1.0, 0.40);
        ringA = ring(d, -5.0 * s, 5.0 * s, aa);
    } else if (uStyle == 6) {
        ringA = ring(d, -1.5 * s, 1.5 * s, aa);
    } else if (uStyle == 7) {
        ringA = ring(d, -2.0 * s, 2.0 * s, aa);
    }

    float glowA = 0.0;
    if (uStyle >= 6 && d > 0.0) {
        float falloff = (uStyle == 7) ? 10.0 * s : 14.0 * s;
        glowA = exp(-d / falloff) * ((uStyle == 7) ? 0.9 : 0.55);
    }

    vec3 rgb = mix(cam.rgb, bc.rgb, ringA * bc.a);
    rgb = mix(bc.rgb, rgb, inside);
    float alpha = max(inside, glowA);
    gl_FragColor = vec4(rgb, alpha);
}
"""
    }
}
