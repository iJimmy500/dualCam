package com.sigmadrive.dualcam.ui

import android.text.format.Formatter
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.sigmadrive.dualcam.camera.DualCamEngine
import com.sigmadrive.dualcam.model.*
import com.sigmadrive.dualcam.settings.AppSettings

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(engine: DualCamEngine, onBack: () -> Unit) {
    val settings = engine.settings
    val availablePairs by engine.availablePairs.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Settings") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Rounded.ArrowBack, "Back")
                    }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            CameraPairSection(settings, availablePairs, engine)
            CameraSection(settings, engine)
            CaptureSection(settings)
            GeneralSection(settings)
            NotificationsSection(settings)
            ExperimentalSection(settings)
            StorageSection(settings, engine)
            AboutSection()
            Spacer(Modifier.height(24.dp))
        }
    }
}

// ── Sections ──

@Composable
private fun CameraPairSection(
    settings: AppSettings,
    availablePairs: List<CameraPair>,
    engine: DualCamEngine,
) {
    val current by settings.cameraPair.flow.collectAsState()
    SettingsSection("Camera Pair") {
        CameraPair.entries.forEach { pair ->
            val available = pair in availablePairs
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .clickable(enabled = available) { engine.selectPair(pair) }
                    .padding(horizontal = 4.dp, vertical = 10.dp),
            ) {
                RadioButton(
                    selected = pair == current,
                    onClick = { if (available) engine.selectPair(pair) },
                    enabled = available,
                )
                Column(Modifier.weight(1f)) {
                    Text(
                        pair.label,
                        style = MaterialTheme.typography.bodyLarge,
                        color = if (available) MaterialTheme.colorScheme.onSurface
                        else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
                    )
                    if (!available) {
                        Text(
                            "Not supported on this device",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun CameraSection(settings: AppSettings, engine: DualCamEngine) {
    val layoutMode by settings.layoutMode.flow.collectAsState()
    val pipShape by settings.pipShape.flow.collectAsState()
    val frameStyle by settings.pipFrameStyle.flow.collectAsState()
    val frameColor by settings.pipFrameColor.flow.collectAsState()
    val quality by settings.videoQuality.flow.collectAsState()
    val split by settings.spotlightSplit.flow.collectAsState()
    val gap by settings.spotlightGap.flow.collectAsState()

    SettingsSection("Camera") {
        ToggleRow("Haptic Feedback", settings.hapticFeedback)
        ToggleRow("Grid Overlay", settings.showGridOverlay)

        SubLabel("Capture Layout")
        SegmentedEnum(LayoutMode.entries, layoutMode, { it.shortLabel }) {
            settings.layoutMode.value = it
        }

        if (layoutMode == LayoutMode.PIP) {
            SubLabel("PiP Window Shape")
            SegmentedEnum(PipShape.entries, pipShape, { it.label }) {
                settings.pipShape.value = it
            }

            SubLabel("PiP Frame Style")
            ChipFlow(PipFrameStyle.entries, frameStyle, { it.label }) {
                settings.pipFrameStyle.value = it
            }

            SubLabel("Frame Color")
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                PipFrameColor.entries.forEach { c ->
                    Box(
                        modifier = Modifier
                            .size(30.dp)
                            .clip(CircleShape)
                            .background(c.swatchColor)
                            .border(
                                width = if (c == frameColor) 3.dp else 1.dp,
                                color = if (c == frameColor) MaterialTheme.colorScheme.primary
                                else Color.White.copy(alpha = 0.2f),
                                shape = CircleShape,
                            )
                            .clickable { settings.pipFrameColor.value = c },
                    )
                }
            }
        } else {
            SubLabel("Split Ratio")
            SegmentedEnum(SpotlightSplit.entries, split, { it.label }) {
                settings.spotlightSplit.value = it
            }

            SubLabel("Divider Gap")
            SegmentedEnum(SpotlightGap.entries, gap, { it.label }) {
                settings.spotlightGap.value = it
            }
        }

        SubLabel("Video Quality")
        SegmentedEnum(
            VideoQuality.entries, quality,
            { it.label.substringBefore(" (") },
        ) {
            settings.videoQuality.value = it
            engine.reconfigureQuality()
        }
        if (quality == VideoQuality.HIGH) {
            Text(
                "High quality requires significantly more processing power and " +
                    "may fail on older devices or with long recordings.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 6.dp),
            )
        }
    }
}

@Composable
private fun CaptureSection(settings: AppSettings) {
    val destination by settings.saveDestination.flow.collectAsState()
    val codec by settings.recordingCodec.flow.collectAsState()

    SettingsSection("Capture") {
        ToggleRow("Show Capture Preview", settings.showCapturePreview, "Review each capture before saving")
        ToggleRow("Sound on Capture", settings.soundOnCapture)
        ToggleRow("Auto-Save Raw Feeds", settings.autoSaveRawFeeds, "Also save each camera's own video")
        ToggleRow(
            "Delayed Dual Capture", settings.delayedDualCapture,
            "Capture the main camera now, then the other after a countdown"
        )

        SubLabel("Save Destination")
        SaveDestination.entries.forEach { dest ->
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .clickable { settings.saveDestination.value = dest }
                    .padding(vertical = 6.dp),
            ) {
                RadioButton(
                    selected = destination == dest,
                    onClick = { settings.saveDestination.value = dest },
                )
                Column {
                    Text(dest.label, style = MaterialTheme.typography.bodyLarge)
                    Text(
                        dest.note,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }

        SubLabel("Recording Codec")
        RecordingCodec.entries.forEach { c ->
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .clickable { settings.recordingCodec.value = c }
                    .padding(vertical = 6.dp),
            ) {
                RadioButton(selected = codec == c, onClick = { settings.recordingCodec.value = c })
                Column {
                    Text(c.label, style = MaterialTheme.typography.bodyLarge)
                    Text(
                        c.note,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

@Composable
private fun GeneralSection(settings: AppSettings) {
    SettingsSection("General") {
        ToggleRow("Keep Screen On", settings.screenAlwaysOn)
        ToggleRow("Reset Zoom on Swap", settings.zoomResetOnSwap)
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .clickable { settings.hasSeenWelcome.value = false }
                .padding(vertical = 12.dp, horizontal = 4.dp),
        ) {
            Column {
                Text("Show Welcome Screen", style = MaterialTheme.typography.bodyLarge)
                Text(
                    "View the app introduction again",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun NotificationsSection(settings: AppSettings) {
    SettingsSection("Notifications") {
        ToggleRow("Notify on Save", settings.notifyOnSave)
    }
}

@Composable
private fun ExperimentalSection(settings: AppSettings) {
    val limit by settings.recordingLimitSeconds.flow.collectAsState()
    val extended by settings.extendedRecording.flow.collectAsState()

    SettingsSection("Experimental", badge = "BETA") {
        ToggleRow("Extended Recording", settings.extendedRecording, "Removes the recording time limit")
        if (!extended) {
            SubLabel("Recording Limit")
            SegmentedOptions(
                listOf(150 to "2.5 min", 300 to "5 min", 600 to "10 min"),
                limit,
            ) { settings.recordingLimitSeconds.value = it }
        }
        ToggleRow("Mirror Front Camera", settings.mirrorFrontCamera)
        ToggleRow("Volume Button Shutter", settings.volumeShutter)
        ToggleRow("Show Debug Info", settings.showDebugInfo)
    }
}

@Composable
private fun StorageSection(settings: AppSettings, engine: DualCamEngine) {
    val context = LocalContext.current
    SettingsSection("Storage") {
        ToggleRow("Storage Warnings", settings.showStorageWarnings)
        ToggleRow("Auto-Clean Temp Files", settings.autoCleanTempFiles)
        Text(
            "Free space: " + Formatter.formatFileSize(context, engine.saver.freeBytes()),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 8.dp, start = 4.dp),
        )
    }
    SettingsSection("Audio") {
        ToggleRow("Mix Audio with Music", settings.mixAudioWithMusic, "Keep music playing while recording")
    }
}

@Composable
private fun AboutSection() {
    SettingsSection("About") {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(vertical = 8.dp, horizontal = 4.dp),
        ) {
            Column {
                Text("dualCam for Android", style = MaterialTheme.typography.bodyLarge)
                Text(
                    "Version 1.0 (1) · by Phushsia",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

// ── Building blocks ──

@Composable
private fun SettingsSection(
    title: String,
    badge: String? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 16.dp, bottom = 6.dp)) {
            Text(
                title.uppercase(),
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (badge != null) {
                Spacer(Modifier.width(8.dp))
                Text(
                    badge,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier
                        .background(
                            MaterialTheme.colorScheme.primaryContainer,
                            RoundedCornerShape(6.dp)
                        )
                        .padding(horizontal = 6.dp, vertical = 2.dp),
                )
            }
        }
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(MaterialTheme.colorScheme.surfaceContainer)
                .padding(12.dp),
            content = content,
        )
    }
}

@Composable
private fun ToggleRow(title: String, pref: AppSettings.Pref<Boolean>, subtitle: String? = null) {
    val value by pref.flow.collectAsState()
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .clickable { pref.value = !value }
            .padding(vertical = 6.dp, horizontal = 4.dp),
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            if (subtitle != null) {
                Text(
                    subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        Switch(checked = value, onCheckedChange = { pref.value = it })
    }
}

@Composable
private fun SubLabel(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(top = 14.dp, bottom = 8.dp, start = 4.dp),
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun <T> SegmentedEnum(
    options: List<T>,
    selected: T,
    label: (T) -> String,
    onSelect: (T) -> Unit,
) {
    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
        options.forEachIndexed { index, option ->
            SegmentedButton(
                selected = option == selected,
                onClick = { onSelect(option) },
                shape = SegmentedButtonDefaults.itemShape(index, options.size),
            ) { Text(label(option), maxLines = 1) }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SegmentedOptions(
    options: List<Pair<Int, String>>,
    selected: Int,
    onSelect: (Int) -> Unit,
) {
    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
        options.forEachIndexed { index, (value, label) ->
            SegmentedButton(
                selected = value == selected,
                onClick = { onSelect(value) },
                shape = SegmentedButtonDefaults.itemShape(index, options.size),
            ) { Text(label, maxLines = 1) }
        }
    }
}

@Composable
private fun <T> ChipFlow(
    options: List<T>,
    selected: T,
    label: (T) -> String,
    onSelect: (T) -> Unit,
) {
    LazyVerticalGrid(
        columns = GridCells.Fixed(4),
        verticalArrangement = Arrangement.spacedBy(6.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(max = 110.dp),
        userScrollEnabled = false,
    ) {
        items(options.size) { i ->
            val option = options[i]
            FilterChip(
                selected = option == selected,
                onClick = { onSelect(option) },
                label = {
                    Text(
                        label(option),
                        maxLines = 1,
                        modifier = Modifier.fillMaxWidth(),
                        style = MaterialTheme.typography.labelMedium,
                    )
                },
            )
        }
    }
}
