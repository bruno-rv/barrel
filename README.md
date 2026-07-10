# Barrel

![Barrel app icon](Resources/AppIcon.png)

Barrel is a native macOS SwiftUI shelf app inspired by drag-and-drop holding utilities. It is an original implementation and does not copy Yoink branding, artwork, or proprietary code.

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
