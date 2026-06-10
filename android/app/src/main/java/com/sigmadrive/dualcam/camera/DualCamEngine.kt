package com.sigmadrive.dualcam.camera

import android.app.Application
import android.app.NotificationManager
import android.content.Context
import android.graphics.Bitmap
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaActionSound
import android.media.MediaMetadataRetriever
import android.view.Surface
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.core.app.NotificationCompat
import com.sigmadrive.dualcam.capture.MediaSaver
import com.sigmadrive.dualcam.capture.RecordingSession
import com.sigmadrive.dualcam.model.*
import com.sigmadrive.dualcam.render.DelayedDualComposer
import com.sigmadrive.dualcam.render.RenderPipeline
import com.sigmadrive.dualcam.settings.AppSettings
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

/**
 * The CaptureManager of the Android app: owns the camera controller, the GL
 * pipeline, and recording state, and keeps the compositor in sync with
 * settings.
 */
class DualCamEngine(app: Application) : AndroidViewModel(app) {

    sealed interface Status {
        data object Initializing : Status
        data object Ready : Status
        data class Unsupported(val message: String) : Status
        data class Error(val message: String) : Status
    }

    val settings = AppSettings.get(app)
    val saver = MediaSaver(app)
    private val controller = DualCameraController(app)
    private var pipeline: RenderPipeline? = null

    private val _status = MutableStateFlow<Status>(Status.Initializing)
    val status: StateFlow<Status> = _status
    private val _availablePairs = MutableStateFlow<List<CameraPair>>(emptyList())
    val availablePairs: StateFlow<List<CameraPair>> = _availablePairs
    private val _isRecording = MutableStateFlow(false)
    val isRecording: StateFlow<Boolean> = _isRecording
    private val _recordingSeconds = MutableStateFlow(0)
    val recordingSeconds: StateFlow<Int> = _recordingSeconds
    private val _zoom = MutableStateFlow(1f)
    val zoom: StateFlow<Float> = _zoom
    private val _maxZoom = MutableStateFlow(1f)
    val maxZoomFlow: StateFlow<Float> = _maxZoom
    private val _fps = MutableStateFlow(0)
    val fps: StateFlow<Int> = _fps
    private val _swapped = MutableStateFlow(false)
    val swapped: StateFlow<Boolean> = _swapped
    private val _flashAvailable = MutableStateFlow(false)
    val flashAvailable: StateFlow<Boolean> = _flashAvailable
    private val _debugInfo = MutableStateFlow("")
    val debugInfo: StateFlow<String> = _debugInfo
    private val _delayedCaptureCountdown = MutableStateFlow<Int?>(null)
    val delayedCaptureCountdown: StateFlow<Int?> = _delayedCaptureCountdown

    val mediaItems = MutableStateFlow<List<MediaItem>>(emptyList())
    val lastCapture = MutableStateFlow<MediaItem?>(null)

    private var cameraSurfaces: Pair<Surface, Surface>? = null
    private var displaySurface: Surface? = null
    private var composite: RecordingSession? = null
    private var rawA: RecordingSession? = null
    private var rawB: RecordingSession? = null
    private var recordTimer: Job? = null
    private var focusRequest: AudioFocusRequest? = null
    private val shutterSound = MediaActionSound()
    private var sessionActive = false

    init {
        controller.onError = { msg -> _status.value = Status.Error(msg) }
        if (settings.autoCleanTempFiles.value) saver.cleanTempFiles()
        observeSettings()
    }

    // MARK: Session lifecycle

    fun startSession() {
        if (sessionActive) return
        sessionActive = true
        _status.value = Status.Initializing
        val p = RenderPipeline()
        pipeline = p
        p.onFps = { _fps.value = it }
        p.start { bg, pip ->
            cameraSurfaces = bg to pip
            displaySurface?.let { p.setDisplaySurface(it) }
            viewModelScope.launch { openCameras() }
        }
    }

    fun stopSession() {
        if (!sessionActive) return
        sessionActive = false
        if (_isRecording.value) stopRecording()
        controller.close()
        pipeline?.stop()
        pipeline = null
        cameraSurfaces = null
    }

