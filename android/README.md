# dualCam for Android

Simultaneous front + back (and multi-lens) video capture with the same PiP and Spotlight layouts as the iOS app — built natively with Kotlin, Jetpack Compose, and Material 3.

## How It's Built

| Subsystem | iOS | Android |
|---|---|---|
| Dual camera session | `AVCaptureMultiCamSession` | Camera2 concurrent streaming |
| Real-time merge engine | Core Image compositing | OpenGL ES compositor (`render/`) — GPU textures merged with an SDF shader for the PiP mask, borders, and glow |
| Recording | `AVAssetWriter` | `MediaRecorder` in surface-input mode, fed by the GL compositor (H.264 / HEVC) |
| UI & state | SwiftUI + `@AppStorage` | Jetpack Compose + SharedPreferences-backed StateFlows |

## Feature parity

PiP and Spotlight layouts, draggable/resizable PiP (circle or rounded-rect, all 8 frame styles/colors), spotlight split ratios and gaps, 4K/1080p/720p quality, H.264/HEVC, capture timer, delayed dual capture, tap-to-focus, pinch-to-zoom, double-tap to swap, grid overlay, volume-button shutter, auto-save raw feeds, save to gallery or any folder (SAF), session gallery with share/export, recording limits, storage warnings, and save notifications.

Platform notes:
- **Live Activity** → an ongoing notification with a chronometer while recording.
- **Camera pairs** beyond Front + Back depend on the phone's hardware; unsupported pairs appear greyed out in Settings.
- **Flash** acts as a torch, since both cameras stream continuously.

## Requirements

- Android 11 (API 30) or newer.
- A phone whose camera hardware supports concurrent streaming (the app tells you on launch if yours doesn't).

## Download

Grab the latest `dualCam-android.apk` from the [Releases page](../../releases), open it on your phone, and allow "Install unknown apps" when prompted.

## How to Build & Install

No developer account needed — build the APK and install it on your own phone.

1. Install [Android Studio](https://developer.android.com/studio).
2. Open this **`android`** folder as the project and let it sync.
3. On your phone: **Settings → About phone**, tap **Build number** 7×, then enable **USB debugging** under **Developer options**.
4. Plug in your phone, accept the debugging prompt, and press **Run ▶**.

> To share with friends without them building it: **Build → Generate Signed App Bundle / APK → APK**, then send the APK — they'll need to allow "Install unknown apps".

## Project layout

```
app/src/main/java/com/sigmadrive/dualcam/
├── model/Models.kt              # Layouts, shapes, styles, pairs — mirrors the iOS enums
├── settings/AppSettings.kt      # SharedPreferences + StateFlow (the @AppStorage equivalent)
├── camera/DualCameraController  # Camera2: lens discovery, concurrent pairs, focus/zoom/torch
├── camera/DualCamEngine         # The CaptureManager: session, recording, saving, state
├── render/EglCore               # EGL14 context shared by preview, encoders, photo readback
├── render/CompositorRenderer    # GLES2 shader: aspect-fill, PiP mask, border styles
├── render/RenderPipeline        # GL thread: camera frames → screen + recorder + photos
├── capture/RecordingSession     # MediaRecorder in surface mode (composite + raw feeds)
├── capture/MediaSaver           # MediaStore, SAF export, notifications, temp cleanup
└── ui/                          # Compose screens: camera, settings, gallery, welcome
```
