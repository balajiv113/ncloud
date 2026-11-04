# ncloud

A single Flutter app for Android and iOS, bringing Nextcloud photos and files into a modern, private interface. **Early functional preview, not full Immich/Google Drive parity.** It connects directly to your server; there is no ncloud backend or telemetry.

## Install and try on Android

1. Sign in to GitHub with access to this private repository. Open **Releases** and choose the newest **ncloud Android preview**.
2. Download `ncloud-android.apk` on your phone. Open it and allow installation from your browser/file manager when Android asks.
3. Open **ncloud → Try demo** to explore immediately without an account. Demo illustrations and changes are local and reset when leaving demo.
4. To use your own files, leave demo from Settings and enter your server's full **HTTPS** address (including any Nextcloud subfolder). Choose **Connect Nextcloud**, approve access in your browser, then return to ncloud.

If browser login is unavailable, create an **app password** in Nextcloud → Personal settings → Security and use the alternative sign-in form. Do not enter your main password. Self-signed/untrusted certificates and plain HTTP are intentionally not supported; install a valid certificate.

Every successful `main` build publishes an APK to a private prerelease and retains an Actions artifact for 30 days. Preview APKs use a **development signing key, not production signing**. If Android rejects an update because its signer changed, uninstall the old preview first (this clears its saved account), then install the new one. Do not distribute these builds as production releases.

## iPhone / iPad testing

iOS does **not** allow an arbitrary unsigned download to be installed like an APK. The complete iOS project is included, but a Mac with Xcode and Apple signing is required:

```sh
git clone https://github.com/balajiv113/ncloud.git
cd ncloud
flutter pub get
open ios/Runner.xcworkspace
```

In Xcode select **Runner → Signing & Capabilities → your Apple team**, choose a unique bundle ID if needed, select your phone, and Run. A personal Apple ID can test on your own device subject to Apple's provisioning limits; Developer Mode may need enabling. For easy distribution to testers, enroll in the Apple Developer Program, configure distribution signing, and upload an archive to TestFlight. No Apple account, certificates, or signing secrets are included in this repository.

Alternatively, boot an iOS Simulator on the Mac and run `flutter run -d <simulator-id>`. Actions → **Build and test → Run workflow → build_ios** performs an unsigned iOS compile check. Its unsigned `.app` artifact is **not installable on an iPhone**.

## What works now

| Area | Preview functionality |
|---|---|
| Experience | Material 3, system light/dark theme, responsive photo grid, local demo |
| Account | Nextcloud Login Flow v2, app-password alternative, secure credential storage, session restore, disconnect |
| Files | Folder browsing/breadcrumbs, create folder, streamed foreground upload, download original via the system share/save sheet |
| Photos | Up to 200 most recently **modified** photos/videos across your account, server thumbnails, zoomable photo preview |
| Favorites | Star/unstar files and folders, server-wide view of up to 200 recent favorites |
| Filtering | Case-insensitive name filtering of loaded items/current folder, pull-to-refresh |

Photos use WebDAV SEARCH, not an Immich API. Dates are file modification times, **not EXIF capture dates**. Previews depend on your server's preview providers (especially HEIC and video); unavailable previews have a retry state. Video playback is external via Download & share. Search/preview API errors are displayed, never replaced with fake demo data.

Transfers require the app to stay open. Uploads never overwrite existing filenames. There is no background/resumable transfer queue or camera-library access yet. Downloads are streamed to temporary app storage and handed to the system share sheet; choose Save to Files or an appropriate app. Disconnect removes credentials and ncloud's downloaded cache, but not files you saved/shared elsewhere. Revoke the app password in Nextcloud Security settings to revoke server access.

## Develop

Use **Flutter 3.38.5 / Dart 3.10**, JDK 17, and the Android SDK (Android Studio), or Xcode/CocoaPods on macOS for iOS. Android supports API 24+; iOS supports 13+.

```sh
flutter doctor
flutter pub get
flutter devices
flutter run                         # select your connected phone or emulator
flutter test
flutter analyze
dart format --output=none --set-exit-if-changed lib test
flutter build apk --release         # build/app/outputs/flutter-apk/app-release.apk
flutter install --release -d <device-id>
```

Android USB testing: enable Developer options → USB debugging and accept your computer's authorization prompt. Emulators can exercise demo mode without a Nextcloud server. These builds are mobile-only; Flutter web/desktop are not configured.

## Architecture and APIs

`lib/models.dart` contains typed account/file models and URL validation. `nextcloud_client.dart` handles Login Flow v2, OCS user lookup (DAV user ID may differ from login email), WebDAV PROPFIND/SEARCH/MKCOL/PUT/PROPPATCH/GET, and authenticated previews. `app_controller.dart` coordinates session storage, race-safe loading, demo data, and foreground transfers. UI is in `screens.dart` and `media_tile.dart`.

Credentials use iOS Keychain / Android encrypted storage. HTTPS is required, authenticated redirects are not followed, and login endpoints must remain on the configured origin. No certificate bypass, main-password persistence, analytics, or third-party image service is used. Downloaded originals are app-cache files until exported. Thumbnails are held in a bounded in-memory cache.

## Roadmap toward the full vision

This is the foundation, not a claim that core Nextcloud supplies all Immich and Google Drive capabilities.

1. Reliable camera backup: OS photo permissions, deduplication, resumable/chunked uploads, background queues, cellular/battery policies and transfer progress.
2. Drive essentials: rename/move/copy/delete, trash/restore, share links and permissions, offline files, server search, file previews/editing and multiple accounts.
3. Photo library: capture-date timeline, pagination/indexing beyond 200 items, albums, in-app video, Live Photos/RAW/HEIC handling, maps, shared libraries and duplicate management.
4. Intelligence: evaluate Nextcloud Photos/Memories/Recognize/Face Recognition APIs and compatibility. Face grouping, semantic search, memories and transcoding require suitable server apps or a separately designed indexing service; they cannot be promised from core WebDAV alone.
5. Distribution: production signing, TestFlight, app-store privacy disclosures, accessibility/device testing, and release hardening.

Before enabling automatic backup or destructive file operations, add integration coverage against real supported Nextcloud versions and device background-lifecycle tests. Current automated checks cover API contracts with mocked HTTP responses and demo/widget flows; they do not prove compatibility with every Nextcloud deployment.
