package com.sigmadrive.dualcam.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

private val Gold = Color(0xFFFFD60A)

// A camera app lives in the dark — one tuned dark scheme, like the iOS app.
private val DarkScheme = darkColorScheme(
    primary = Gold,
    onPrimary = Color(0xFF1A1400),
    primaryContainer = Color(0xFF3D3200),
    onPrimaryContainer = Color(0xFFFFE45C),
    secondary = Color(0xFFCCC6B4),
    onSecondary = Color(0xFF32302A),
    surface = Color(0xFF121212),
    onSurface = Color(0xFFE6E1D9),
    surfaceVariant = Color(0xFF1E1E1E),
    onSurfaceVariant = Color(0xFFB0ABA0),
    surfaceContainer = Color(0xFF1A1A1A),
    surfaceContainerHigh = Color(0xFF222222),
    background = Color(0xFF0B0B0B),
    onBackground = Color(0xFFE6E1D9),
    outline = Color(0xFF4A4A4A),
    error = Color(0xFFFFB4AB),
)

@Composable
fun DualCamTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = DarkScheme, content = content)
}
