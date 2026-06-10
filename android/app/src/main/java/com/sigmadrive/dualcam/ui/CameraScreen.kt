package com.sigmadrive.dualcam.ui

import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.BrokenImage
import androidx.compose.material.icons.rounded.Cameraswitch
import androidx.compose.material.icons.rounded.PhotoLibrary
import androidx.compose.material.icons.rounded.PictureInPictureAlt
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.Splitscreen
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import com.sigmadrive.dualcam.camera.DualCamEngine
import com.sigmadrive.dualcam.model.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.launch
import java.util.Locale

enum class CaptureMode { PHOTO, VIDEO }

@Composable
fun CameraScreen(
    engine: DualCamEngine,
    shutterEvents: MutableSharedFlow<Unit>,
    onOpenSettings: () -> Unit,
    onOpenGallery: () -> Unit,
) {
    val context = LocalContext.current
    val settings = engine.settings
    val haptics = LocalHapticFeedback.current
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }

    val status by engine.status.collectAsState()
    val isRecording by engine.isRecording.collectAsState()
    val recordingSeconds by engine.recordingSeconds.collectAsState()
    val zoom by engine.zoom.collectAsState()
    val maxZoom by engine.maxZoomFlow.collectAsState()
    val fpsValue by engine.fps.collectAsState()
    val availablePairs by engine.availablePairs.collectAsState()
    val lastCapture by engine.lastCapture.collectAsState()
    val mediaItems by engine.mediaItems.collectAsState()

    val layoutMode by settings.layoutMode.flow.collectAsState()
    val pipShape by settings.pipShape.flow.collectAsState()
    val pipCx by settings.pipCenterX.flow.collectAsState()
    val pipCy by settings.pipCenterY.flow.collectAsState()
    val pipW by settings.pipWidth.flow.collectAsState()
    val showGrid by settings.showGridOverlay.flow.collectAsState()
    val showDebug by settings.showDebugInfo.flow.collectAsState()
    val flashMode by settings.flashMode.flow.collectAsState()
    val captureTimer by settings.captureTimer.flow.collectAsState()
    val delayedDualCapture by settings.delayedDualCapture.flow.collectAsState()
    val delayedDualCaptureSeconds by settings.delayedDualCaptureSeconds.flow.collectAsState()
    val delayedCaptureCountdown by engine.delayedCaptureCountdown.collectAsState()
    val currentPair by settings.cameraPair.flow.collectAsState()
    val hapticsEnabled by settings.hapticFeedback.flow.collectAsState()
    val showPreviewModal by settings.showCapturePreview.flow.collectAsState()

    var captureMode by remember { mutableStateOf(CaptureMode.PHOTO) }
    var quickPanelVisible by remember { mutableStateOf(false) }
    var countdown by remember { mutableStateOf<Int?>(null) }
    var focusPoint by remember { mutableStateOf<Offset?>(null) }
    var previewSize by remember { mutableStateOf(IntSize.Zero) }
    var previewItem by remember { mutableStateOf<MediaItem?>(null) }

    fun tick() {
        if (hapticsEnabled) haptics.performHapticFeedback(HapticFeedbackType.LongPress)
    }

    fun pipRect(): Rect {
        val w = pipW * previewSize.width
        val h = if (pipShape == PipShape.CIRCLE) w else w * 4f / 3f
        val cx = pipCx * previewSize.width
        val cy = pipCy * previewSize.height
        return Rect(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2)
    }

    fun doCapturePhoto() {
        tick()
        engine.capturePhoto()
    }

    fun triggerShutter() {
        if (status !is DualCamEngine.Status.Ready) return
        when (captureMode) {
            CaptureMode.PHOTO -> {
                if (captureTimer > 0 && countdown == null) {
                    countdown = captureTimer
                    scope.launch {
                        var remaining = captureTimer
                        while (remaining > 0) {
                            tick()
                            delay(1000)
                            remaining--
                            countdown = remaining
                        }
                        countdown = null
                        doCapturePhoto()
                    }
                } else if (countdown == null) {
                    doCapturePhoto()
                }
            }

            CaptureMode.VIDEO -> {
                tick()
                if (isRecording) {
                    engine.stopRecording()
                } else {
                    if (settings.showStorageWarnings.value &&
                        engine.saver.freeBytes() < 2L * 1024 * 1024 * 1024
                    ) {
                        scope.launch { snackbar.showSnackbar("Storage is low — long recordings may fail.") }
                    }
                    engine.startRecording()
                }
            }
        }
    }

    LaunchedEffect(Unit) {
        shutterEvents.collect { triggerShutter() }
    }

    LaunchedEffect(lastCapture) {
        if (showPreviewModal && lastCapture != null) previewItem = lastCapture
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
    ) {
        // ── Preview, letterboxed to the 9:16 composite canvas ──
        Box(
            modifier = Modifier
                .align(Alignment.Center)
                .aspectRatio(9f / 16f)
                .onSizeChanged { previewSize = it }
        ) {
            AndroidView(
                modifier = Modifier.fillMaxSize(),
                factory = { ctx ->
                    SurfaceView(ctx).apply {
                        holder.addCallback(object : SurfaceHolder.Callback {
                            override fun surfaceCreated(holder: SurfaceHolder) {
                                engine.setDisplaySurface(holder.surface)
                            }

                            override fun surfaceChanged(h: SurfaceHolder, f: Int, w: Int, hgt: Int) {}

                            override fun surfaceDestroyed(holder: SurfaceHolder) {
                                engine.setDisplaySurface(null)
                            }
                        })
                    }
                },
            )

            // Tap to focus / double-tap to swap
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .pointerInput(layoutMode, pipShape) {
                        detectTapGestures(
                            onTap = { pos ->
                                if (layoutMode == LayoutMode.PIP && pipRect().contains(pos)) return@detectTapGestures
                                focusPoint = pos
                                engine.focusAt(pos.x / size.width, pos.y / size.height)
                                scope.launch { delay(900); focusPoint = null }
                            },
                            onDoubleTap = {
                                tick()
                                engine.swapCameras()
                            },
                        )
                    }
                    // Pinch zoom / PiP drag & resize
                    .pointerInput(layoutMode, pipShape) {
                        awaitEachGesture {
                            val down = awaitFirstDown()
                            val onPip = layoutMode == LayoutMode.PIP && pipRect().contains(down.position)
                            while (true) {
                                val event = awaitPointerEvent()
                                if (event.changes.none { it.pressed }) break
                                val zoomChange = event.calculateZoom()
                                val pan = event.calculatePan()
                                if (onPip) {
                                    if (pan != Offset.Zero || zoomChange != 1f) {
                                        val newW = (settings.pipWidth.value * zoomChange)
                                            .coerceIn(0.18f, 0.55f)
                                        settings.pipWidth.value = newW
                                        val aspect = if (pipShape == PipShape.CIRCLE) 1f else 4f / 3f
                                        val h = newW * aspect * size.width / size.height.toFloat()
                                        settings.pipCenterX.value =
                                            (settings.pipCenterX.value + pan.x / size.width)
                                                .coerceIn(newW / 2, 1f - newW / 2)
                                        settings.pipCenterY.value =
                                            (settings.pipCenterY.value + pan.y / size.height)
                                                .coerceIn(h / 2, 1f - h / 2)
                                        event.changes.forEach { if (it.positionChanged()) it.consume() }
                                    }
                                } else if (zoomChange != 1f) {
                                    engine.setZoom(engine.zoom.value * zoomChange)
                                    event.changes.forEach { if (it.positionChanged()) it.consume() }
                                }
                            }
                        }
                    }
            )

            if (showGrid) GridOverlay()

            focusPoint?.let { FocusRing(it) }
        }

        // ── Status overlays ──
        when (val s = status) {
            is DualCamEngine.Status.Unsupported -> StatusCard(
                title = "Dual capture unavailable",
                message = s.message,
                modifier = Modifier.align(Alignment.Center),
            )

            is DualCamEngine.Status.Error -> StatusCard(
                title = "Camera error",
                message = s.message,
                modifier = Modifier.align(Alignment.Center),
            )

            else -> {}
        }

        // ── Top bar ──
        Row(
            modifier = Modifier
                .align(Alignment.TopCenter)
                .statusBarsPadding()
                .padding(horizontal = 16.dp, vertical = 8.dp)
                .fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            GlassIconButton(Icons.Rounded.Settings, "Settings", enabled = !isRecording) {
                tick(); onOpenSettings()
            }

            if (isRecording) RecordingPill(recordingSeconds)
            else if (zoom > 1.01f) ZoomPill(zoom)
            else Spacer(Modifier.size(1.dp))

            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                GlassIconButton(
                    if (layoutMode == LayoutMode.PIP) Icons.Rounded.PictureInPictureAlt
                    else Icons.Rounded.Splitscreen,
                    "Layout",
                ) {
                    tick()
                    settings.layoutMode.value =
                        if (layoutMode == LayoutMode.PIP) LayoutMode.SPOTLIGHT else LayoutMode.PIP
                }
                GlassIconButton(Icons.Rounded.Tune, "Quick settings") {
                    tick(); quickPanelVisible = !quickPanelVisible
                }
            }
        }

        AnimatedVisibility(
            visible = quickPanelVisible,
            enter = fadeIn(), exit = fadeOut(),
            modifier = Modifier
                .align(Alignment.TopEnd)
                .statusBarsPadding()
                .padding(top = 64.dp, end = 16.dp),
        ) {
            QuickSettingsPanel(
                flashMode = flashMode,
                flashAvailable = engine.flashAvailable.collectAsState().value,
                timer = captureTimer,
                onFlash = { tick(); engine.setFlashMode(it) },
                onTimer = { tick(); settings.captureTimer.value = it },
                delayedDual = delayedDualCapture,
                onDelayedDual = { tick(); settings.delayedDualCapture.value = it },
                delayedDualSeconds = delayedDualCaptureSeconds,
                onDelayedDualSeconds = { tick(); settings.delayedDualCaptureSeconds.value = it },
            )
        }

        if (showDebug) {
            val debugInfo by engine.debugInfo.collectAsState()
            val rotA by settings.debugRotationOffsetA.flow.collectAsState()
            val rotB by settings.debugRotationOffsetB.flow.collectAsState()
            val mirrorA by settings.debugExtraMirrorA.flow.collectAsState()
            val mirrorB by settings.debugExtraMirrorB.flow.collectAsState()
            Column(
                horizontalAlignment = Alignment.Start,
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .statusBarsPadding()
                    .padding(start = 16.dp, top = 64.dp)
                    .background(Color.Black.copy(alpha = 0.5f), RoundedCornerShape(6.dp))
                    .padding(horizontal = 8.dp, vertical = 4.dp),
            ) {
                Text(
                    "${fpsValue} fps · ${settings.videoQuality.value.label} · " +
                        "${settings.recordingCodec.value.label.substringBefore(" —")} · " +
                        "${currentPair.shortLabel}\n$debugInfo\npreview ${previewSize.width}x${previewSize.height}" +
                        "\nA: rot $rotA° mirror ${if (mirrorA) "on" else "off"}" +
                        "  ·  B: rot $rotB° mirror ${if (mirrorB) "on" else "off"}",
                    style = MaterialTheme.typography.labelSmall,
                    color = Color(0xFF8DF58D),
                )
                Spacer(Modifier.height(6.dp))
                @Composable
                fun chip(label: String, onClick: () -> Unit) {
                    Text(
                        label,
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.SemiBold,
                        color = Color.Black,
                        modifier = Modifier
                            .clip(RoundedCornerShape(50))
                            .background(Color(0xFF8DF58D))
                            .clickable(onClick = onClick)
                            .padding(horizontal = 10.dp, vertical = 5.dp),
                    )
                }
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    chip("A +90") { settings.debugRotationOffsetA.value = (rotA + 90) % 360 }
                    chip("A mirror") { settings.debugExtraMirrorA.value = !mirrorA }
                }
                Spacer(Modifier.height(4.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    chip("B +90") { settings.debugRotationOffsetB.value = (rotB + 90) % 360 }
                    chip("B mirror") { settings.debugExtraMirrorB.value = !mirrorB }
                }
            }
        }

        countdown?.let { n ->
            if (n > 0) Text(
                "$n",
                style = MaterialTheme.typography.displayLarge,
                fontWeight = FontWeight.Bold,
                color = Color.White,
                modifier = Modifier.align(Alignment.Center),
            )
        }

        delayedCaptureCountdown?.let { n ->
            if (n > 0) Text(
                "$n",
                style = MaterialTheme.typography.displayLarge,
                fontWeight = FontWeight.Bold,
                color = Color.White,
                modifier = Modifier.align(Alignment.Center),
            )
        }

        // ── Bottom controls ──
        Column(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .navigationBarsPadding()
                .padding(bottom = 16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            if (maxZoom > 1.05f && status is DualCamEngine.Status.Ready) {
                ZoomControl(
                    zoom = zoom,
                    maxZoom = maxZoom,
                    onZoomChange = { engine.setZoom(it) },
                    onTick = ::tick,
                )
                Spacer(Modifier.height(14.dp))
            }

            if (availablePairs.size > 1 && !isRecording) {
                Row(
                    modifier = Modifier
                        .horizontalScroll(rememberScrollState())
                        .padding(horizontal = 16.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    availablePairs.forEach { pair ->
                        FilterChip(
                            selected = pair == currentPair,
                            onClick = { tick(); engine.selectPair(pair) },
                            label = { Text(pair.shortLabel) },
                        )
                    }
                }
                Spacer(Modifier.height(10.dp))
            }

            if (!isRecording) {
                Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                    CaptureMode.entries.forEach { mode ->
                        Text(
                            mode.name,
                            style = MaterialTheme.typography.labelLarge,
                            fontWeight = if (mode == captureMode) FontWeight.Bold else FontWeight.Normal,
                            color = if (mode == captureMode) MaterialTheme.colorScheme.primary
                            else Color.White.copy(alpha = 0.7f),
                            modifier = Modifier
                                .clip(RoundedCornerShape(8.dp))
                                .clickable { tick(); captureMode = mode }
                                .padding(horizontal = 10.dp, vertical = 6.dp),
                        )
                    }
                }
                Spacer(Modifier.height(8.dp))
            }

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 36.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                // Session gallery thumbnail
                Box(
                    modifier = Modifier
                        .size(48.dp)
                        .clip(RoundedCornerShape(10.dp))
                        .background(Color.White.copy(alpha = 0.12f))
                        .border(1.dp, Color.White.copy(alpha = 0.25f), RoundedCornerShape(10.dp))
                        .clickable(enabled = !isRecording) { tick(); onOpenGallery() },
                    contentAlignment = Alignment.Center,
                ) {
                    val thumb = mediaItems.firstOrNull()?.thumbnail
                    if (thumb != null) {
                        Image(
                            thumb.asImageBitmap(), "Gallery",
                            contentScale = ContentScale.Crop,
                            modifier = Modifier.fillMaxSize(),
                        )
                    } else {
                        Icon(
                            Icons.Rounded.PhotoLibrary, "Gallery",
                            tint = Color.White.copy(alpha = 0.8f),
                        )
                    }
                }

                ShutterButton(
                    isVideo = captureMode == CaptureMode.VIDEO,
                    isRecording = isRecording,
                    enabled = status is DualCamEngine.Status.Ready,
                    onClick = ::triggerShutter,
                )

                GlassIconButton(
                    Icons.Rounded.Cameraswitch, "Swap cameras",
                    size = 48.dp, enabled = !isRecording,
                ) {
                    tick(); engine.swapCameras()
                }
            }
        }

        SnackbarHost(
            hostState = snackbar,
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(bottom = 140.dp),
        )
    }

    previewItem?.let { item ->
        CapturePreviewDialog(
            engine = engine,
            item = item,
            onDismiss = { previewItem = null },
        )
    }
}

