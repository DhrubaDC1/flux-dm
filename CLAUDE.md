# Flux Download Manager: progress and verification

Updated: 2026-10-27. Scope: open-source (GPL-3.0), cross-platform download
manager aiming to be the closest alternative to IDM. Public repo:
https://github.com/DhrubaDC1/flux-dm. Keep this tracker current with feature changes.

## Completed implementation

- Local isolated Git repository, shared Dart model/transfer engine, adaptive
  Flutter interface and native runner projects for all five requested targets.
- Persistent fixed-range downloads and sequential fallback, pause/resume,
  safe restart when validators change, strict response checks, retry bounds.
- Deferred downloads, main queue start/stop and concurrency; persisted options.
- Portable Unicode filenames, no overwrite policy, crash-at-publication recovery.
- Desktop categories/table/search/sort and mobile drawer/cards, two-step Add URL,
  progress/segments and history deletion preserving downloaded files.
- Network permissions, macOS sandbox entitlements, mobile private storage and
  iOS Files visibility.
- Architecture decision and measurable roadmap.

## Verification

- User confirmed the Linux application launches and works on this PC.
- Passed: 20 independent core tests with real HTTP and filesystem operations,
  including malformed/ignored ranges, validator changes, persistent resume,
  queues, late filename conflicts, publish interruption and Unicode limits.
- Passed: initial Linux debug build; rendered and inspected the actual app on
  a private Xvfb display using Mesa software rendering.
- Passed: all 23 tests (20 core + 3 widget); whole-project Flutter analysis has
  no issues. Desktop and 390px mobile widget flows verified; current Linux debug
  bundle rebuilt after final implementation changes.
- Passed twice: Linux native end-to-end smoke (`tool/linux_smoke.sh`). Two
  launches of the real GTK app under Xvfb share a throwaway profile: Add URL ->
  start -> Stop mid-transfer -> process exit -> relaunch shows Paused -> Resume
  requests only missing ranges -> exact bytes -> Delete keeps the file. Driven
  by integration_test, not the earlier synthetic X keys (which were invalid).
- Passed: Android ARM64 debug APK build. Initial attempts encountered sandboxed
  read-only SDK/tool paths, temporary disk quota, and Kotlin daemon stalls.
  Task-owned temporary files were removed; Kotlin now compiles in Gradle's
  process. Directory lookup uses the platform-channel backend instead of JNI.
  This host used NDK 27.1 via the explicit `fluxNdkVersion` override; the default
  uses Flutter's recommended NDK. Plugins warn that they prefer NDK 28.2;
  no Android runtime/device validation has been performed.
- Passed: Apple plist/entitlement and Android manifest syntax parsing.
- Unrun: Android device/runtime validation; no ADB device is connected.
- Unrun: Windows build/runtime and macOS/iOS build/runtime/signing; required
  operating system hosts/toolchains are unavailable here.

## Current boundary

This is a core milestone. Dynamic half-splitting/rebalancing, schedule/named/sync
queues, speed limits/quotas, batch/capture/grabber/media, authentication/proxies,
mobile background adapters, secure secrets and production packaging remain open.
Do not describe the implementation as full parity or production-ready. Treat
generated platform projects separately from built and runtime-tested platforms.
See ROADMAP.md for acceptance gates. `research/` is local-only reference
material: it is gitignored and must never be committed, published or packaged.

## Useful commands

```sh
flutter pub get
flutter analyze
flutter test --reporter expanded
flutter run -d linux
FLUTTER=flutter tool/linux_smoke.sh   # needs xvfb-run
flutter build apk --debug --target-platform android-arm64
```

In this sandbox use `/tmp/flutter/bin/flutter --suppress-analytics` with
`FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true
PUB_CACHE=/tmp/flux-pub-cache`. Android builds use task-owned Gradle/SDK caches.
The existing NDK can be selected with
`ORG_GRADLE_PROJECT_fluxNdkVersion=27.1.12297006`; use Flutter's default on a
fully provisioned host. Build log: `/tmp/flux-android-build-final.log`.
Avoid global configuration edits.
