import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flux_dm/core/manager.dart';
import 'package:flux_dm/core/model.dart';
import 'package:flux_dm/main.dart' as app;
import 'package:flux_dm/ui/app.dart';
import 'package:integration_test/integration_test.dart';

// Run through tool/linux_smoke.sh: two app launches share one throwaway XDG
// profile, so "reopen" is a real process restart of the native app.
const _phase = String.fromEnvironment('FLUX_PHASE');
const _port = 47321;
const _name = 'smoke.bin';
const _url = 'http://127.0.0.1:$_port/$_name';
const _chunk = 16 * 1024;
final _bytes = Uint8List.fromList(
  List<int>.generate(8 * 1024 * 1024, (i) => (i * 31 + 7) % 251),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Linux native smoke: $_phase', (tester) async {
    final ranges = <String>[];
    final server = await _serve(slow: _phase == 'pause', ranges: ranges);
    addTearDown(() => server.close(force: true));
    await app.main();
    await tester.pumpAndSettle();
    final manager = tester.widget<FluxApp>(find.byType(FluxApp)).manager;
    switch (_phase) {
      case 'pause':
        await _addAndPause(tester, manager);
      case 'resume':
        await _resumeAndDelete(tester, manager, ranges);
      default:
        fail('Run via tool/linux_smoke.sh (FLUX_PHASE=pause|resume)');
    }
  });
}

Future<void> _addAndPause(WidgetTester tester, DownloadManager manager) async {
  expect(manager.tasks, isEmpty, reason: 'phase 1 needs a fresh profile');
  await tester.tap(find.text('Add URL').first);
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('download-url')), _url);
  await tester.tap(find.text('Next'));
  await tester.pumpAndSettle();
  // The XDG Downloads lookup ignores env overrides; never publish into it.
  final folder = Platform.environment['FLUX_SMOKE_DIR']!;
  await tester.enterText(find.byKey(const Key('download-directory')), folder);
  await tester.tap(find.byKey(const Key('start-download')));
  await _until(tester, () => manager.tasks.isNotEmpty);
  final task = manager.tasks.single;
  expect(task.directory, folder);
  await _until(tester, () => task.received >= 512 * 1024);

  await _select(tester);
  await tester.tap(find.text('Stop').first);
  await _until(tester, () => task.status == DownloadStatus.paused);
  expect(task.received, lessThan(_bytes.length));
  expect(find.text('Paused'), findsWidgets);
}

Future<void> _resumeAndDelete(
  WidgetTester tester,
  DownloadManager manager,
  List<String> ranges,
) async {
  final task = manager.tasks.single;
  expect(task.status, DownloadStatus.paused);
  final kept = task.received;
  expect(kept, inExclusiveRange(0, _bytes.length));
  expect(find.text('Paused'), findsWidgets);

  await _select(tester);
  await tester.tap(find.text('Resume').first);
  await _until(tester, () => task.status == DownloadStatus.complete);
  expect(await File(task.path).readAsBytes(), _bytes);
  // Ranges after the one-byte probe must cover exactly the bytes still missing.
  final fetched = ranges.where((r) => r != 'bytes=0-0').map((r) {
    final [start, end] = r.substring(6).split('-').map(int.parse).toList();
    return end - start + 1;
  });
  expect(fetched.fold(0, (a, b) => a + b), _bytes.length - kept);

  await tester.tap(find.text('Delete').first);
  await _until(tester, () => find.text(_name).evaluate().isEmpty);
  expect(manager.tasks, isEmpty);
  // Deleting a history row keeps the completed file.
  expect(File(task.path).lengthSync(), _bytes.length);
}

Future<void> _select(WidgetTester tester) async {
  await tester.tap(find.text(_name).first);
  // Wait out the row's double-tap window so the selection lands.
  await Future<void>.delayed(const Duration(milliseconds: 500));
  await tester.pump();
}

Future<void> _until(WidgetTester tester, bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for the app');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
}

Future<HttpServer> _serve({
  required bool slow,
  required List<String> ranges,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, _port);
  server.listen((request) async {
    final response = request.response;
    try {
      final range = request.headers.value(HttpHeaders.rangeHeader)!;
      ranges.add(range);
      final [start, end] = range.substring(6).split('-').map(int.parse).toList();
      response
        ..statusCode = HttpStatus.partialContent
        ..contentLength = end - start + 1;
      response.headers
        ..set(HttpHeaders.etagHeader, '"smoke-1"')
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${_bytes.length}',
        );
      for (var at = start; at <= end; at += _chunk) {
        response.add(
          Uint8List.sublistView(_bytes, at, min(at + _chunk, end + 1)),
        );
        await response.flush();
        // Phase 1 throttles so the pause lands mid-transfer.
        if (slow) await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await response.close();
    } catch (_) {
      // Pausing cancels in-flight ranges; the app sees the disconnect.
    }
  });
  return server;
}
