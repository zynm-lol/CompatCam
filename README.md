# CompatCam

A native iOS camera app built around one core idea: **never assume a single
camera configuration works.** It automatically discovers and tries multiple
`AVCaptureSession` configurations until it finds one that produces a stable,
running session on your hardware — useful for cameras that behave oddly with
Apple's own Camera app but work fine in other apps (which usually points to
a specific session preset / format / device-type combination the stock app
doesn't try).

Everything here uses **only public Apple frameworks** (AVFoundation, Core
Image, Metal, Photos, SwiftUI, Combine). No private APIs, no Instagram code,
no reverse engineering — as requested.

## What's implemented (real, working code)

- **`CameraCompatibilityEngine`** — the heart of the app. Builds an ordered
  list of `CameraConfiguration` candidates per profile (A–F) and mode
  (Standard / Compatibility / Maximum Compatibility / Experimental / Low-Res
  Safe / Manual), and walks them until one succeeds.
- **`CameraManager`** — actor-safe wrapper around `AVCaptureSession`. Device
  discovery, input/output wiring, format selection strategies (highest/lowest
  resolution, closest-to, must-support-fps), stabilization/focus/exposure/
  white-balance application, zoom, torch, tap-to-focus, manual ISO/shutter
  (`setExposureModeCustom`), and lazy video-recording wiring (mic input +
  `AVCaptureMovieFileOutput`).
- **Automatic Recovery** — listens for `AVCaptureSessionRuntimeError` /
  interruption notifications and calls back into the engine to find a new
  working configuration live, without crashing or requiring app restart.
- **`CameraDiagnosticsService`** — enumerates all discoverable built-in
  devices and their formats/frame-rate ranges/pixel formats using
  `AVCaptureDevice.DiscoverySession`, for the Diagnostics screen.
- **`DiagnosticsLogger`** — actor-based logger feeding a live SwiftUI log view.
- **`FilterEngine`** — 12 realtime Core Image filters (Natural, Film, Vintage,
  Warm, Cool, Noir, Dream, Soft, Classic, Vivid, Cinematic, B&W), rendered
  through a Metal-backed `CIContext`.
- **`FrameAnalysisCoordinator`** — live luminance histogram, focus-peaking
  overlay (edge detection), and zebra-stripe overexposure overlay, all
  computed from `AVCaptureVideoDataOutput` sample buffers, throttled to
  every 6th frame so analysis never competes with preview smoothness.
- **`PhotoCaptureCoordinator`** — async/await bridge for
  `AVCapturePhotoCaptureDelegate`. Supports standard JPEG/HEIF capture,
  RAW capture (`availableRawPhotoPixelFormatTypes`) with a processed sibling,
  and burst capture (long-press the shutter). Saves to Photos via
  `PHAssetCreationRequest`.
- **`VideoRecordingCoordinator`** — async/await bridge for
  `AVCaptureFileOutputRecordingDelegate`; records to a temp file, tracks
  elapsed time, saves the finished movie to Photos.
- **SwiftUI screens**: Capture screen (Photo/Video/Manual mode switcher,
  preview + controls + filter strip + live histogram + focus-peaking/zebra
  overlays + countdown timer + startup/recovery/error overlays), Camera
  Compatibility menu, Diagnostics screen, Manual Configuration screen
  (device/format/stabilization/exposure/WB/HDR/RAW/burst/manual ISO-shutter),
  Gallery (PhotoKit-backed).

## What was intentionally removed, and why

You asked me to cut anything I judged wasn't earning its place. Rather than
build every line item in the original spec regardless of fit, here's what
came out and the reasoning — happy to reverse any of these if you disagree:

- **"Debug Mode"** as a separate Compatibility Mode. It only ever duplicated
  Maximum Compatibility's full A–F ladder, and its one distinguishing idea —
  seeing every device on both camera positions — is already covered by the
  Diagnostics screen, which lists every device regardless of active mode.
- **Continuity Camera / External device types** from the Experimental profile
  and from Diagnostics discovery. Those device types exist for Mac/iPad
  accessory-camera scenarios (a webcam plugged into an iPad, or an iPhone
  used as a Mac's webcam) and are never returned when discovering an
  iPhone's own built-in cameras — they were dead weight that could never
  produce a match on this app's actual target hardware.
  Experimental mode now tries a locked-exposure/focus/WB configuration and
  an unspecified-position discovery instead, both of which can plausibly
  help with a marginal sensor.
- **Portrait Mode and a separate "Professional" swipe mode.** Portrait would
  require virtual-camera depth capture plus person-segmentation compositing
  — a large, separate subsystem disproportionate to this app's actual goal
  (getting a marginal rear camera to produce a stable stream at all).
  "Professional" wasn't a distinct capture pipeline in the spec to begin
  with, just another label for manual controls, which already exist as
  their own mode — a second entry point to the same screen added nothing.
- **The placeholder HDR toolbar icon** from the first draft (it didn't do
  anything — a stand-in glyph). HDR is a real, working toggle in Manual
  Configuration; the toolbar space went to a real Histogram toggle and a
  Focus Peaking / Zebra overlay menu instead.

## What's still scaffolded for a follow-up pass rather than fully built

- **ProRes / Apple Log** encoding presets (these need device-specific format
  capability checks plus `AVCaptureDevice.Format.supportedColorSpaces` /
  `isAppleProResSupported`, wired into the video pipeline's output settings).
- **Focus/exposure locking UI affordances** beyond tap-to-focus (e.g. a
  press-and-hold "AE/AF Lock" badge) — the underlying device calls already
  exist in `CameraManager.focus(at:)`, this is purely a UI addition.
- Unit tests for `CameraCompatibilityEngine.buildCandidates` (pure, easily
  testable — no device access required — good first thing to add).

Tell me which of these you want built out next and I'll extend the same
architecture rather than start over.

## Building this project

This delivery is Swift source files, not a binary `.xcodeproj` (Xcode project
files are fragile to hand-generate and easy to corrupt). Two ways to turn it
into a real Xcode project in under a minute:

**Option A — XcodeGen (recommended)**
```bash
brew install xcodegen
cd CompatCam
xcodegen generate
open CompatCam.xcodeproj
```
`project.yml` is already included and configured for iOS 17, Swift 6.

**Option B — Manual**
1. Create a new Xcode project: iOS App, SwiftUI, Swift.
2. Delete the generated `ContentView.swift`/`App.swift`.
3. Drag the `CompatCam/CompatCam` folder (App, Models, Engine, Managers,
   ViewModels, Views, Filters, Utilities) into your project, "Create groups",
   target membership checked.
4. Replace your target's `Info.plist` with `Resources/Info.plist` (or merge
   the usage-description keys into your existing one).
5. Set deployment target to iOS 17.0, Swift Language Version to 6.
6. Build on a physical device (camera APIs don't run in Simulator).

## Notes

- Run on a **physical device** — the Simulator has no real camera hardware,
  so the compatibility engine has nothing to discover there.
- The camera's Unique Device ID is displayed in Diagnostics only; nothing is
  ever transmitted anywhere. The whole app has no networking code at all.
