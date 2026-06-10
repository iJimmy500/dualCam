package com.sigmadrive.dualcam

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import android.view.KeyEvent
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.lifecycleScope
import com.sigmadrive.dualcam.camera.DualCamEngine
import com.sigmadrive.dualcam.ui.CameraScreen
import com.sigmadrive.dualcam.ui.GalleryScreen
import com.sigmadrive.dualcam.ui.SettingsScreen
import com.sigmadrive.dualcam.ui.WelcomeScreen
import com.sigmadrive.dualcam.ui.theme.DualCamTheme
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.launch

enum class Screen { CAMERA, SETTINGS, GALLERY }

class MainActivity : ComponentActivity() {

    private val engine: DualCamEngine by viewModels()
    private val shutterEvents = MutableSharedFlow<Unit>(extraBufferCapacity = 1)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        lifecycleScope.launch {
            engine.settings.screenAlwaysOn.flow.collect { keepOn ->
                if (keepOn) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        }

        setContent {
            DualCamTheme {
                AppRoot(engine, shutterEvents)
            }
        }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        val isVolume = keyCode == KeyEvent.KEYCODE_VOLUME_UP ||
            keyCode == KeyEvent.KEYCODE_VOLUME_DOWN
        if (isVolume && engine.settings.volumeShutter.value) {
            shutterEvents.tryEmit(Unit)
            return true
        }
        return super.onKeyDown(keyCode, event)
    }
}

@Composable
private fun AppRoot(engine: DualCamEngine, shutterEvents: MutableSharedFlow<Unit>) {
    val context = LocalContext.current
    val settings = engine.settings
    val hasSeenWelcome by settings.hasSeenWelcome.flow.collectAsState()
    var screen by remember { mutableStateOf(Screen.CAMERA) }

    var cameraGranted by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED &&
                ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED
        )
    }
    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { result ->
        cameraGranted = result[Manifest.permission.CAMERA] == true &&
            result[Manifest.permission.RECORD_AUDIO] == true
    }

    fun requestPermissions() {
        permissionLauncher.launch(
            arrayOf(
                Manifest.permission.CAMERA,
                Manifest.permission.RECORD_AUDIO,
                Manifest.permission.POST_NOTIFICATIONS,
            )
        )
    }

    when {
        !hasSeenWelcome -> WelcomeScreen(
            onContinue = {
                settings.hasSeenWelcome.value = true
                if (!cameraGranted) requestPermissions()
            }
        )

        !cameraGranted -> PermissionGate(onRequest = ::requestPermissions)

        else -> {
            // Run the camera session only while the app is in the foreground
            // and the camera screen is showing.
            val lifecycleOwner = LocalLifecycleOwner.current
            DisposableEffect(lifecycleOwner, screen) {
                val observer = LifecycleEventObserver { _, event ->
                    when (event) {
                        Lifecycle.Event.ON_START -> if (screen == Screen.CAMERA) engine.startSession()
                        Lifecycle.Event.ON_STOP -> engine.stopSession()
                        else -> {}
                    }
                }
                if (screen == Screen.CAMERA &&
                    lifecycleOwner.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)
                ) {
                    engine.startSession()
                }
                lifecycleOwner.lifecycle.addObserver(observer)
                onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
            }

            when (screen) {
                Screen.CAMERA -> CameraScreen(
                    engine = engine,
                    shutterEvents = shutterEvents,
                    onOpenSettings = { screen = Screen.SETTINGS },
                    onOpenGallery = { screen = Screen.GALLERY },
                )

                Screen.SETTINGS -> {
                    BackHandler { screen = Screen.CAMERA }
                    SettingsScreen(engine = engine, onBack = { screen = Screen.CAMERA })
                }

                Screen.GALLERY -> {
                    BackHandler { screen = Screen.CAMERA }
                    GalleryScreen(engine = engine, onBack = { screen = Screen.CAMERA })
                }
            }
        }
    }
}

@Composable
private fun PermissionGate(onRequest: () -> Unit) {
    Surface(modifier = Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(32.dp),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text("Camera & Microphone", style = MaterialTheme.typography.headlineSmall)
            Text(
                "dualCam records both cameras and the mic at the same time. " +
                    "Grant access to start capturing.",
                style = MaterialTheme.typography.bodyMedium,
                textAlign = TextAlign.Center,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 12.dp, bottom = 24.dp),
            )
            Button(onClick = onRequest) { Text("Grant access") }
        }
    }
}
