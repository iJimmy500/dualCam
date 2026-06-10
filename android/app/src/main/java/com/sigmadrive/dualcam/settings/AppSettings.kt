package com.sigmadrive.dualcam.settings

import android.content.Context
import android.content.SharedPreferences
import com.sigmadrive.dualcam.model.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * SharedPreferences-backed settings, exposed as StateFlows so Compose and the
 * camera engine both react to changes — the Android counterpart of the iOS
 * @AppStorage-based AppSettings class.
 */
class AppSettings(context: Context) {

    companion object {
        @Volatile private var instance: AppSettings? = null
        fun get(context: Context): AppSettings =
            instance ?: synchronized(this) {
                instance ?: AppSettings(context.applicationContext).also { instance = it }
            }
    }

    private val prefs: SharedPreferences =
        context.getSharedPreferences("dualcam_settings", Context.MODE_PRIVATE)

    inner class Pref<T>(
        private val key: String,
        default: T,
        private val read: (SharedPreferences, String, T) -> T,
        private val write: (SharedPreferences.Editor, String, T) -> Unit,
    ) {
        private val state = MutableStateFlow(read(prefs, key, default))
        val flow: StateFlow<T> get() = state
        var value: T
            get() = state.value
            set(new) {
                state.value = new
                prefs.edit().also { write(it, key, new) }.apply()
            }
    }

    private fun bool(key: String, default: Boolean) =
        Pref(key, default, { p, k, d -> p.getBoolean(k, d) }, { e, k, v -> e.putBoolean(k, v) })

    private fun int(key: String, default: Int) =
        Pref(key, default, { p, k, d -> p.getInt(k, d) }, { e, k, v -> e.putInt(k, v) })

    private fun float(key: String, default: Float) =
        Pref(key, default, { p, k, d -> p.getFloat(k, d) }, { e, k, v -> e.putFloat(k, v) })

    private inline fun <reified E : Enum<E>> enum(key: String, default: E) =
        Pref(
            key, default,
            { p, k, d -> p.getString(k, null)?.let { s -> enumValues<E>().find { it.name == s } } ?: d },
            { e, k, v -> e.putString(k, v.name) },
        )

    // Camera
    val hapticFeedback = bool("hapticFeedback", true)
    val showGridOverlay = bool("showGridOverlay", false)
    val layoutMode = enum("layoutMode", LayoutMode.PIP)
    val captureTimer = int("captureTimer", 0)            // 0 / 3 / 5 / 10 seconds
    val delayedDualCapture = bool("delayedDualCapture", false)
    val delayedDualCaptureSeconds = int("delayedDualCaptureSeconds", 3)  // 3 / 5 / 10 seconds
    val pipFrameStyle = enum("pipFrameStyle", PipFrameStyle.GLASS)
    val pipFrameColor = enum("pipFrameColor", PipFrameColor.WHITE)
    val pipShape = enum("pipShape", PipShape.ROUNDED_RECT)
    val videoQuality = enum("videoQuality", VideoQuality.MEDIUM)
    val spotlightSplit = enum("spotlightSplit", SpotlightSplit.STANDARD)
    val spotlightGap = enum("spotlightGap", SpotlightGap.THIN)
    val cameraPair = enum("cameraPair", CameraPair.FRONT_AND_BACK)
    val flashMode = enum("flashMode", FlashMode.OFF)

    // PiP placement (persisted like iOS layout state)
    val pipCenterX = float("pipCenterX", 0.22f)
    val pipCenterY = float("pipCenterY", 0.16f)
    val pipWidth = float("pipWidth", 0.32f)

    // After capture
    val showCapturePreview = bool("showCapturePreview", true)
    val soundOnCapture = bool("soundOnCapture", false)
    val autoSaveRawFeeds = bool("autoSaveRawFeeds", false)
    val saveDestination = enum("saveDestination", SaveDestination.PHOTOS)

    // General QoL
    val screenAlwaysOn = bool("screenAlwaysOn", true)
    val zoomResetOnSwap = bool("zoomResetOnSwap", true)

    // Experimental
    val recordingLimitSeconds = int("recordingLimitSeconds", 150)   // 150 / 300 / 600
    val extendedRecording = bool("extendedRecording", false)
    val showDebugInfo = bool("showDebugInfo", false)
    // Per-physical-camera debug rotation/mirror, since the two sensors can need
    // different corrections (e.g. front rot270 vs back rot90).
    val debugRotationOffsetA = int("debugRotationOffsetA", 0)   // 0/90/180/270, added to feedA's sensor rotation
    val debugRotationOffsetB = int("debugRotationOffsetB", 0)   // 0/90/180/270, added to feedB's sensor rotation
    val debugExtraMirrorA = bool("debugExtraMirrorA", false)    // extra horizontal flip on feedA
    val debugExtraMirrorB = bool("debugExtraMirrorB", false)    // extra horizontal flip on feedB
    val mirrorFrontCamera = bool("mirrorFrontCamera", true)
    val volumeShutter = bool("volumeShutter", false)

    // Storage
    val showStorageWarnings = bool("showStorageWarnings", true)
    val autoCleanTempFiles = bool("autoCleanTempFiles", true)

    // Audio
    val mixAudioWithMusic = bool("mixAudioWithMusic", true)

    // Notifications
    val notifyOnSave = bool("notifyOnSave", true)

    // Onboarding
    val hasSeenWelcome = bool("hasSeenWelcome", false)

    val recordingCodec = enum("recordingCodec", RecordingCodec.HEVC_SAFE)

    fun pipTransform() = PipTransform(pipCenterX.value, pipCenterY.value, pipWidth.value)

    fun savePipTransform(t: PipTransform) {
        pipCenterX.value = t.cx
        pipCenterY.value = t.cy
        pipWidth.value = t.width
    }
}