    private suspend fun openCameras(pairOverride: CameraPair? = null) {
        val (bgSurface, pipSurface) = cameraSurfaces ?: return
        try {
            controller.discover()
            if (!controller.supportsConcurrent) {
                _status.value = Status.Unsupported(
                    "This device doesn't support running two cameras at once."
                )
                return
            }
            val pairs = controller.availablePairs()
            _availablePairs.value = pairs
            if (pairs.isEmpty()) {
                _status.value = Status.Unsupported("No concurrent camera pair available.")
                return
            }
            val pair = (pairOverride ?: settings.cameraPair.value)
                .takeIf { it in pairs } ?: pairs.first()
            settings.cameraPair.value = pair

            val quality = settings.videoQuality.value
            val targetEdge = if (quality == VideoQuality.LOW) 1280 else 1920
            val bgInfo = controller.backgroundLens(pair)!!
            val pipInfo = controller.pipLens(pair)!!
            val bgSize = controller.pickStreamSize(bgInfo, targetEdge)
            val pipSize = controller.pickStreamSize(pipInfo, targetEdge)

            pipeline?.setCanvasSize(quality.width, quality.height)
            pipeline?.setFeeds(
                RenderPipeline.FeedInfo(bgSize.width, bgSize.height, bgInfo.sensorOrientation, bgInfo.isFront),
                RenderPipeline.FeedInfo(pipSize.width, pipSize.height, pipInfo.sensorOrientation, pipInfo.isFront),
            )
            _debugInfo.value = "BG ${bgSize.width}x${bgSize.height} rot${bgInfo.sensorOrientation}" +
                (if (bgInfo.isFront) " front" else " back") +
                " | PiP ${pipSize.width}x${pipSize.height} rot${pipInfo.sensorOrientation}" +
                (if (pipInfo.isFront) " front" else " back") +
                " | canvas ${quality.width}x${quality.height}"
            _swapped.value = false
            pushStyle()

            controller.open(pair, bgSurface, pipSurface)
            _zoom.value = controller.currentZoom()
            _maxZoom.value = controller.maxZoom()
            _flashAvailable.value = controller.isFlashAvailable()
            applyFlashSetting()
            _status.value = Status.Ready
        } catch (e: Exception) {
            _status.value = Status.Error(e.message ?: "Camera failed to start")
        }
    }

    fun selectPair(pair: CameraPair) {
        if (_isRecording.value) return
        viewModelScope.launch { openCameras(pair) }
    }

    /** Re-opens the session after a quality change (stream sizes depend on it). */
    fun reconfigureQuality() {
        if (_isRecording.value || !sessionActive) return
        viewModelScope.launch { openCameras() }
    }

    fun setDisplaySurface(surface: Surface?) {
        displaySurface = surface
        pipeline?.setDisplaySurface(surface)
    }

    // MARK: Style sync

    private fun observeSettings() {
        val s = settings
        viewModelScope.launch {
            // Any of these settings changing re-pushes the compositor style.
            kotlinx.coroutines.flow.merge(
                s.layoutMode.flow, s.pipShape.flow, s.pipFrameStyle.flow,
                s.pipFrameColor.flow, s.spotlightSplit.flow, s.spotlightGap.flow,
                s.mirrorFrontCamera.flow,
                s.pipCenterX.flow, s.pipCenterY.flow, s.pipWidth.flow,
                s.debugRotationOffsetA.flow, s.debugRotationOffsetB.flow,
                s.debugExtraMirrorA.flow, s.debugExtraMirrorB.flow,
            ).collect { pushStyle() }
        }
    }

    private fun pushStyle() {
        val s = settings
        pipeline?.updateStyle(
            RenderPipeline.Style(
                layoutMode = s.layoutMode.value,
                pipShape = s.pipShape.value,
                frameStyle = s.pipFrameStyle.value,
                frameColor = s.pipFrameColor.value,
                spotlightSplit = s.spotlightSplit.value,
                spotlightGap = s.spotlightGap.value,
                pip = s.pipTransform(),
                mirrorFront = s.mirrorFrontCamera.value,
                swapped = _swapped.value,
                debugRotationOffsetA = s.debugRotationOffsetA.value,
                debugRotationOffsetB = s.debugRotationOffsetB.value,
                debugExtraMirrorA = s.debugExtraMirrorA.value,
                debugExtraMirrorB = s.debugExtraMirrorB.value,
            )
        )
    }

    // MARK: Controls

    fun setZoom(ratio: Float) {
        controller.setZoom(ratio)
        _zoom.value = controller.currentZoom()
    }

    fun maxZoom(): Float = controller.maxZoom()

    fun focusAt(x: Float, y: Float) = controller.focusAt(x, y)

    fun swapCameras() {
        _swapped.value = !_swapped.value
        controller.swapRoles()
        if (settings.zoomResetOnSwap.value) controller.setZoom(1f)
        _zoom.value = controller.currentZoom()
        _maxZoom.value = controller.maxZoom()
        _flashAvailable.value = controller.isFlashAvailable()
        pushStyle()
    }

