# iShot

A native Swift (AppKit) macOS menu-bar screenshot app. It captures regions or the full screen, lets you
annotate the shot, and can save, copy, pin, share, run OCR and record the screen. It's a clone of
*iScreen Shoter*. See [ARCHITECTURE.md](ARCHITECTURE.md) for the design.

## Build

Requirements: macOS 14+, Swift 5.9+ and the Command Line Tools. Xcode is **not** required.

```sh
cd /Users/gmanc/Work/iShot
scripts/create-signing-cert.sh   # once: creates the "iShot Local Signing" certificate
scripts/build-app.sh --install   # build, sign, copy to /Applications and launch
```

The script:
1. finds a usable Command Line Tools SDK (the newest one where SwiftUI's `State` is not a macro),
   unless `ISHOT_SDK` is set or Xcode is selected;
2. runs `swift build --package-path app -c release --product iShot`;
3. packages the binary into `build/iShot.app` with an `Info.plist` (`com.local.ishot`, `LSUIElement`);
4. signs the app with the "iShot Local Signing" certificate (ad-hoc, with a warning, if it is missing)
   and checks the signature with `codesign --verify`;
5. with `--install`, quits the running copy, installs it in `/Applications/iShot.app` and launches it.

To sign with another identity, set `ISHOT_SIGN_IDENTITY="Developer ID Application: …"`.

## Run

```sh
open /Applications/iShot.app
```

iShot has no Dock icon. Look for the viewfinder icon in the menu bar.

## Features

- **Capture Region**: a dimmed overlay covers every screen. Drag to select an area; a label shows the size in pixels while you drag.
  Press Esc or right-click to cancel. The default global shortcut is **⌥⇧A** (you can change it in Settings).
- **Capture Fullscreen**: captures the display under the mouse pointer.
- **Editor tools**: select/move, pen (smoothed), rectangle, ellipse, line, arrow, text and mosaic (pixelation).
  - Hold ⇧ while dragging to draw squares or circles, or to snap lines to 45°.
  - There are 8 preset colors plus a custom color well, and 6 line widths (the width also sets the text size).
  - Use Undo (⌘Z) or Clear to remove changes. With the select tool, ⌫ deletes the selected annotation and a double-click edits text.
- **Actions**: Save (↩ / ⌘S), Copy (⌘C), Pin (⌘P), OCR, Share, Cancel (Esc).
- **Pin**: shows the image in a borderless window that stays on top. Drag it to move it, scroll to zoom,
  and double-click or press Esc to close it.
- **OCR**: Vision recognizes the text on the device. You can run it from the editor or with *OCR Last Screenshot*.
- **Record Screen**: ScreenCaptureKit records the display under the pointer to `.mov` (H.264, 30 fps).
  Choose *Stop Recording* to finish; the file then appears in Finder.
- **Settings**: save folder (default `~/Pictures/Screenshots`), format (PNG/JPG), file name prefix
  (files are named `prefix_YYYYMMDD_HHMMSS.ext`), global shortcut recorder and launch at login.

## Screen Recording permission

macOS requires the **Screen Recording** permission before an app can read screen pixels or record the screen.

- The first time you capture, iShot asks for the permission. Allow it in
  **System Settings › Privacy & Security › Screen & System Audio Recording**, then **relaunch iShot**.
- Without the permission, iShot keeps working: you get an alert with a button that opens the right
  settings pane.
- macOS ties the permission to the app's code signature. An ad-hoc signature is just the hash of the
  binary, so it changes on every rebuild and the permission is lost (the switch stays on in System Settings
  but no longer applies). That is why the build signs with a fixed local certificate
  (`scripts/create-signing-cert.sh`): the identity stays `com.local.ishot` + that certificate across rebuilds.
- If the permission seems stuck (e.g. after switching from ad-hoc builds), run
  `tccutil reset ScreenCapture com.local.ishot`, relaunch iShot and allow it again.
- Screenshots use ScreenCaptureKit (`SCScreenshotManager`), not the deprecated `CGDisplayCreateImage`,
  which makes recent macOS versions re-ask for the permission periodically.
- *Launch at login* uses `SMAppService`. It works best when `iShot.app` is in `/Applications`.

## Layout

```
app/Package.swift              SwiftPM package (executable target "iShot", macOS 14+)
app/Sources/iShot/             main, AppDelegate, StatusMenu
  Capture/                     ScreenCapture, RegionOverlay
  Editor/                      Annotation, Tools, EditorView, EditorWindow
  OCR/                         OCRService (+ result window)
  Recording/                   ScreenRecorder (ScreenCaptureKit)
  Settings/                    SettingsStore, SettingsWindow
  Shortcut/                    GlobalShortcut (Carbon hotkey)
  Support/                     Exporter, PinWindow
scripts/build-app.sh           build + bundle + sign (+ --install)
scripts/create-signing-cert.sh one-time local code-signing certificate
```
