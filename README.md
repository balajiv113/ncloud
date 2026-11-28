# ncloud

A Flutter app for Android and iOS that brings your Nextcloud photos, videos
and files into a modern, private interface.

ncloud talks directly to your own Nextcloud server. There is no ncloud backend,
no account to create with us, and no telemetry.

> **Status: early preview.** Core browsing, albums, sharing, and phone backup
> work, but the app is not yet at feature parity with Immich. See
> [docs/IMMICH_PARITY.md](docs/IMMICH_PARITY.md) for what is done and what is
> planned. Development notes and release history are in
> [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Features

- **Timeline:** photos and videos by date, with fast scrubbing and memory cards
  for past years (via the Memories app, when installed).
- **Albums:** server albums, smart albums, and the photos on your phone that are
  not backed up yet.
- **Drive:** browse, upload, rename, move, copy, and delete files, with
  permissions respected from the server.
- **Map:** photos with location data, using OpenStreetMap tiles on request.
- **People:** face groups from Memories' Recognize app.
- **Sharing:** public links and user shares.
- **Phone backup:** automatic backup of chosen phone albums on Android and iOS.
- **Offline:** save originals for offline viewing.

## Requirements

- A Nextcloud server reachable over **HTTPS** with a valid certificate.
  Self-signed certificates and plain HTTP are not supported.
- Optional: the Memories app (timeline index, memories, and people).

## Sign in

1. Enter your server address, such as `https://cloud.example.com`.
2. Approve access in your browser, or use **Use an app password instead** and
   create an app password in Nextcloud under Personal settings → Security.
   Do not enter your main password.

## Build from source

Requirements: Flutter 3.50.1 (stable), Java 17, Android SDK (for Android) and
Xcode (for iOS).

```sh
flutter pub get
flutter run            # on a connected device or emulator
flutter test           # unit tests
flutter analyze        # static analysis
```

For Android, `flutter build apk --debug` builds an installable APK. For iOS,
open `ios/Runner.xcworkspace` in Xcode after `flutter pub get`.

## Contributing

Issues and pull requests are welcome. Please run `flutter analyze` and
`flutter test` before opening a pull request. The CI workflow in
`.github/workflows/build.yml` runs these checks along with device tests.

## License

MIT. See [LICENSE](LICENSE).
