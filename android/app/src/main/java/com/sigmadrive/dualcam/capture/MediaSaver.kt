package com.sigmadrive.dualcam.capture

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.StatFs
import android.provider.MediaStore
import androidx.core.app.NotificationCompat
import androidx.core.content.FileProvider
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Export layer: MediaStore (the "Photos" destination) and content-Uri copies
 * for the SAF "Files" destination, plus save notifications and temp-file
 * housekeeping.
 */
class MediaSaver(private val context: Context) {

    companion object {
        private const val ALBUM = "dualCam"
        private const val CHANNEL_SAVES = "saves"
        const val CHANNEL_RECORDING = "recording"
    }

    init {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_SAVES, "Saved captures", NotificationManager.IMPORTANCE_LOW)
        )
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_RECORDING, "Recording", NotificationManager.IMPORTANCE_LOW)
        )
    }

    fun timestampName(prefix: String, ext: String): String {
        val ts = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
        return "${prefix}_$ts.$ext"
    }

    fun tempFile(prefix: String, ext: String): File {
        val dir = File(context.cacheDir, "captures").apply { mkdirs() }
        return File(dir, timestampName(prefix, ext))
    }

    fun cleanTempFiles(olderThanMs: Long = 24 * 60 * 60 * 1000L) {
        val dir = File(context.cacheDir, "captures")
        val cutoff = System.currentTimeMillis() - olderThanMs
        dir.listFiles()?.forEach { if (it.lastModified() < cutoff) it.delete() }
    }

    fun freeBytes(): Long = StatFs(context.cacheDir.absolutePath).availableBytes

    /** Saves a photo bitmap into the gallery (Pictures/dualCam). */
    fun savePhotoToGallery(bitmap: Bitmap): Uri? {
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, timestampName("dualCam", "jpg"))
            put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
            put(MediaStore.Images.Media.RELATIVE_PATH, "DCIM/$ALBUM")
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val resolver = context.contentResolver
        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values) ?: return null
        resolver.openOutputStream(uri)?.use { bitmap.compress(Bitmap.CompressFormat.JPEG, 92, it) }
        values.clear()
        values.put(MediaStore.Images.Media.IS_PENDING, 0)
        resolver.update(uri, values, null, null)
        return uri
    }

    /** Saves a finished video temp file into the gallery (Movies/dualCam). */
    fun saveVideoToGallery(file: File): Uri? {
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, file.name)
            put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
            put(MediaStore.Video.Media.RELATIVE_PATH, "DCIM/$ALBUM")
            put(MediaStore.Video.Media.IS_PENDING, 1)
        }
        val resolver = context.contentResolver
        val uri = resolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values) ?: return null
        resolver.openOutputStream(uri)?.use { out -> file.inputStream().use { it.copyTo(out) } }
        values.clear()
        values.put(MediaStore.Video.Media.IS_PENDING, 0)
        resolver.update(uri, values, null, null)
        MediaScannerConnection.scanFile(context, arrayOf(file.absolutePath), null, null)
        return uri
    }

    /** Writes a photo into a user-picked SAF document Uri ("Files" destination). */
    fun writePhotoTo(uri: Uri, bitmap: Bitmap): Boolean = try {
        context.contentResolver.openOutputStream(uri)?.use {
            bitmap.compress(Bitmap.CompressFormat.JPEG, 92, it)
        } != null
    } catch (_: Exception) {
        false
    }

    /** Copies a video temp file into a user-picked SAF document Uri. */
    fun writeVideoTo(uri: Uri, file: File): Boolean = try {
        context.contentResolver.openOutputStream(uri)?.use { out ->
            file.inputStream().use { it.copyTo(out) }
        } != null
    } catch (_: Exception) {
        false
    }

    /** Content Uri for sharing a cached capture via FileProvider. */
    fun shareUri(file: File): Uri =
        FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)

    fun notifySaved(message: String) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val notification = NotificationCompat.Builder(context, CHANNEL_SAVES)
            .setSmallIcon(android.R.drawable.ic_menu_save)
            .setContentTitle("dualCam")
            .setContentText(message)
            .setTimeoutAfter(4000)
            .build()
        try {
            nm.notify((System.currentTimeMillis() % 10000).toInt(), notification)
        } catch (_: SecurityException) {
            // Notification permission declined — saving still succeeded.
        }
    }
}
