# Architecture decision: shared native app and transfer core

Status: implemented core milestone, 2026-10-27.

## Technology choice

Flutter provides one native-rendered UI across Windows, Linux, macOS, Android
and iOS. Dart's asynchronous file/socket APIs provide a shared foreground
transfer engine without a local web server, subprocess downloader, or separately
maintained JavaScript/native engines. The desktop layout follows the familiar
category-tree/list/toolbar workflow of classic desktop download managers; narrow
screens use a drawer and download cards.

Alternatives considered: Electron would require a separate mobile implementation;
Qt has strong desktop integration but adds a more demanding mobile toolchain and
binding/distribution choices; a Rust core plus Flutter/Tauri would add FFI and a
second build toolchain before transfer correctness is established. A Rust engine
remains an option if profiling demonstrates a bottleneck. Async streamed I/O
currently bounds memory by chunks and connection count, not file size.

Official references: [Flutter platforms](https://docs.flutter.dev/reference/supported-platforms),
[desktop support](https://docs.flutter.dev/platform-integration/desktop),
[background execution](https://docs.flutter.dev/packages-and-plugins/background-processes).

## Boundaries

- `lib/core/model.dart`: transfer state, progress, category inference, portable
  filename rules. No Flutter imports.
- `lib/core/manager.dart`: real HTTP/file I/O, validators, range checks, retries,
  part recovery, atomic metadata replacement, final assembly and queue limits.
  No Flutter imports. A broadcast stream supplies UI updates four times/second.
- `lib/ui/`: rendering and workflows.
- `lib/main.dart`: native directory discovery and application composition.
- Platform runner folders: generated Flutter hosts, app identities, network
  permissions and sandbox entitlements. They are build targets, not evidence of
  a passed platform test.

## Transfer lifecycle and correctness

1. Validate HTTP(S) URL and destination; sanitize filenames for every platform.
   Reserve a distinct task path, numbering duplicate names. The current policy
   never overwrites an existing download.
2. Persist a queued task. Download Later does not initiate a request. Download
   now enters the bounded active-file queue; each file has its own connection
   limit. Explicitly starting the queue activates deferred/paused tasks.
3. Probe using `GET Range: bytes=0-0` rather than relying on HEAD support.
   Validate 206 metadata; a 200 response selects sequential transfer. Request
   identity encoding and retain strong ETag or Last-Modified as remote identity.
4. With a compatible validator, divide the file into bounded fixed ranges.
   Without a validator, use one connection and restart on resume to avoid mixing
   different resource versions. Fixed partitioning is explicitly short of IDM's
   documented dynamic half-splitting/rebalancing.
5. Persist segment boundaries and validators before any part write. Each segment
   owns a separate part file and handle. Await writes; derive recovered offsets
   from actual file lengths rather than stale progress counters. Never append
   against an incompatible resource identity or an ignored/mismatched range.
6. Retry transient connection/HTTP failures at most twice with short backoff.
   Keep partials on failure. There is no claim that this matches IDM's exact retry
   timing. Pause closes active clients and waits for file handles to close.
7. Assemble into a temporary file in the destination filesystem, verify length,
   exclusively reserve the final path, then rename and persist completion.
   Recover publication/manifest interruption by comparing any existing final file
   byte-for-byte against complete parts. Unrelated same-size files remain safe.
8. Remove deletes history and owned partials; completed user files remain on disk.
   Reopening does not automatically restart network activity. OS file locks and
   an in-process guard prevent concurrent writers to the same state directory.

State format version 1 is JSON and has a single serialized writer. Layout and
metadata updates use flushed temporary files and atomic rename. Parts are
flushed on transfer completion/pause; power-loss durability of the filesystem
and parent directory is not guaranteed. Corrupt/unsupported state is surfaced,
not silently replaced. Backups, migrations and integrity hashes belong to the
hardening milestone.

## Platform integration strategy and limits

| Platform | Present implementation | Required before production |
| --- | --- | --- |
| Linux | Flutter GTK host; desktop destination picker; shared foreground engine | Packaging, keychain, tray/notifications, desktop integration |
| Windows | Flutter host scaffold; shared foreground engine | Windows build/run, installer, notifications, signed release |
| macOS | Flutter scaffold; network and user-selected/download-folder entitlements | Apple build/run, persisted security-scoped folder bookmarks, signing/notarization |
| Android | Flutter host; INTERNET and explicit HTTP support; app-private Downloads | Device tests, foreground transfer service/WorkManager, SAF/MediaStore export and share receiver |
| iOS | Flutter host; app Documents/Downloads exposed in Files; HTTP networking policy | Apple build/run/signing, background URLSession adapter, document export/share extension |

The engine currently runs while the app is executing. Mobile background transfer
is not achieved by a Dart isolate alone. iOS requires OS-owned background
[URLSession downloads](https://developer.apple.com/documentation/Foundation/downloading-files-in-the-background);
Android needs a visible foreground transfer/service and recovery compatible with
its restrictions. Native adapters must share persisted task/events semantics
while allowing the OS to own transfer scheduling. Their segmentation/background
differences must be represented accurately in the UI.

Browser capture should use a separately authored WebExtension and explicit
host messaging/share integration, with narrow URL/context exchange. Windows
kernel-level interception and protected-media/licence mechanisms are out of scope.

Authentication, proxy credentials and URL headers are not yet implemented;
credential-bearing URLs are rejected. Future credentials belong in native
secure storage rather than the JSON manifest, and redirect-origin policy needs
dedicated tests. Download URLs can themselves contain sensitive query tokens;
state is local, and must not be uploaded as diagnostics by default.

## Fidelity validation

Core tests use independent local HTTP origins with deterministic response bytes,
slow streams, validators, ignored/malformed ranges, disconnects and redirects.
Widget tests exercise actual state changes and layout. Native builds and runtime
smoke checks are reported separately in `CLAUDE.md`. Side-by-side comparison
with IDM's live workflows requires a Windows host; the other targets need their
own hosts/devices.
