package com.sigmadrive.dualcam.camera

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Rect
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.params.MeteringRectangle
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.SessionConfiguration
import android.os.Handler
import android.os.HandlerThread
import android.util.Size
import android.view.Surface
import com.sigmadrive.dualcam.model.CameraPair
import com.sigmadrive.dualcam.model.Lens
import kotlinx.coroutines.suspendCancellableCoroutine
import java.util.concurrent.Executor
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.math.abs

/**
 * Discovers the device's lenses, figures out which iOS-style camera pairs can
 * stream concurrently (CameraManager.getConcurrentCameraIds), and runs the two
 * Camera2 capture sessions — the AVCaptureMultiCamSession counterpart.
 */
class DualCameraController(context: Context) {

    data class LensInfo(
        val id: String,
        val lens: Lens,
        val sensorOrientation: Int,
        val isFront: Boolean,
        val hasFlash: Boolean,
        val maxZoom: Float,
        val activeArray: Rect,
        val streamSizes: List<Size>,
    )

    private class OpenCamera(
        val info: LensInfo,
        val device: CameraDevice,
        val surface: Surface,
    ) {
        var session: CameraCaptureSession? = null
        var zoom = 1f
        var torch = false
        var afRegion: MeteringRectangle? = null
    }

    private val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
    private val thread = HandlerThread("dualcam-camera").also { it.start() }
    private val handler = Handler(thread.looper)
    private val executor = Executor { handler.post(it) }

    var lenses: Map<Lens, LensInfo> = emptyMap(); private set
    private var concurrentSets: Set<Set<String>> = emptySet()

    private var background: OpenCamera? = null
    private var pip: OpenCamera? = null

    var onError: ((String) -> Unit)? = null

