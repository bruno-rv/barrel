# Barrel

![Barrel app icon](Resources/AppIcon.png)

Barrel is a native SwiftUI shelf app inspired by drag-and-drop holding utilities. It is an original implementation and does not copy Yoink branding, artwork, or proprietary code.

## macOS Features

- Floating desktop shelf window for temporary file, link, image, and text storage.
- Drag files/text/links/images onto the shelf, and drag stored items back out.
- Import with an open panel or paste directly from the clipboard.
- Stack marked items, split stacks, rename items, open items, reveal files in Finder, and delete held content.
- Persist shelf metadata and copied files in the app's Application Support container.

## macOS Build

Run:

```sh
./script/build_and_run.sh
```

The script builds the SwiftPM app, stages `dist/BarrelMac.app`, stops any previous `BarrelMac` process, and launches the fresh bundle.

## iOS Features

- Import one or more files from Files.
- Open compatible documents into Barrel through iOS document handling.
- Paste text, links, and images from the clipboard.
- Drop files, links, text, and images onto the shelf on iPad.
- Stack multiple selected items, split stacks, rename items, and delete held content.
- Preview files and images with Quick Look.
- Share stored files, links, and text back out through the system share sheet.
- Persist shelf metadata and copied files in the app's Application Support container.

## iOS Build

Open `Barrel.xcodeproj` in Xcode, set a development team if you want to run on a physical device, then build the `Barrel` scheme for an iPhone or iPad simulator.

The iOS project targets iOS 17.0 or later.
