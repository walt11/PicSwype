# PicSwype

PicSwype is an iPhone and iPad app for reviewing photos and videos one at a time. Tap a video’s play icon to watch it. Swipe right to keep an item or left to add it to the deletion queue. Open the queue to review thumbnails, keep a photo you queued by mistake, or delete selected copies.

## Connect a library

- **Apple Photos** uses the library access you grant in iOS Settings.
- **Immich** connects to your server URL with an API key. The key needs access to search photos, read previews and originals, and move selected assets to trash.
- **Synology Photos** connects to Personal Space using a DSM address or QuickConnect ID. Sign in with your DSM account and verification code if required. You can also choose a NAS folder through Files.

PicSwype starts with Apple Photos. Open Settings to add an Immich or Synology connection. Tap the title to switch between connected libraries. To check for copies across services, turn on **Settings → Link libraries**. With three connected services, select the libraries to include. Connect each selected server directly and allow Photos access if you include Apple Photos. Matching starts when you queue a photo. PicSwype compares originals, so edits or re-encoded copies can produce different results. The queue shows which libraries contain verified matches and lets you choose where to delete. A matching still from an Immich Live Photo is flagged when the motion component is unverified.

## Build

Open `PicSwype.xcodeproj` in Xcode with an iOS SDK, let Swift Package Manager resolve ZIPFoundation, and run the **PicSwype** scheme on an iOS 17 or later simulator. Use **Product → Test** to run the test suite. For installation on your own device, select your development team and a bundle identifier available to it. The project is generated from `project.yml` with XcodeGen.

## Privacy and license

[Privacy policy](https://walt11.github.io/PicSwype/privacy/) · [PicSwype support](https://walt11.github.io/PicSwype/support/)

PicSwype is copyright © 2026 John Walter and distributed under the [MIT License](LICENSE). ZIPFoundation’s [MIT notice](PicSwype/ZIPFoundation-LICENSE.txt) is included in the app under **About PicSwype → Licenses**.
