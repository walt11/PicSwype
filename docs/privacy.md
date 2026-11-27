---
title: PicSwype privacy policy
permalink: /privacy/
---

# PicSwype privacy policy

Updated November 27, 2026

PicSwype is a photo and video review app by John Walter. You choose which libraries it can access. The developer does not operate a photo server, receive your library or review history, sell personal information, or use advertising or analytics SDKs in the app.

## Photo access and matching

PicSwype reads photo and video identifiers, filenames, previews, and originals from the libraries you connect. It uses this information to show photos, play videos, and find copies when you enable library linking. Matching runs on your device. PicSwype can send a file checksum or filename to your Immich server to look for candidates and download originals from your connected services to verify them. Access to Apple Photos follows your iOS permission selection and can include downloading originals from iCloud through Apple Photos.

## Connections and storage

The app sends authentication and library requests to the server address you configure. QuickConnect also sends your QuickConnect ID to Synology to locate your NAS and can route traffic through Synology’s relay. These services can receive connection information, including your IP address. Their own policies and your server settings govern their logs and retention.

PicSwype stores your Immich API key and saved Synology session in the iOS Keychain. It keeps connection settings, folder access bookmarks, review decisions, queue entries, and matching information locally. Queued thumbnails are cached on the device and removed when their entries leave the queue. Review history can persist after a queue entry is removed.

## Your choices

You can remove an item from the queue, change which libraries are selected, or unlink libraries before deleting. Choosing Delete All sends deletion requests to the selected libraries. Recovery depends on the library and its trash settings. You can change Apple Photos access in iOS Settings, revoke the Immich API key on your server, and invalidate a Synology session on your NAS.

Apple may process beta feedback or diagnostics through TestFlight according to your Apple settings. Opening this policy or the project on GitHub makes a request to GitHub.

## Contact

For questions, contact John Walter through the [PicSwype project](https://github.com/walt11/PicSwype/issues). Issues are public. Please omit private photos, server addresses, passwords, and API keys.

[PicSwype support](../support/)
