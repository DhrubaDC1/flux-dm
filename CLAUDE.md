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
- Unsigned release CI (`.github/workflows/release.yml`): a `v*` tag matching
  pubspec runs analyze/tests, builds Linux tar.gz and AppImage (Ubuntu 22.04
  glibc floor; appimagetool/runtime pinned by SHA-256),
  Windows zip with MSVC runtime, macOS zip, Android APK and unsigned iOS IPA,
  then publishes a GitHub pre-release. App icons on every platform (Android
  adaptive) are generated from `docs/logo.svg`.

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
- Passed locally: release workflow's Linux packaging (tarball extracted and
  launched under Xvfb with a throwaway profile) and Android release APK with a
  test keystore and with the debug-key fallback (apksigner); adaptive icon is
  in the APK.
- Passed on GitHub Actions (manual runs 40505364495, 40507118785): tests and
  all five release builds. Inspected artifacts: Windows zip has exe + MSVC
  DLLs; macOS app is universal (x86_64+arm64), ad-hoc signed, has icon; IPA
  has Payload/Runner.app; APK has arm64/armv7/x86_64; Linux binary needs
  glibc <= 2.34 and the CI tarball launched here under Xvfb.
- Published v0.1.0 pre-release (run 40520686179) with all five packages. Its
  APK is debug-key signed by user choice, so later stable-key APKs cannot
  update it in place. Its AppImage was added afterwards from run 40522566577
  (commit c126d01; app sources identical to the tag, only CI/docs differ).
- Passed: AppImage in CI run 40522566577. Payload unpacked with 7z (AppRun
  link, desktop entry, icon) and launched via AppRun under Xvfb. Running the
  AppImage itself (type2 runtime/FUSE mount) is untested here.
- Unrun: Android device/runtime validation; no ADB device is connected.
- Unrun: Windows, macOS and iOS runtime, and Apple signing; no such hosts or
  devices are available here.

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

## Releasing

Bump `version:` in pubspec.yaml, commit, then `git tag v<version>` and push the
tag. Manual workflow runs only upload artifacts. Android release signing is
optional: repo secrets `ANDROID_KEYSTORE_BASE64` (base64 .jks),
`ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` map to
the `fluxKeystore*` Gradle properties. Without them each APK gets a throwaway
debug key and cannot update an earlier install; uninstalling deletes downloads
in app-private storage. Never commit keystores.