// ── Pieces ──

@Composable
private fun GlassIconButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    contentDescription: String,
    size: androidx.compose.ui.unit.Dp = 42.dp,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    Box(
        modifier = Modifier
            .size(size)
            .clip(CircleShape)
            .background(Color.Black.copy(alpha = 0.35f))
            .border(1.dp, Color.White.copy(alpha = 0.15f), CircleShape)
            .clickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            icon, contentDescription,
            tint = Color.White.copy(alpha = if (enabled) 0.9f else 0.35f),
            modifier = Modifier.size(size * 0.5f),
        )
    }
}

@Composable
private fun ShutterButton(isVideo: Boolean, isRecording: Boolean, enabled: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .size(76.dp)
            .clip(CircleShape)
            .border(4.dp, Color.White.copy(alpha = if (enabled) 1f else 0.4f), CircleShape)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(7.dp),
        contentAlignment = Alignment.Center,
    ) {
        val inner = if (isVideo) Color(0xFFFF3B30) else Color.White
        Box(
            modifier = Modifier
                .fillMaxSize()
                .clip(if (isRecording) RoundedCornerShape(8.dp) else CircleShape)
                .padding(if (isRecording) 14.dp else 0.dp)
                .background(inner.copy(alpha = if (enabled) 1f else 0.4f),
                    if (isRecording) RoundedCornerShape(6.dp) else CircleShape),
        )
    }
}