    fun setFlashMode(mode: FlashMode) {
        settings.flashMode.value = mode
        applyFlashSetting()
    }

    private fun applyFlashSetting() {
        // Video pipeline → flash means torch. AUTO behaves like ON while capturing.
        controller.setTorch(_isRecording.value && settings.flashMode.value != FlashMode.OFF)
    }

    // MARK: Photo

    fun capturePhoto() {
        val p = pipeline ?: return
        viewModelScope.launch {
            val useTorch = settings.flashMode.value != FlashMode.OFF && _flashAvailable.value
            if (useTorch) {
                controller.setTorch(true)
                delay(400)
            }
            if (settings.delayedDualCapture.value) {
                captureDelayedDual(p, useTorch)
                return@launch
            }
            if (settings.soundOnCapture.value) shutterSound.play(MediaActionSound.SHUTTER_CLICK)
            p.requestPhoto { bitmap ->
                if (useTorch && !_isRecording.value) controller.setTorch(false)
                val item = MediaItem(
                    type = MediaType.PHOTO,
                    pair = settings.cameraPair.value,
                    bitmap = bitmap,
                    thumbnail = Bitmap.createScaledBitmap(
                        bitmap, 200, 200 * bitmap.height / bitmap.width, true
                    ),
                )
                mediaItems.value = listOf(item) + mediaItems.value
                lastCapture.value = item
                if (!settings.showCapturePreview.value &&
                    settings.saveDestination.value == SaveDestination.PHOTOS
                ) {
                    autoSave(item)
                }
            }
        }
    }

    /**
     * Captures the background camera immediately, waits for the countdown,
     * then captures the pip camera and composites both into the styled
     * layout — the Android counterpart of the iOS captureDelayedPrimary /
     * captureDelayedSecondary / finishPhotoCapture flow.
     */
    private suspend fun captureDelayedDual(p: RenderPipeline, useTorch: Boolean) {
        val bgIsA = !_swapped.value
        if (settings.soundOnCapture.value) shutterSound.play(MediaActionSound.SHUTTER_CLICK)
        val bgBitmap = captureFeedBitmap(p, bgIsA)

        var remaining = maxOf(settings.delayedDualCaptureSeconds.value, 1)
        _delayedCaptureCountdown.value = remaining
        while (remaining > 0) {
            delay(1000)
            remaining--
            _delayedCaptureCountdown.value = if (remaining > 0) remaining else null
        }

        if (settings.soundOnCapture.value) shutterSound.play(MediaActionSound.SHUTTER_CLICK)
        val pipBitmap = captureFeedBitmap(p, !bgIsA)
        if (useTorch && !_isRecording.value) controller.setTorch(false)

        val composite = DelayedDualComposer.compose(bgBitmap, pipBitmap, p.style)
        val item = MediaItem(
            type = MediaType.PHOTO,
            pair = settings.cameraPair.value,
            bitmap = composite,
            thumbnail = Bitmap.createScaledBitmap(
                composite, 200, 200 * composite.height / composite.width, true
            ),
        )
        mediaItems.value = listOf(item) + mediaItems.value
        lastCapture.value = item
        if (!settings.showCapturePreview.value &&
            settings.saveDestination.value == SaveDestination.PHOTOS
        ) {
            autoSave(item)
        }
    }

    private suspend fun captureFeedBitmap(p: RenderPipeline, isA: Boolean): Bitmap =
        suspendCancellableCoroutine { cont ->
            p.requestFeedBitmap(isA) { bitmap -> cont.resume(bitmap) }
        }

    // MARK: Video

    fun startRecording() {
        if (_isRecording.value || pipeline == null) return
        val ctx = getApplication<Application>()
        val quality = settings.videoQuality.value
        val codec = settings.recordingCodec.value
        try {
            val session = RecordingSession(
                ctx, saver.tempFile("dualCam", "mp4"),
                quality.width.even(), quality.height.even(), codec, withAudio = true,
            )
            composite = session
            pipeline?.attachEncoder(session.surface, session.width, session.height)

            if (settings.autoSaveRawFeeds.value) {
                // Raw feeds at the composite canvas size, one per camera
                val a = RecordingSession(
                    ctx, saver.tempFile("dualCam_main", "mp4"),
                    quality.width.even(), quality.height.even(), codec, withAudio = false,
                )
                val b = RecordingSession(
                    ctx, saver.tempFile("dualCam_pip", "mp4"),
                    quality.width.even(), quality.height.even(), codec, withAudio = false,
                )
                rawA = a; rawB = b
                pipeline?.attachRawEncoders(a.surface, a.width, a.height, b.surface, b.width, b.height)
                a.start(); b.start()
            }
            session.start()
        } catch (e: Exception) {
            composite = null; rawA = null; rawB = null
            pipeline?.detachEncoders()
            _status.value = Status.Error("Recording failed to start: ${e.message}")
            return
        }

        if (!settings.mixAudioWithMusic.value) requestAudioFocus(ctx)
        _isRecording.value = true
        applyFlashSetting()
        showRecordingNotification(ctx)

        recordTimer = viewModelScope.launch {
            _recordingSeconds.value = 0
            while (true) {
                delay(1000)
                _recordingSeconds.value += 1
                val limit = settings.recordingLimitSeconds.value
                if (!settings.extendedRecording.value && _recordingSeconds.value >= limit) {
                    stopRecording()
                    break
                }
            }
        }
    }

