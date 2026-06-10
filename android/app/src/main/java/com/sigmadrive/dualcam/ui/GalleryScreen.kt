package com.sigmadrive.dualcam.ui

import android.net.Uri
import android.widget.VideoView
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.PlayCircle
import androidx.compose.material.icons.rounded.Save
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.sigmadrive.dualcam.camera.DualCamEngine
import com.sigmadrive.dualcam.model.MediaItem
import com.sigmadrive.dualcam.model.MediaType
import com.sigmadrive.dualcam.model.SaveDestination
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private enum class MediaFilter(val label: String) { ALL("All"), PHOTOS("Photos"), VIDEOS("Videos") }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GalleryScreen(engine: DualCamEngine, onBack: () -> Unit) {
    val items by engine.mediaItems.collectAsState()
    var filter by remember { mutableStateOf(MediaFilter.ALL) }
    var selected by remember { mutableStateOf<MediaItem?>(null) }

    val filtered = when (filter) {
        MediaFilter.ALL -> items
        MediaFilter.PHOTOS -> items.filter { it.type == MediaType.PHOTO }
        MediaFilter.VIDEOS -> items.filter { it.type == MediaType.VIDEO }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Session Captures") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Rounded.ArrowBack, "Back")
                    }
                },
            )
        },
    ) { padding ->
        Column(Modifier.padding(padding)) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            ) {
                MediaFilter.entries.forEach { f ->
                    FilterChip(
                        selected = filter == f,
                        onClick = { filter = f },
                        label = { Text(f.label) },
                    )
                }
            }

            if (filtered.isEmpty()) {
                Column(
                    modifier = Modifier.fillMaxSize(),
                    verticalArrangement = Arrangement.Center,
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text("No captures yet", style = MaterialTheme.typography.titleMedium)
                    Text(
                        "Photos and videos from this session show up here.\nSaved items stay in your gallery app.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.padding(top = 8.dp),
                    )
                }
            } else {
                LazyVerticalGrid(
                    columns = GridCells.Fixed(3),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                    contentPadding = PaddingValues(16.dp),
                ) {
                    items(filtered, key = { it.id }) { item ->
                        Box(
                            modifier = Modifier
                                .aspectRatio(1f)
                                .clip(RoundedCornerShape(10.dp))
                                .background(MaterialTheme.colorScheme.surfaceContainerHigh)
                                .clickable { selected = item },
                        ) {
                            item.thumbnail?.let {
                                Image(
                                    it.asImageBitmap(), null,
                                    contentScale = ContentScale.Crop,
                                    modifier = Modifier.fillMaxSize(),
                                )
                            }
                            if (item.type == MediaType.VIDEO) {
                                Icon(
                                    Icons.Rounded.PlayCircle, "Video",
                                    tint = Color.White.copy(alpha = 0.9f),
                                    modifier = Modifier
                                        .align(Alignment.Center)
                                        .size(32.dp),
                                )
                            }
                            if (item.savedUri != null) {
                                Icon(
                                    Icons.Rounded.Check, "Saved",
                                    tint = Color.White,
                                    modifier = Modifier
                                        .align(Alignment.TopEnd)
                                        .padding(4.dp)
                                        .size(16.dp)
                                        .background(
                                            MaterialTheme.colorScheme.primary.copy(alpha = 0.85f),
                                            RoundedCornerShape(50)
                                        )
                                        .padding(2.dp),
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    selected?.let { item ->
        MediaDetailSheet(engine, item, onClose = { selected = null })
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MediaDetailSheet(engine: DualCamEngine, item: MediaItem, onClose: () -> Unit) {
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
        }
    }

    ModalBottomSheet(onDismissRequest = onClose) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .padding(bottom = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            when (item.type) {
                MediaType.PHOTO -> item.bitmap?.let {
                    Image(
                        it.asImageBitmap(), "Photo",
                        contentScale = ContentScale.Fit,
                        modifier = Modifier
                            .heightIn(max = 460.dp)
                            .clip(RoundedCornerShape(16.dp)),
                    )
                }

                MediaType.VIDEO -> item.videoFile?.let { file ->
                    AndroidView(
                        factory = { ctx ->
                            VideoView(ctx).apply {
                                setVideoURI(Uri.fromFile(file))
                                setOnPreparedListener { mp ->
                                    mp.isLooping = true
                                    start()
                                }
                            }
                        },
                        modifier = Modifier
                            .heightIn(max = 460.dp)
                            .aspectRatio(9f / 16f)
                            .clip(RoundedCornerShape(16.dp)),
                    )
                }
            }

            Spacer(Modifier.height(8.dp))
            Text(
                "${item.pair.label} · " +
                    SimpleDateFormat("HH:mm:ss", Locale.getDefault()).format(Date(item.createdAt)) +
                    if (item.rawVideoFiles.isNotEmpty()) " · +${item.rawVideoFiles.size} raw feeds" else "",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(12.dp))

            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                FilledTonalButton(onClick = {
                    when (destination) {
                        SaveDestination.PHOTOS -> engine.autoSave(item)
                        SaveDestination.FILES -> createDocument.launch(suggestedFileName(item))
                    }
                }) {
                    Icon(Icons.Rounded.Save, null, Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(if (item.savedUri != null) "Save again" else "Save")
                }
                FilledTonalButton(onClick = { shareMediaItem(context, engine, item) }) {
                    Icon(Icons.Rounded.Share, null, Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Share")
                }
                FilledTonalButton(
                    onClick = { engine.discard(item); onClose() },
                    colors = ButtonDefaults.filledTonalButtonColors(
                        contentColor = MaterialTheme.colorScheme.error
                    ),
                ) {
                    Icon(Icons.Rounded.Delete, null, Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Delete")
                }
            }
        }
    }
}