@Composable
private fun ZoomControl(
    zoom: Float,
    maxZoom: Float,
    onZoomChange: (Float) -> Unit,
    onTick: () -> Unit,
) {
    val presets = buildList {
        add(1f)
        if (maxZoom >= 2.5f) add(2f)
        if (maxZoom >= 5.5f) add(5f)
        if (maxZoom > (lastOrNull() ?: 1f) + 0.5f) add(maxZoom)
    }

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.padding(horizontal = 24.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            presets.forEach { preset ->
                val active = kotlin.math.abs(zoom - preset) < 0.15f
                Text(
                    if (preset == preset.toInt().toFloat()) "${preset.toInt()}×"
                    else String.format(Locale.US, "%.1f×", preset),
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = if (active) Color.Black else MaterialTheme.colorScheme.primary,
                    modifier = Modifier
                        .clip(RoundedCornerShape(50))
                        .background(if (active) MaterialTheme.colorScheme.primary else Color.Black.copy(alpha = 0.45f))
                        .border(
                            1.dp,
                            MaterialTheme.colorScheme.primary.copy(alpha = if (active) 0f else 0.4f),
                            RoundedCornerShape(50),
                        )
                        .clickable { onTick(); onZoomChange(preset) }
                        .padding(horizontal = 12.dp, vertical = 7.dp),
                )
            }
        }
        Spacer(Modifier.height(10.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                String.format(Locale.US, if (zoom < 10) "%.1f×" else "%.0f×", zoom),
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.width(36.dp),
                textAlign = TextAlign.End,
            )
            Spacer(Modifier.width(10.dp))
            Slider(
                value = zoom,
                onValueChange = onZoomChange,
                valueRange = 1f..maxZoom,
                modifier = Modifier.weight(1f),
                colors = SliderDefaults.colors(
                    thumbColor = Color.White,
                    activeTrackColor = Color.White,
                    inactiveTrackColor = Color.White.copy(alpha = 0.25f),
                ),
            )
        }
    }
}