    fun stopRecording() {
        if (!_isRecording.value) return
        _isRecording.value = false
        recordTimer?.cancel()
        recordTimer = null
        applyFlashSetting()

        val ctx = getApplication<Application>()
        (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(42)
        focusRequest?.let {
            (ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager).abandonAudioFocusRequest(it)
            focusRequest = null
        }

        val session = composite
        val rA = rawA
        val rB = rawB
        composite = null; rawA = null; rawB = null
        pipeline?.detachEncoders()

        viewModelScope.launch {
            delay(150) // let in-flight frames drain before stopping the encoder
            val ok = session?.stop() ?: false
            val rawOkA = rA?.stop() ?: false
            val rawOkB = rB?.stop() ?: false
            if (!ok || session == null) {
                _status.value = Status.Error("Recording was too short to save.")
                return@launch
            }
            val rawFiles = buildList {
                if (rawOkA && rA != null) add(rA.outputFile)
                if (rawOkB && rB != null) add(rB.outputFile)
            }
            val item = MediaItem(
                type = MediaType.VIDEO,
                pair = settings.cameraPair.value,
                videoFile = session.outputFile,
                rawVideoFiles = rawFiles,
                thumbnail = videoThumbnail(session.outputFile.absolutePath),
            )
            mediaItems.value = listOf(item) + mediaItems.value
            lastCapture.value = item
            if (!settings.showCapturePreview.value &&
                settings.saveDestination.value == SaveDestination.PHOTOS
            ) {
                autoSave(item)
            }
        }
    }

    // MARK: Saving

    /** Saves to the gallery (Photos destination). The SAF flow lives in the UI. */
    fun autoSave(item: MediaItem) {
        viewModelScope.launch(kotlinx.coroutines.Dispatchers.IO) {
            val uri = when (item.type) {
                MediaType.PHOTO -> item.bitmap?.let { saver.savePhotoToGallery(it) }
                MediaType.VIDEO -> item.videoFile?.let { saver.saveVideoToGallery(it) }
            }
            item.rawVideoFiles.forEach { saver.saveVideoToGallery(it) }
            if (uri != null) {
                item.savedUri = uri
                if (settings.notifyOnSave.value) {
                    saver.notifySaved(
                        if (item.type == MediaType.PHOTO) "Photo saved to gallery"
                        else "Video saved to gallery"
                    )
                }
            }
        }
    }

    fun discard(item: MediaItem) {
        item.videoFile?.delete()
        item.rawVideoFiles.forEach { it.delete() }
        mediaItems.value = mediaItems.value.filterNot { it.id == item.id }
        if (lastCapture.value?.id == item.id) lastCapture.value = null
    }

    // MARK: Helpers

    private fun requestAudioFocus(ctx: Context) {
        val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            .setAudioAttributes(
                AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).build()
            )
            .build()
        am.requestAudioFocus(request)
        focusRequest = request
    }

    private fun showRecordingNotification(ctx: Context) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val notification = NotificationCompat.Builder(ctx, MediaSaver.CHANNEL_RECORDING)
            .setSmallIcon(android.R.drawable.presence_video_online)
            .setContentTitle("dualCam")
            .setContentText("Recording…")
            .setUsesChronometer(true)
            .setOngoing(true)
            .build()
        try {
            nm.notify(42, notification)
        } catch (_: SecurityException) {
        }
    }

    private fun videoThumbnail(path: String): Bitmap? = try {
        MediaMetadataRetriever().use { r ->
            r.setDataSource(path)
            r.getFrameAtTime(0)
        }
    } catch (_: Exception) {
        null
    }

    private fun Int.even(): Int = this - (this % 2)

    override fun onCleared() {
        stopSession()
        controller.release()
        shutterSound.release()
    }
}
