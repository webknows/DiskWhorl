# DiskWhorl

A native macOS disk-space analyzer. It scans a disk or folder, draws the result as an interactive sunburst map, and lets you stage large or unwanted items in a Collector before moving them to the Trash. It never cleans anything on its own.

Built with SwiftUI and AppKit. No third-party dependencies, no network access, no telemetry.

## Requirements

| | |
|---|---|
| macOS | 14 Sonoma or later |
| Mac | Apple silicon or Intel |
| Toolchain | Swift 5.9 or later: Xcode 15 or later, **or** only the Command Line Tools |

## Build

1. Install the build tools if they are not already present. Xcode from the App Store works, and so does the smaller Command Line Tools package:
   ```sh
   xcode-select --install
   ```
2. Get the source and build the app bundle:
   ```sh
   git clone https://github.com/<owner>/DiskWhorl.git
   cd DiskWhorl
   zsh Scripts/build-app.sh             # creates build/DiskWhorl.app for this Mac
   zsh Scripts/build-app.sh --install   # also copies it to ~/Applications
   ```
   Or double-click **Build DiskWhorl.command** in Finder. It builds, installs to `~/Applications`, and writes the compiler output to `build/build.log`.

   Options and settings:
   - `--universal` builds one app for both Apple silicon and Intel. This needs full Xcode.
   - `BUNDLE_ID=com.example.DiskWhorl zsh Scripts/build-app.sh` sets your own bundle identifier.
   - `VERSION=1.1 zsh Scripts/build-app.sh` sets the version number.

   The project deliberately avoids SwiftUI's `@State`. In recent macOS SDKs `@State` is a macro whose compiler plugin ships only with Xcode, and avoiding it keeps the build working with the Command Line Tools alone.
3. Open the app. An app you build yourself is not quarantined, so it opens normally. If you received a pre-built copy from someone else and macOS blocks it, open System Settings › Privacy & Security and click **Open Anyway**. Since macOS 15, right-click › Open no longer bypasses this check.
4. Grant Full Disk Access: System Settings › Privacy & Security › Full Disk Access › add DiskWhorl, then relaunch it. Without it, macOS hides Mail, Messages, Safari and other app data, and those bytes appear as hidden space.

   The build is signed ad hoc, and that signature changes with every build, so macOS treats each rebuild as a new app. Grant Full Disk Access again after rebuilding.

To work on the code, open `Package.swift` in Xcode and run the `DiskWhorl` scheme. A copy run from Xcode is not inside an app bundle, so administrator scans and the Dock icon work best from the built `.app`.

## Using it

| Action | How |
|---|---|
| Scan a disk | Click ▶ next to it in the sidebar, or select it and press **Scan** |
| Scan every local disk at once | Toolbar › **Scan All Local Disks** (⇧⌘A) |
| Scan any folder | Toolbar › **Scan Folder…** (⌘O) |
| Open a folder | Click its arc, or its row in the contents list |
| Go up | Click the centre circle, the back chevron, a breadcrumb, or press ⌘↑ / Esc |
| Inspect | Hover an arc: name, size, share and absolute path appear in the tooltip and the sidebar |
| Quick Look | Space bar (hovered or selected item), or double-click a file |
| Reveal in Finder | ⌘R or the context menu |
| Collect for deletion | Drag an arc or a row onto the Collector, press ⌘⌫, or use the context menu |
| Delete | Collector › **Delete…** › review › **Move to Trash**, then a countdown with **Undo** (⌘Z) |
| Hidden space, snapshots, purgeable | Click the dark-gray or lavender arc, or **Hidden Space** (⇧⌘H) |
| Administrator scan | Toolbar lock toggle, or right-click a disk › **Scan as Administrator** |

### Colour legend