@Composable
private fun RecordingPill(seconds: Int) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(Color(0xFFFF3B30))
            .padding(horizontal = 12.dp, vertical = 5.dp),
    ) {
        Box(
            Modifier
                .size(8.dp)
                .clip(CircleShape)
                .background(Color.White)
        )
        Spacer(Modifier.width(6.dp))
        Text(
            String.format(Locale.US, "%d:%02d", seconds / 60, seconds % 60),
            style = MaterialTheme.typography.labelLarge,
            color = Color.White,
            fontWeight = FontWeight.SemiBold,
        )
    }
}

@Composable
private fun ZoomPill(zoom: Float) {
    Text(
        String.format(Locale.US, "%.1f×", zoom),
        style = MaterialTheme.typography.labelLarge,
        color = Color.White,
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(Color.Black.copy(alpha = 0.4f))
            .padding(horizontal = 12.dp, vertical = 5.dp),
    )
}

@Composable
private fun GridOverlay() {
    Canvas(modifier = Modifier.fillMaxSize()) {
        val color = Color.White.copy(alpha = 0.30f)
        for (i in 1..2) {
            drawLine(
                color,
                Offset(size.width * i / 3f, 0f),
                Offset(size.width * i / 3f, size.height),
                strokeWidth = 1f,
            )
            drawLine(
                color,
                Offset(0f, size.height * i / 3f),
                Offset(size.width, size.height * i / 3f),
                strokeWidth = 1f,
            )
        }
    }
}

