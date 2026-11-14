# iShot for Linux

Panel screenshot tool: capture a region, the window in front or the whole screen, annotate it,
copy/save/pin/share it, recognize its text (OCR) and record the screen.

It adapts to the desktop it runs on:

| | X11 (XFCE, KDE/GNOME on Xorg) | KDE Plasma (Wayland) | GNOME (Wayland) |
|---|---|---|---|
| Capture | direct | portal | portal |
| Snap to the window in front | yes | no | no |
| Global shortcuts | direct | portal | portal (GNOME 48+) or custom keybindings |
| Recording | ffmpeg | portal + GStreamer | portal + GStreamer |
| Panel icon | yes | yes | with the AppIndicator extension |

*Settings › Available on this system* shows what is active on your desktop.

## Text recognition (OCR)

iShot recognizes text with the **RapidOCR / PaddleOCR PP-OCRv6 "small"** models, bundled in the
package (`/usr/share/ishot/ocr`, Apache-2.0) and run on the CPU with ONNX Runtime. If the models are
missing it falls back to Tesseract (`sudo apt install tesseract-ocr tesseract-ocr-ita`).

Measured on screenshots (Italian text, terminal font, app UI, white text on coloured buttons),
both engines on the image enlarged ×2:

| Engine | Words exactly right | Character errors | Time per capture |
|---|---|---|---|
| Tesseract 5 | 84.7% | 16.3% | ~0.3 s |
| **RapidOCR PP-OCRv6 small (iShot)** | **91.0%** | **4.1%** | ~0.8 s |

Tesseract missed white text on coloured buttons entirely and read `1.248` as `1,248` in the terminal.

`ishot --ocr-file IMAGE` prints the text found in an image (diagnostics).

## Install

Download `ishot_<version>_amd64.deb` from the [releases](https://github.com/Abi0ne/iShot/releases):

```sh
sudo apt install ./ishot_*_amd64.deb
```

Recommended packages (installed automatically by apt unless disabled): `ffmpeg` (recording on X11),
`gstreamer1.0-pipewire` and friends (recording on Wayland). OCR needs nothing extra.

## Command line

`ishot --region | --fullscreen | --record | --ocr-last | --settings | --quit`, forwarded to the
running instance. Bind them to keys in your desktop settings if global shortcuts are unavailable.

## Build

```sh
sudo apt install build-essential pkg-config libgtk-4-dev
./fetch-models.sh              # OCR models → models/ (checked with SHA-256)
cargo build --release          # binary: target/release/ishot (ONNX Runtime linked in)
cargo install cargo-deb && cargo deb   # package: target/debian/ishot_*.deb
```

Release packages are built for Debian 13 by `.github/workflows/linux-deb.yml`.
