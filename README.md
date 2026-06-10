# dualCam: iOS Dual-Camera Capture

Quick story: 
I recently went to a graduation and everyone had the iPhone 17 and was enjoying the dual capture feature, I thought to myself "this doesnt need to be gatekept to just the 17" so i built my own version that runs on any device that supports iOS 18 and beyond using claude and my swift brainpower. #suckit apple

This is an open-source iOS camera application that captures simultaneous video feeds from multiple cameras (front/rear or multiple rear cameras), offering real-time custom layouts and optional raw feed storage.

> **Android user?** There's a native Android version too — Kotlin, Jetpack Compose, and the Camera2 concurrent-camera API, with the same features. See [`android/README.md`](android/README.md) for the (free, no-account-needed) build instructions.

## How It's Built

The application is engineered using native Apple frameworks, divided into three core subsystems:

### 1. The Multi-Camera Session (AVFoundation)
At the heart of the app is **`AVCaptureMultiCamSession`**. Unlike standard single-camera captures, a multi-cam session coordinates hardware resources to run two independent camera inputs concurrently:
* **Hardware Selection**: Automatically resolves combinations of Wide, Ultra-Wide, and Telephoto physical lenses based on device capability.
* **Dual Input Ports**: Binds both the front TrueDepth camera and the selected rear camera system as active input sources.
* **Data Processing**: Connects independent `AVCaptureVideoDataOutput` streams to receive uncompressed, high-frequency CMSampleBuffers from both cameras simultaneously.

### 2. The Real-Time Merging Engine (Core Image)
Rather than simple layer overlays, dualCam processes video feeds frame-by-frame on the GPU using **Core Image**:
* **Thread-Safe Synchronization**: Employs a custom locking queue to ingest frame buffers from both outputs concurrently.
* **Layout Geometry Math**: Dynamically translates UIKit coordinate space coordinates (used for dragging and scaling the PiP frame) into Y-up Core Image pixel coordinates.
* **Custom Compositing Filters**: Applies `CIImage` cropping, masking, and borders (using circular or rounded-rect paths) to shape the secondary feed and merges it onto the primary background feed seamlessly.
* **AVAssetWriter Pipeline**: Feeds the merged frames and the device's microphone audio track into a hardware-accelerated H.264/HEVC writer for instant, lightweight compilation.

### 3. State Management & Modern Frontend (SwiftUI)
* **AppStorage Synchronization**: All layouts, qualities, and options are stored via persistent `@AppStorage` wrappers.
* **Thread-Safe Observers**: View adjustments trigger explicit, reactive `.onChange(of:)` synchronization blocks that configure live camera parameters on background queues without interrupting preview layers.

---

## Features
*   **Dual Camera Support**: Capture Front + Back, Ultra-wide + Front, Wide + Telephoto, and more combinations simultaneously.
*   **PiP & Spotlight Layouts**: Draggable, resizable picture-in-picture frame or a 65/35 split spotlight view.
*   **Customizable PiP**: Circular or rounded-rectangle frame with multiple border styles and colours.
*   **Flexible Export**: Save directly to Photos or pick any Files destination (iCloud Drive, local folders, third-party providers).
*   **Auto-Save Raw Feeds**: Optional automatic saving of individual source video tracks alongside the merged output.
*   **Gestures & Interactions**: Tap-to-focus, pinch-to-zoom, and pinch-to-resize the PiP window.

---

## How to Sideload & Build to Your iPhone (100% Free)

Since `dualCam` is open source, **you do not need a paid Apple Developer Account ($99/year) to run this on your own device.** You can compile and deploy it onto your iPhone using a standard, free Apple ID.

### Prerequisites
*   A **Mac** running macOS Sonoma or later.
*   **Xcode 15** or later installed (available free in the Mac App Store).
*   A USB-C or Lightning cable to connect your iPhone to your Mac.

---

### Step-by-Step Instructions

#### 1. Clone or Download the Code
*   Clone this repository to your Mac, or click **Code > Download ZIP** and extract the archive.

#### 2. Open in Xcode
*   Navigate into the project folder.
*   Double-click the **`dualCam.xcodeproj`** file to open it in Xcode.

#### 3. Connect Your iPhone & Select as Target
*   Connect your physical iPhone to your Mac using your cable.
*   If prompted on your iPhone, tap **Trust This Computer** and enter your passcode.
*   In the top bar of Xcode, click the active target dropdown (next to the Play button) and select your **physical iPhone** (do not select a simulator, as multi-camera APIs require physical hardware).

#### 4. Configure Your Free Apple ID Signing
Apple requires all apps installed on physical devices to be signed.
1. In the left-hand Xcode navigator, click the topmost blue folder icon named **`dualCam`** to open the project settings.
2. In the main editor panel, select the **`dualCam`** target under the Targets list.
3. Click the **Signing & Capabilities** tab in the top center menu.
4. Check the box for **"Automatically manage signing"** if it isn't already.
5. In the **Team** dropdown, select your name (it will say **"Your Name (Personal Team)"**). If you don't see it:
   *   Click *Add an Account...* and sign in with your normal Apple ID.
   *   Once signed in, select your Personal Team.
6. **Important**: Change the **Bundle Identifier** to something unique to you (for example, change `com.sigmadrive.dualCam` to `com.yourname.dualCam`). Apple's free developer certificates require a unique bundle ID that isn't already registered by another user.

#### 5. Enable Developer Mode on Your iPhone 
If you haven't enabled developer mode on your phone before:
1. On your iPhone, open **Settings -> Privacy & Security**.
2. Scroll to the very bottom and tap **Developer Mode**.
3. Toggle the switch **On** and follow the prompts to restart your device.
4. After restarting and unlocking your device, tap **Turn On** and enter your passcode to confirm.

#### 6. Build and Run!
*   In Xcode, click the **Play (▶) button** in the top-left corner (or press `⌘R`).
*   Xcode will compile the code and sideload the application onto your connected iPhone.

#### 7. Trust Your Personal Developer Certificate
The first time you build the app using your free account, your iPhone will show an "Untrusted Developer" alert and won't launch the app yet. To fix this:
1. On your iPhone, open **Settings -> General -> VPN & Device Management**.
2. Under "Developer App", tap on your **Apple ID / email address**.
3. Tap **Trust [Your Email Address]** and confirm.
4. **Go back to your Home Screen and launch `dualCam`!**

---

## Hardware Compatibility & Requirements
Because concurrent multi-camera recording requires immense hardware processing pipelines, iOS limits `AVCaptureMultiCamSession` support to modern hardware:
*   **Requires iOS 18.0 or newer**.
*   **Supported Devices**: iPhone XS, iPhone XR, iPhone 11, iPhone 12, iPhone 13, iPhone 14, iPhone 15, iPhone 16, and all newer models (Pro/Max/Mini variations fully supported).

---

## License
This project is source-available under the **dualCam Community License v1.0** (which grants open-source-equivalent rights to individuals and small organizations while requiring custom licensing for large enterprise distribution). 

See the [LICENSE](LICENSE) file for complete details.