@Composable
private fun FocusRing(position: Offset) {
    Canvas(modifier = Modifier.fillMaxSize()) {
        drawCircle(
            color = Color(0xFFFFD60A),
            radius = 38f,
            center = position,
            style = androidx.compose.ui.graphics.drawscope.Stroke(width = 3f),
        )
    }
}

@Composable
private fun StatusCard(title: String, message: String, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .padding(32.dp)
            .clip(RoundedCornerShape(20.dp))
            .background(Color(0xFF1C1C1E))
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(
            Icons.Rounded.BrokenImage, null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(36.dp),
        )
        Spacer(Modifier.height(12.dp))
        Text(title, style = MaterialTheme.typography.titleMedium, color = Color.White)
        Spacer(Modifier.height(6.dp))
        Text(
            message,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
    }
}

/** Flash + timer chip rows, like the iOS QuickSettingsPanel. */
@Composable
private fun QuickSettingsPanel(
    flashMode: FlashMode,
    flashAvailable: Boolean,
    timer: Int,
    onFlash: (FlashMode) -> Unit,
    onTimer: (Int) -> Unit,
    delayedDual: Boolean,
    onDelayedDual: (Boolean) -> Unit,
    delayedDualSeconds: Int,
    onDelayedDualSeconds: (Int) -> Unit,
) {
    Column(
        modifier = Modifier
            .clip(RoundedCornerShape(18.dp))
            .background(Color.Black.copy(alpha = 0.65f))
            .border(1.dp, Color.White.copy(alpha = 0.1f), RoundedCornerShape(18.dp))
            .padding(vertical = 6.dp),
    ) {
        QuickRow("Flash", enabled = flashAvailable) {
            FlashMode.entries.forEach { mode ->
                QuickChip(mode.label, selected = flashMode == mode) { onFlash(mode) }
            }
        }
        HorizontalDivider(
            color = Color.White.copy(alpha = 0.08f),
            modifier = Modifier.padding(horizontal = 14.dp),
        )
        QuickRow("Timer", enabled = true) {
            listOf(0 to "Off", 3 to "3s", 5 to "5s", 10 to "10s").forEach { (value, label) ->
                QuickChip(label, selected = timer == value) { onTimer(value) }
            }
        }
        HorizontalDivider(
            color = Color.White.copy(alpha = 0.08f),
            modifier = Modifier.padding(horizontal = 14.dp),
        )
        QuickRow("Delayed Dual", enabled = true) {
            QuickChip("Off", selected = !delayedDual) { onDelayedDual(false) }
            QuickChip("On", selected = delayedDual) { onDelayedDual(true) }
        }
        if (delayedDual) {
            HorizontalDivider(
                color = Color.White.copy(alpha = 0.08f),
                modifier = Modifier.padding(horizontal = 14.dp),
            )
            QuickRow("Delay", enabled = true) {
                listOf(3, 5, 10).forEach { value ->
                    QuickChip("${value}s", selected = delayedDualSeconds == value) {
                        onDelayedDualSeconds(value)
                    }
                }
            }
        }
    }
}

