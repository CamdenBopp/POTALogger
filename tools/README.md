# Tools

## Framing screenshots

`frame-screenshots.swift` puts raw simulator captures into an iPhone frame for the README.

### One-time setup: get the bezel

Apple's device bezels can't be redistributed, so the repo doesn't include one. Get your own copy:

1. Download **iPhone 17** under Product Bezels at [Apple Design Resources](https://developer.apple.com/design/resources/#product-bezels).
2. Open the disk image and accept Apple's license.
3. Copy `PNG/iPhone 17 Pro/iPhone 17 Pro - Deep Blue - Portrait.png` into `tools/bezels/`. That folder is gitignored.

### Capturing and framing

1. Run the app on an **iPhone 17 Pro** simulator. The capture size has to match the bezel's screen, and the script stops with an error if it doesn't.
2. Optionally, clean up the status bar first:
   ```bash
   xcrun simctl status_bar booted override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
   ```
3. Save each screen into `docs/screenshots/raw/`:
   ```bash
   xcrun simctl io booted screenshot docs/screenshots/raw/spots.png
   ```
4. From the repo root, frame everything:
   ```bash
   swift tools/frame-screenshots.swift
   ```

Framed images are written to `docs/screenshots/` with the same file names. To use a different bezel, pass its path as the first argument. The script finds the screen opening by itself, so any portrait bezel works as long as its screen matches your capture size.