- **Folders:** hue follows angular position, so a branch keeps one colour family from the centre outward; deeper rings are lighter.
- **Files:** gray.
- **Smaller items:** light gray arc that groups entries too thin to draw.
- **Hidden space:** dark gray. Used space that no readable file accounts for.
- **Purgeable space:** lavender. Space macOS can reclaim automatically.

## How it works

**Scanning.** `BulkScanner` walks directories with `getattrlistbulk(2)`, which returns names, types, inode numbers, flags and allocated sizes for a whole batch of entries per system call. A pool of worker threads, sized to the medium (more for internal NVMe flash, fewer for USB, network and FUSE), pulls folders from a shared work stack. Contents are never opened. If a file system does not support the call, the scanner falls back to `readdir` + `fstatat`.

**Physical size.** Arcs use allocated bytes (`ATTR_FILE_ALLOCSIZE`), so compressed, sparse and cloud-evicted files count for what they occupy. Hard links are counted once. The info panel also shows the apparent (logical) size.

**Startup disk.** The Mac boots from a sealed System volume joined to a Data volume through firmlinks, plus Preboot, VM, Update and other volumes in the same APFS container. DiskWhorl scans each one in parallel and merges them into one tree that mirrors what Finder shows. Items that exist only on the Data volume keep their real path, so Reveal, Quick Look and deletion always act on the right file.

**Hidden space.** `used − files found − purgeable`. It typically holds APFS snapshots, the Recovery volume, swap and sleep images, folders the scan could not read, and file-system metadata. The Hidden Space window lists APFS snapshots (`diskutil apfs listSnapshots`) and deletes Time Machine and third-party snapshots with administrator approval (`tmutil deletelocalsnapshots`, `diskutil apfs deleteSnapshot`). The sealed system snapshot is protected and cannot be deleted.

**Purgeable space.** Two tools. *Thin Time Machine Snapshots* runs `tmutil thinlocalsnapshots <volume> … 4`. *Reclaim Purgeable Space* reserves free space in a temporary file using `F_PREALLOCATE` (no data is written), which makes macOS purge on its own, then deletes the file. It never lets free space drop below 1.5 GB and gives up after 20 seconds without progress.

**Administrator mode.** The app runs its own executable as root (`--helper-scan`) through the standard macOS authentication dialog (`osascript … with administrator privileges`). No helper daemon is installed. The root process writes progress and the finished tree to files in your temporary folder, and the app reads them back.

**Safety stoppers.** These locations are blocked:

- `/System` and the other system volumes
- `/bin`, `/sbin`, `/usr` (except `/usr/local` contents)
- `/private/var/db`, `/private/var/vm`, `/private/var/folders`, `/Library/Apple`
- keychains
- volume roots and mount points
- your home folder and its standard folders
- anything SIP-restricted, immutable or no-unlink
- DiskWhorl itself

These need an extra acknowledgement:

- items inside an `.app`
- `~/Library` and `/Library` contents
- iCloud Drive and other cloud-synced items
- running applications
- media libraries

Every item is checked again against the live file system just before deletion.

**What it does not do.** It runs no automated cleaning, cache clearing, background maintenance or file-system monitoring. Results stay as they were at the end of the scan until you rescan. It makes no network connections.

## Limitations

- APFS clones share blocks but are counted at full size each. When this makes the scan exceed the used space the volume reports, the summary card says so.
- macOS does not report how much space each snapshot holds, so snapshot sizes are not shown.
- Moving items to the Trash does not free space until the Trash is emptied. Items on volumes without a Trash (some network shares, FAT/exFAT media) can be deleted permanently after a second confirmation.
- Root-owned items, such as some apps in `/Applications`, may refuse to move to the Trash. Use **Reveal in Finder** and delete them there.

## Disclaimer

DiskWhorl can move files to the Trash and, when you confirm it, delete them permanently. It can also delete APFS snapshots with administrator approval. Its safety checks reduce risk, but they cannot know what matters to you. Keep backups, review what you collect, and use it at your own risk.

## License

Released under the [MIT License](LICENSE).
