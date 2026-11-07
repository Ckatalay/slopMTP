# slopMTP

A native macOS MTP client, written in Swift and SwiftUI, for browsing and transferring files to and from a homebrew-enabled Nintendo Switch running an MTP responder such as **DBI** or **Sphaira**.

> **Legal use only.** slopMTP is a general-purpose file transfer tool meant for backing up your own saves, screenshots and game dumps, homebrew development and game preservation. It does not include, download or circumvent anything. Don't use it for piracy.

## Features

- Detects MTP devices automatically and connects to a Switch as soon as it's plugged in
- Browses every storage the responder exposes (SD card, NAND partitions, DBI's virtual folders), with free space shown
- Downloads and uploads files and whole folders, with a transfer queue showing progress, speed and time remaining
- Handles files over 4 GiB (64-bit `ObjectSize`, `SendObjectPropList` when the responder supports it, unknown-length data phases)
- New folder, rename, delete, drag and drop to and from Finder
- For DBI: a game library with cover art, install review (base → update → DLC), backups of games and saves, uninstalling, and an Album gallery with thumbnails
- Live refresh from device events, fast listings via `GetObjectPropList`, and downloads that resume where they stopped (`GetPartialObject64`)
- No dependencies: talks to USB directly through Apple's `IOUSBHost` framework (no libusb, no libmtp)

## Requirements

- macOS 14 Sonoma or later, Apple silicon or Intel
- Xcode 16 or later to build
- A Switch running an MTP responder: DBI ("Run MTP responder") or Sphaira (MTP enabled in settings)

## Install

```sh
brew install --cask ckatalay/tap/slopmtp
```

Or download the notarized app from [Releases](https://github.com/Ckatalay/slopMTP/releases).

## Building

```sh
open SlopMTP.xcodeproj        # then Run (⌘R)
```

or from the command line:

```sh
xcodebuild -project SlopMTP.xcodeproj -scheme SlopMTP -configuration Release build
```

The Xcode project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`. After adding or removing files run `xcodegen generate`.

Protocol tests run without hardware:

```sh
cd Packages/MTPKit && swift test
```

To check a real device from the terminal (prints device info, storages and root listings):

```sh
cd Packages/MTPKit && swift run mtp-probe
swift run mtp-probe --download <handle> <local path>
```

## Usage

1. Start the MTP responder on the Switch.
2. Connect it with a USB-C cable (a data cable, not a charge-only one).
3. slopMTP connects automatically. Pick a storage in the sidebar and browse.

### Troubleshooting

**"The device's MTP interface is in use."** macOS's camera daemon (`ptpcamerad`) claims every PTP/MTP device the moment it's plugged in. slopMTP takes the interface over automatically: it asks the owner to let go and, if the owner is `ptpcamerad`, stops it (it's a per-user launch agent that macOS restarts on demand) and opens the device before it comes back. If another app such as OpenMTP or Android File Transfer holds the device, the error names it; quit that app and reconnect.

**The device doesn't show up.** Make sure the responder is running on the Switch *before* or right after plugging in, and try a different cable or port. USB hubs sometimes cause trouble.

## Architecture

```
App/SlopMTP/              SwiftUI app (models + views)
Packages/MTPKit/          Reusable protocol library
  PTP/                    Codes, container framing, dataset encoding/decoding
  Transport/              MTPTransport protocol, IOUSBHost USB transport, device watcher
  Session/                MTPSession actor: transaction engine and file operations
  Tests/                  Unit tests, including a packet-level mock MTP responder
```

`MTPSession` is an actor that runs on its own serial dispatch queue, so blocking USB I/O never blocks Swift's cooperative thread pool. Data phases are streamed in 1 MiB bulk transfers, with correct zero-length-packet handling at packet boundaries.

## License

MIT. See [LICENSE](LICENSE).
