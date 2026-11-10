# Simpla Recorder

A tiny menu-bar screen recorder for macOS 15+.
Records a whole screen, a single window or a selected area — with system audio and/or microphone — to MP4 or MOV (H.264 / HEVC).

## Usage

The menu-bar icon has four items: **Record Screen**, **Settings…**, **Open Recordings Folder** and **Quit**.

1. **Record Screen** dims the screens. Click a window to pick it, press **Entire Screen**, or drag to select an area
   (a dragged area can then be resized by its borders and moved by dragging the panel).
2. A small panel lets you turn the microphone and system audio on or off for this recording, then start it.
3. While recording, the menu-bar item becomes a red stop button with the elapsed time.
   Click it to stop; the file is revealed in Finder.

## Build

Only the Command Line Tools are required (no Xcode).

```sh
./build.sh        # build and sign ~/Applications/Simpla Recorder.app
./build.sh run    # build and launch
```

Build products go to `~/Library/Caches/SimplaRecorder-build`, not the project folder.
Signing uses `CODESIGN_IDENTITY`, else the first code-signing certificate in the keychain, else ad-hoc.

## Permissions

On the first recording macOS asks for access: System Settings → Privacy & Security → Screen & System Audio Recording.
The microphone is requested separately. With ad-hoc signing you may have to grant access again after each rebuild.

## Settings

**Settings…**: format, codec, frame rate, default microphone / system audio, and the output folder
(default `~/Movies/Simpla Recorder`). Stored in `UserDefaults` (`com.simpla.recorder`).
Recordings are named `Screen Recording yyyy-MM-dd HH.mm.ss`.
