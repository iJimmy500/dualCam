package com.sigmadrive.dualcam.ui

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import com.sigmadrive.dualcam.camera.DualCamEngine
import com.sigmadrive.dualcam.model.MediaItem
import com.sigmadrive.dualcam.model.MediaType

/** Opens the system share sheet for a session capture. */
fun shareMediaItem(context: Context, engine: DualCamEngine, item: MediaItem) {
    val (uri, mime) = when (item.type) {
        MediaType.PHOTO -> {
            val bitmap = item.bitmap ?: return
            val file = engine.saver.tempFile("share", "jpg")
            file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 92, it) }
            engine.saver.shareUri(file) to "image/jpeg"
        }

        MediaType.VIDEO -> {
            val file = item.videoFile ?: return
            engine.saver.shareUri(file) to "video/mp4"
        }
    }
    val intent = Intent(Intent.ACTION_SEND).apply {
        type = mime
        putExtra(Intent.EXTRA_STREAM, uri)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    context.startActivity(Intent.createChooser(intent, "Share capture"))
}

fun suggestedFileName(item: MediaItem): String =
    if (item.type == MediaType.PHOTO) "dualCam_${item.id.toString().take(8)}.jpg"
    else item.videoFile?.name ?: "dualCam_${item.id.toString().take(8)}.mp4"