@Composable
private fun QuickRow(title: String, enabled: Boolean, chips: @Composable RowScope.() -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .padding(horizontal = 14.dp, vertical = 10.dp)
            .alpha(if (enabled) 1f else 0.35f),
    ) {
        Text(
            title,
            style = MaterialTheme.typography.labelMedium,
            color = Color.White.copy(alpha = 0.5f),
            modifier = Modifier.width(48.dp),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(5.dp), content = chips)
    }
}

@Composable
private fun QuickChip(label: String, selected: Boolean, onClick: () -> Unit) {
    Text(
        label,
        style = MaterialTheme.typography.labelMedium,
        fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
        color = if (selected) Color.Black else Color.White.copy(alpha = 0.75f),
        modifier = Modifier
            .clip(RoundedCornerShape(7.dp))
            .background(if (selected) Color.White else Color.White.copy(alpha = 0.1f))
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 5.dp),
    )
}

/** Post-capture modal: preview + Save / Share / Discard, like CapturePreviewModal. */
@Composable
fun CapturePreviewDialog(
    engine: DualCamEngine,
    item: MediaItem,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val destination by engine.settings.saveDestination.flow.collectAsState()

    val createDocument = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument(
            if (item.type == MediaType.PHOTO) "image/jpeg" else "video/mp4"
        )
    ) { uri ->
        if (uri != null) {
            val ok = when (item.type) {
                MediaType.PHOTO -> item.bitmap?.let { engine.saver.writePhotoTo(uri, it) } == true
                MediaType.VIDEO -> item.videoFile?.let { engine.saver.writeVideoTo(uri, it) } == true
            }
            if (ok) {
                item.savedUri = uri
                if (engine.settings.notifyOnSave.value) engine.saver.notifySaved("Saved to Files")
            }
            onDismiss()
        }
    }

    Dialog(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .clip(RoundedCornerShape(24.dp))
                .background(MaterialTheme.colorScheme.surfaceContainer)
                .padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            val preview = item.bitmap ?: item.thumbnail
            if (preview != null) {
                Image(
                    preview.asImageBitmap(), "Capture preview",
                    contentScale = ContentScale.Fit,
                    modifier = Modifier
                        .heightIn(max = 420.dp)
                        .clip(RoundedCornerShape(16.dp)),
                )
            }
            Spacer(Modifier.height(8.dp))
            Text(
                if (item.type == MediaType.PHOTO) "Photo · ${item.pair.label}"
                else "Video · ${item.pair.label}",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(12.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                TextButton(onClick = { engine.discard(item); onDismiss() }) { Text("Discard") }
                TextButton(onClick = { shareMediaItem(context, engine, item) }) { Text("Share") }
                Button(onClick = {
                    when (destination) {
                        SaveDestination.PHOTOS -> {
                            engine.autoSave(item)
                            onDismiss()
                        }

                        SaveDestination.FILES -> createDocument.launch(suggestedFileName(item))
                    }
                }) {
                    Text(if (destination == SaveDestination.PHOTOS) "Save" else "Save to…")
                }
            }
        }
    }
}