    fun discover() {
        val found = mutableMapOf<Lens, LensInfo>()
        val backCandidates = mutableListOf<Pair<LensInfo, Float>>()

        for (id in manager.cameraIdList) {
            val ch = manager.getCameraCharacteristics(id)
            val facing = ch.get(CameraCharacteristics.LENS_FACING) ?: continue
            val map = ch.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP) ?: continue
            val sizes = map.getOutputSizes(SurfaceTexture::class.java)?.toList() ?: continue
            val info = LensInfo(
                id = id,
                lens = Lens.WIDE, // refined below
                sensorOrientation = ch.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90,
                isFront = facing == CameraCharacteristics.LENS_FACING_FRONT,
                hasFlash = ch.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true,
                maxZoom = ch.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE)?.upper ?: 1f,
                activeArray = ch.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)
                    ?: Rect(0, 0, 4000, 3000),
                streamSizes = sizes,
            )
            when (facing) {
                CameraCharacteristics.LENS_FACING_FRONT ->
                    if (!found.containsKey(Lens.FRONT)) found[Lens.FRONT] = info.copy(lens = Lens.FRONT)

                CameraCharacteristics.LENS_FACING_BACK -> {
                    val focal = ch.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
                        ?.minOrNull() ?: 4f
                    backCandidates += info to focal
                }
            }
        }

        // Classify exposed back cameras by focal length: shortest = ultra-wide,
        // middle = wide, longest = telephoto (when meaningfully longer).
        val sorted = backCandidates.sortedBy { it.second }
        when {
            sorted.size == 1 -> found[Lens.WIDE] = sorted[0].first.copy(lens = Lens.WIDE)
            sorted.size >= 2 -> {
                val (shortest, shortFocal) = sorted.first()
                val (longest, longFocal) = sorted.last()
                // The "wide" is whichever remains once extremes are assigned
                if (shortFocal < sorted[1].second * 0.85f) {
                    found[Lens.ULTRAWIDE] = shortest.copy(lens = Lens.ULTRAWIDE)
                }
                if (sorted.size >= 3 || (longFocal > sorted.first().second * 1.5f && found.containsKey(Lens.ULTRAWIDE))) {
                    if (longFocal > sorted[sorted.size - 2].second * 1.3f) {
                        found[Lens.TELEPHOTO] = longest.copy(lens = Lens.TELEPHOTO)
                    }
                }
                val taken = setOfNotNull(found[Lens.ULTRAWIDE]?.id, found[Lens.TELEPHOTO]?.id)
                val wide = sorted.firstOrNull { it.first.id !in taken } ?: sorted.first()
                found[Lens.WIDE] = wide.first.copy(lens = Lens.WIDE)
            }
        }

        lenses = found
        concurrentSets = try {
            manager.concurrentCameraIds
        } catch (_: Exception) {
            emptySet()
        }
    }

    /** Pairs from the iOS list that this device can actually run concurrently. */
    fun availablePairs(): List<CameraPair> = CameraPair.entries.filter { pair ->
        val a = lenses[pair.background]?.id ?: return@filter false
        val b = lenses[pair.pip]?.id ?: return@filter false
        a != b && concurrentSets.any { it.contains(a) && it.contains(b) }
    }

    val supportsConcurrent: Boolean get() = concurrentSets.isNotEmpty()

    fun backgroundLens(pair: CameraPair): LensInfo? = lenses[pair.background]
    fun pipLens(pair: CameraPair): LensInfo? = lenses[pair.pip]

    /** Largest 16:9 stream size not exceeding the target, falling back gracefully. */
    fun pickStreamSize(info: LensInfo, targetLongEdge: Int): Size {
        val wide = info.streamSizes.filter {
            abs(it.width * 9 - it.height * 16) <= it.height && it.width <= targetLongEdge
        }
        return wide.maxByOrNull { it.width.toLong() * it.height }
            ?: info.streamSizes.filter { it.width <= targetLongEdge }
                .maxByOrNull { it.width.toLong() * it.height }
            ?: info.streamSizes.first()
    }

    @SuppressLint("MissingPermission") // permission gated in the UI layer
    suspend fun open(pair: CameraPair, backgroundSurface: Surface, pipSurface: Surface) {
        close()
        val bgInfo = backgroundLens(pair) ?: error("Lens unavailable: ${pair.background}")
        val pipInfo = pipLens(pair) ?: error("Lens unavailable: ${pair.pip}")
        background = openSingle(bgInfo, backgroundSurface)
        pip = openSingle(pipInfo, pipSurface)
        background?.let { startRepeating(it) }
        pip?.let { startRepeating(it) }
    }

    private suspend fun openSingle(info: LensInfo, surface: Surface): OpenCamera {
        val device = suspendCancellableCoroutine { cont ->
            manager.openCamera(info.id, executor, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    if (cont.isActive) cont.resume(camera)
                }

                override fun onDisconnected(camera: CameraDevice) {
                    camera.close()
                    if (cont.isActive) cont.resumeWithException(IllegalStateException("Camera disconnected"))
                    else onError?.invoke("Camera ${info.lens} disconnected")
                }

                override fun onError(camera: CameraDevice, error: Int) {
                    camera.close()
                    val msg = "Camera ${info.lens} error $error"
                    if (cont.isActive) cont.resumeWithException(IllegalStateException(msg))
                    else onError?.invoke(msg)
                }
            })
        }

        val open = OpenCamera(info, device, surface)
        open.session = suspendCancellableCoroutine { cont ->
            val config = SessionConfiguration(
                SessionConfiguration.SESSION_REGULAR,
                listOf(OutputConfiguration(surface)),
                executor,
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        if (cont.isActive) cont.resume(session)
                    }

                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        if (cont.isActive) cont.resumeWithException(
                            IllegalStateException("Session configuration failed (${info.lens})")
                        )
                    }
                },
            )
            device.createCaptureSession(config)
        }
        return open
    }

    private fun startRepeating(cam: OpenCamera) {
        val session = cam.session ?: return
        try {
            val builder = cam.device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
            builder.addTarget(cam.surface)
            builder.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
            builder.set(
                CaptureRequest.CONTROL_AF_MODE,
                CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO
            )
            builder.set(CaptureRequest.CONTROL_ZOOM_RATIO, cam.zoom)
            if (cam.torch && cam.info.hasFlash) {
                builder.set(CaptureRequest.FLASH_MODE, CaptureRequest.FLASH_MODE_TORCH)
            }
            cam.afRegion?.let {
                builder.set(CaptureRequest.CONTROL_AF_REGIONS, arrayOf(it))
                builder.set(CaptureRequest.CONTROL_AE_REGIONS, arrayOf(it))
            }
            session.setRepeatingRequest(builder.build(), null, handler)
        } catch (e: Exception) {
            onError?.invoke("Camera request failed: ${e.message}")
        }
    }

    // MARK: Controls — all act on the current background camera, like the iOS app

    fun setZoom(ratio: Float) {
        val cam = background ?: return
        cam.zoom = ratio.coerceIn(1f, cam.info.maxZoom)
        startRepeating(cam)
    }

    fun currentZoom(): Float = background?.zoom ?: 1f
    fun maxZoom(): Float = background?.info?.maxZoom ?: 1f
    fun isFlashAvailable(): Boolean =
        background?.info?.hasFlash == true || pip?.info?.hasFlash == true

    /** Torch on whichever open camera has a flash unit (the rear one). */
    fun setTorch(on: Boolean) {
        for (cam in listOfNotNull(background, pip)) {
            if (cam.info.hasFlash) {
                cam.torch = on
                startRepeating(cam)
            }
        }
    }

    /**
     * Tap-to-focus at normalized upright coords (origin top-left of the
     * background feed). Converts through the sensor rotation to active-array
     * coordinates and triggers a one-shot AF.
     */
    fun focusAt(x: Float, y: Float) {
        val cam = background ?: return
        val (bx, by) = when (cam.info.sensorOrientation) {
            90 -> y to (1f - x)
            180 -> (1f - x) to (1f - y)
            270 -> (1f - y) to x
            else -> x to y
        }
        val rect = cam.info.activeArray
        val cxPx = rect.left + (bx * rect.width()).toInt()
        val cyPx = rect.top + (by * rect.height()).toInt()
        val half = (minOf(rect.width(), rect.height()) * 0.1f).toInt()
        val region = MeteringRectangle(
            (cxPx - half).coerceAtLeast(rect.left),
            (cyPx - half).coerceAtLeast(rect.top),
            half * 2, half * 2,
            MeteringRectangle.METERING_WEIGHT_MAX,
        )
        cam.afRegion = region
        try {
            val builder = cam.device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
            builder.addTarget(cam.surface)
            builder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_AUTO)
            builder.set(CaptureRequest.CONTROL_AF_REGIONS, arrayOf(region))
            builder.set(CaptureRequest.CONTROL_AE_REGIONS, arrayOf(region))
            builder.set(CaptureRequest.CONTROL_AF_TRIGGER, CaptureRequest.CONTROL_AF_TRIGGER_START)
            builder.set(CaptureRequest.CONTROL_ZOOM_RATIO, cam.zoom)
            cam.session?.capture(builder.build(), null, handler)
        } catch (e: Exception) {
            onError?.invoke("Focus failed: ${e.message}")
        }
        startRepeating(cam)
    }

    /** After a visual swap, route zoom/focus/torch to the new on-screen main camera. */
    fun swapRoles() {
        val t = background
        background = pip
        pip = t
    }

    fun close() {
        for (cam in listOfNotNull(background, pip)) {
            try {
                cam.session?.close()
                cam.device.close()
            } catch (_: Exception) {
            }
        }
        background = null
        pip = null
    }

    fun release() {
        close()
        thread.quitSafely()
    }
}
