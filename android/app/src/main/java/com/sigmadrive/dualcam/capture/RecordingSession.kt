package com.sigmadrive.dualcam.capture

import android.content.Context
import android.media.MediaRecorder
import android.os.Build
import android.view.Surface
import com.sigmadrive.dualcam.model.RecordingCodec
import java.io.File

/**
 * One MediaRecorder in surface-input mode; the RenderPipeline renders the
 * composited (or raw) frames into [surface]. Audio is captured only on the
 * main composite recording.
 */
class RecordingSession(
    context: Context,
    val outputFile: File,
    val width: Int,
    val height: Int,
    codec: RecordingCodec,
    withAudio: Boolean,
) {
    private val recorder: MediaRecorder =
        if (Build.VERSION.SDK_INT >= 31) MediaRecorder(context) else @Suppress("DEPRECATION") MediaRecorder()

    val surface: Surface

    init {
        if (withAudio) recorder.setAudioSource(MediaRecorder.AudioSource.CAMCORDER)
        recorder.setVideoSource(MediaRecorder.VideoSource.SURFACE)
        recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
        recorder.setOutputFile(outputFile.absolutePath)
        recorder.setVideoEncodingBitRate(codec.bitrateFor(width, height))
        recorder.setVideoFrameRate(30)
        recorder.setVideoSize(width, height)
        recorder.setVideoEncoder(
            if (codec.isHevc) MediaRecorder.VideoEncoder.HEVC else MediaRecorder.VideoEncoder.H264
        )
        if (withAudio) {
            recorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            recorder.setAudioEncodingBitRate(128_000)
            recorder.setAudioSamplingRate(44_100)
        }
        recorder.prepare()
        surface = recorder.surface
    }

    fun start() = recorder.start()

    /** Returns false if nothing valid was written (e.g. stopped immediately). */
    fun stop(): Boolean = try {
        recorder.stop()
        true
    } catch (_: RuntimeException) {
        outputFile.delete()
        false
    } finally {
        recorder.release()
    }
}
