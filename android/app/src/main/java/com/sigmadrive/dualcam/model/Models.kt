package com.sigmadrive.dualcam.model

import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.ui.graphics.Color
import java.io.File
import java.util.UUID

// Mirrors the iOS app's enums in MediaItem.swift / AppSettings.swift.

enum class LayoutMode(val label: String, val shortLabel: String) {
    PIP("Picture in Picture", "PiP"),
    SPOTLIGHT("Spotlight", "Spotlight"),
}

enum class PipShape(val label: String) {
    ROUNDED_RECT("Rounded Rect"),
    CIRCLE("Circle"),
}

enum class PipFrameStyle(val label: String) {
    NONE("None"),
    SOLID("Solid"),
    THICK("Thick"),
    DOUBLE("Double"),
    DASHED("Dashed"),
    GLASS("Glass"),
    GLOW("Glow"),
    NEON("Neon"),
}

enum class PipFrameColor(val label: String, val color: Color) {
    WHITE("White", Color.White),
    SILVER("Silver", Color(0xFFB8B8B8)),
    BLACK("Black", Color(0xFF141414)),
    GOLD("Gold", Color(0xFFFFD60A)),
    BLUE("Blue", Color(0xFF3399FF)),
    ROSE("Rose", Color(0xFFFF598C)),
    MINT("Mint", Color(0xFF2EE0A8)),
    ORANGE("Orange", Color(0xFFFF8C1A));

    // Swatch dot shown in settings — black lightened for visibility on dark bg
    val swatchColor: Color get() = if (this == BLACK) Color(0xFF383838) else color
}

enum class VideoQuality(val label: String, val width: Int, val height: Int) {
    HIGH("High (4K)", 2160, 3840),
    MEDIUM("Mid (1080p rec.)", 1080, 1920),
    LOW("Low (720p)", 720, 1280),
}

enum class SpotlightSplit(val label: String, val mainFraction: Float) {
    HALF("50/50", 0.50f),
    SLIGHT("60/40", 0.60f),
    STANDARD("65/35", 0.65f),
    MAJOR("70/30", 0.70f),
}

enum class SpotlightGap(val label: String, val dp: Float) {
    NONE("None", 0f),
    THIN("Thin", 4f),
    THICK("Thick", 12f),
}

enum class RecordingCodec(val label: String, val note: String, val bitrate1080p: Int) {
    H264(
        "Standard — H.264 · 4 Mbps",
        "No battery optimization. Maximum device compatibility.",
        4_000_000
    ),
    HEVC_SAFE(
        "Efficient — HEVC · 4 Mbps",
        "Same quality as Standard. Smaller files, less I/O, modest battery savings. Recommended.",
        4_000_000
    ),
    HEVC_SAVE(
        "Power Save — HEVC · 2.5 Mbps",
        "Smallest files, most battery savings. Possible quality drop on fast motion.",
        2_500_000
    );

    val isHevc: Boolean get() = this != H264

    /** Scale the 1080p reference bitrate to the actual output resolution. */
    fun bitrateFor(width: Int, height: Int): Int {
        val scale = (width.toLong() * height) / (1080.0 * 1920.0)
        return (bitrate1080p * scale).toInt().coerceAtLeast(1_500_000)
    }
}

enum class SaveDestination(val label: String, val note: String) {
    PHOTOS("Photos", "Saves directly to your photo gallery"),
    FILES("Files", "Pick a save location each time"),
}

enum class FlashMode(val label: String) { OFF("Off"), AUTO("Auto"), ON("On") }

/** Which physical lens a pair slot wants. */
enum class Lens { FRONT, WIDE, ULTRAWIDE, TELEPHOTO }

/**
 * Camera pairs from the iOS app. [background] is the main/full-screen feed,
 * [pip] is the secondary feed shown in the PiP window / smaller spotlight pane.
 */
enum class CameraPair(
    val label: String,
    val shortLabel: String,
    val background: Lens,
    val pip: Lens,
) {
    FRONT_AND_BACK("Front + Back", "F + B", Lens.WIDE, Lens.FRONT),
    WIDE_AND_ULTRAWIDE("Wide + Ultra", "W + U", Lens.WIDE, Lens.ULTRAWIDE),
    ULTRA_AND_FRONT("Ultra + Front", "U + F", Lens.ULTRAWIDE, Lens.FRONT),
    WIDE_AND_TELEPHOTO("Wide + Tele", "W + T", Lens.WIDE, Lens.TELEPHOTO),
    TELEPHOTO_AND_FRONT("Tele + Front", "T + F", Lens.TELEPHOTO, Lens.FRONT),
    ULTRAWIDE_AND_TELEPHOTO("Ultra + Tele", "U + T", Lens.ULTRAWIDE, Lens.TELEPHOTO);

    val requiresTelephoto: Boolean
        get() = background == Lens.TELEPHOTO || pip == Lens.TELEPHOTO
}

enum class MediaType { PHOTO, VIDEO }

/**
 * Normalized PiP placement on the 9:16 canvas. [cx]/[cy] are the window center,
 * [width] is the window width — all as fractions of canvas width/height.
 */
data class PipTransform(
    val cx: Float = 0.22f,
    val cy: Float = 0.16f,
    val width: Float = 0.32f,
)

/** A capture from this session, kept in the in-app gallery (like iOS MediaItem). */
class MediaItem(
    val type: MediaType,
    val pair: CameraPair,
    val bitmap: Bitmap? = null,          // photos: the composited result
    val videoFile: File? = null,         // videos: composited temp file
    val rawVideoFiles: List<File> = emptyList(),
    val thumbnail: Bitmap? = null,
) {
    val id: UUID = UUID.randomUUID()
    val createdAt: Long = System.currentTimeMillis()
    var savedUri: Uri? = null            // set once exported to MediaStore / SAF
}
