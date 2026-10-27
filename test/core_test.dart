import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flux_dm/core/manager.dart';
import 'package:flux_dm/core/model.dart';

/// These tests exercise real HTTP streams and real files, including hostile
/// range responses. They do not reproduce the transfer implementation.
void main() {
  late Directory root;
  late Directory destination;
  late DownloadManager manager;
  late _Origin origin;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('flux-core-test-');
    destination = await Directory('${root.path}/downloads').create();
    manager = await DownloadManager.open(Directory('${root.path}/state'));
    origin = await _Origin.start();
  });

  tearDown(() async {
    await manager.close();
    await origin.close();
    await root.delete(recursive: true);
  });

  test('parallel ranges produce the exact original file', () async {
    final task = await manager.add(
      origin.url('/range'),
      directory: destination.path,
      connections: 4,
    );
    await _terminal(task);
    expect(task.status, DownloadStatus.complete, reason: task.error);
    expect(await File(task.path).readAsBytes(), orderedEquals(origin.bytes));
    expect(task.received, origin.bytes.length);
    expect(task.totalBytes, origin.bytes.length);
    expect(task.supportsResume, isTrue);
    expect(origin.ranges.where((r) => r != 'bytes=0-0').length, greaterThan(1));
  });

  test('server ignoring ranges falls back without duplicate bytes', () async {
    final task = await manager.add(
      origin.url('/plain'),
      directory: destination.path,
      connections: 8,
    );
    await _terminal(task);
    expect(task.status, DownloadStatus.complete, reason: task.error);
    expect(task.supportsResume, isFalse);
    expect(await File(task.path).readAsBytes(), orderedEquals(origin.bytes));
  });

  test('non-resumable download restarts cleanly after pause', () async {
    final task = await manager.add(
      origin.url('/plain-slow'),
      directory: destination.path,
      connections: 4,
    );
    await _until(() => task.received > 32768);
    await manager.pause(task.id).timeout(const Duration(seconds: 5));
    origin.replaceContent();
    await manager.resume(task.id);
    await _terminal(task);
    expect(task.status, DownloadStatus.complete, reason: task.error);
    expect(await File(task.path).readAsBytes(), orderedEquals(origin.bytes));
  });

  test(
    'range origin without validators restarts safely using one segment',
    () async {
      final task = await manager.add(
        origin.url('/unvalidated-slow'),
        directory: destination.path,
        connections: 8,
      );
      await _until(() => task.received > 32768);
      expect(task.segments, hasLength(1));
      expect(task.supportsResume, isFalse);
      await manager.pause(task.id).timeout(const Duration(seconds: 5));
      origin.replaceContent();
      origin.ranges.clear();
      await manager.resume(task.id);
      await _terminal(task);
      expect(task.status, DownloadStatus.complete, reason: task.error);
      expect(task.supportsResume, isFalse);
      expect(task.segments, hasLength(1));
      expect(await File(task.path).readAsBytes(), orderedEquals(origin.bytes));
      expect(
        origin.ranges.where((range) => range != 'bytes=0-0'),
        everyElement(startsWith('bytes=0-')),
        reason: 'Unvalidated partial bytes must never be appended after pause.',
      );
    },
  );

  test(
    'pause, restart the manager, and resume persisted partial ranges',
    () async {
      final task = await manager.add(
        origin.url('/slow'),
        directory: destination.path,
        connections: 2,
      );
      await _until(() => task.received > 32768);
      await manager.pause(task.id).timeout(const Duration(seconds: 5));
      final savedBytes = task.received;
      expect(task.status, DownloadStatus.paused);
      expect(savedBytes, greaterThan(0));
      expect(await File(task.path).exists(), isFalse);
      await manager.close();
      manager = await DownloadManager.open(Directory('${root.path}/state'));
      final restored = manager.tasks.single;
      expect(restored.id, task.id);
      expect(restored.status, DownloadStatus.paused);
      expect(restored.received, savedBytes);
      origin.ranges.clear();
      await manager.resume(restored.id);
      await _terminal(restored);
      expect(restored.status, DownloadStatus.complete, reason: restored.error);
      expect(
        await File(restored.path).readAsBytes(),
        orderedEquals(origin.bytes),
      );
      expect(
        origin.ranges.any((r) {
          final match = RegExp(r'^bytes=(\d+)-').firstMatch(r);
          return match != null && int.parse(match[1]!) > 0;
        }),
        isTrue,
        reason: 'A resumed segment must continue at its persisted offset.',
      );
    },
  );

  test(
    'changed validator discards old partial bytes before resuming',
    () async {
      final task = await manager.add(
        origin.url('/slow'),
        directory: destination.path,
        connections: 2,
      );
      await _until(() => task.received > 32768);
      await manager.pause(task.id).timeout(const Duration(seconds: 5));
      origin.replaceContent();
      await manager.resume(task.id);
      await _terminal(task);
      expect(task.status, DownloadStatus.complete, reason: task.error);
      expect(await File(task.path).readAsBytes(), orderedEquals(origin.bytes));
    },
  );

  test('malformed Content-Range cannot publish a corrupt file', () async {
    final task = await manager.add(
      origin.url('/bad-range'),
      directory: destination.path,
      connections: 2,
    );
    await _terminal(task);
    expect(task.status, DownloadStatus.failed);
    expect(task.error, isNotEmpty);
    expect(await File(task.path).exists(), isFalse);
  });

  test('premature EOF cannot publish a truncated file', () async {
    final task = await manager.add(
      origin.url('/short'),
      directory: destination.path,
      connections: 1,
    );
    await _terminal(task);
    expect(task.status, DownloadStatus.failed);
    expect(await File(task.path).exists(), isFalse);
  });

  test(
    'Download Later survives restart and runs only after queue start',
    () async {
      final task = await manager.add(
        origin.url('/range'),
        directory: destination.path,
        start: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(task.status, DownloadStatus.queued);
      expect(origin.ranges, isEmpty);
      await manager.close();
      manager = await DownloadManager.open(Directory('${root.path}/state'));
      final restored = manager.tasks.single;
      expect(restored.status, DownloadStatus.queued);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(origin.ranges, isEmpty);
      await manager.startQueue();
      await _terminal(restored);
      expect(restored.status, DownloadStatus.complete, reason: restored.error);
    },
  );

  test('queue honors the maximum number of simultaneous files', () async {
    manager.maxConcurrent = 1;
    final tasks = <DownloadTask>[];
    for (var i = 0; i < 3; i++) {
      tasks.add(
        await manager.add(
          origin.url('/small-slow?file=$i'),
          directory: destination.path,
          filename: 'file-$i.bin',
          connections: 1,
          start: false,
        ),
      );
    }
    await manager.startQueue();
    await Future.wait(tasks.map(_terminal));
    for (final task in tasks) {
      expect(task.status, DownloadStatus.complete, reason: task.error);
    }
    expect(origin.maximumActiveBodies, 1);
  });

  test(
    'configured concurrency and connections persist across restart',
    () async {
      await manager.configure(maxConcurrent: 3, connections: 4);
      await manager.close();
      manager = await DownloadManager.open(Directory('${root.path}/state'));
      expect(manager.maxConcurrent, 3);
      expect(manager.defaultConnections, 4);
      final task = await manager.add(
        origin.url('/range'),
        directory: destination.path,
        start: false,
      );
      expect(task.connections, 4);
      expect(origin.ranges, isEmpty);
    },
  );

  test(
    'existing destination files and duplicate names are preserved',
    () async {
      final existing = File('${destination.path}/archive.zip');
      await existing.writeAsString('keep this original file');
      final first = await manager.add(
        origin.url('/range'),
        directory: destination.path,
        filename: 'archive.zip',
        start: false,
      );
      final second = await manager.add(
        origin.url('/range'),
        directory: destination.path,
        filename: 'archive.zip',
        start: false,
      );
      expect(first.path, isNot(existing.path));
      expect(second.path, isNot(existing.path));
      expect(second.path, isNot(first.path));
      await manager.resume(first.id);
      await _terminal(first);
      expect(first.status, DownloadStatus.complete, reason: first.error);
      expect(await existing.readAsString(), 'keep this original file');
    },
  );

  test(
    'file created at destination after enqueue is never overwritten',
    () async {
      final task = await manager.add(
        origin.url('/range'),
        directory: destination.path,
        filename: 'late-existing.bin',
        start: false,
      );
      final destinationFile = File(task.path);
      await destinationFile.writeAsString(
        'created outside the download manager',
      );
      await manager.resume(task.id);
      await _terminal(task);
      expect(task.status, DownloadStatus.failed);
      expect(
        await destinationFile.readAsString(),
        'created outside the download manager',
      );
    },
  );

  test(
    'unsafe names stay inside destination and URLs require HTTP(S)',
    () async {
      for (final value in [
        'file:///etc/passwd',
        'ftp://localhost/file',
        'not a url',
      ]) {
        await expectLater(
          manager.add(value, directory: destination.path),
          throwsA(isA<ArgumentError>()),
        );
      }
      final task = await manager.add(
        origin.url('/range'),
        directory: destination.path,
        filename: '../CON?.zip',
        start: false,
      );
      expect(task.filename, isNot(contains('/')));
      expect(task.filename, isNot(contains('\\')));
      expect(File(task.path).parent.path, destination.path);
      expect(safeFilename('CON.txt'), '_CON.txt');
      expect(safeFilename('..'), 'download');
    },
  );

  test(
    'Unicode filenames fit a 200-byte UTF-8 budget and keep extension',
    () async {
      final original = '${List.filled(100, 'বাংলা🍋').join()}.zip';
      final name = safeFilename(original);
      expect(utf8.encode(name).length, lessThanOrEqualTo(200));
      expect(name, endsWith('.zip'));
      expect(utf8.decode(utf8.encode(name), allowMalformed: false), name);
      final task = await manager.add(
        origin.url('/range'),
        directory: destination.path,
        filename: original,
        connections: 1,
      );
      await _terminal(task);
      expect(task.status, DownloadStatus.complete, reason: task.error);
      expect(task.filename, name);
      expect(await File(task.path).readAsBytes(), orderedEquals(origin.bytes));
    },
  );

  test('reopen reconciles publish completed before manifest commit', () async {
    final task = await manager.add(
      origin.url('/range'),
      directory: destination.path,
      connections: 4,
    );
    await _terminal(task);
    expect(task.status, DownloadStatus.complete, reason: task.error);
    await manager.close();
    await _simulateUncommittedPublish(Directory('${root.path}/state'), task);
    origin.ranges.clear();
    manager = await DownloadManager.open(Directory('${root.path}/state'));
    final restored = manager.tasks.single;
    expect(restored.status, DownloadStatus.complete, reason: restored.error);
    expect(restored.received, origin.bytes.length);
    expect(
      await File(restored.path).readAsBytes(),
      orderedEquals(origin.bytes),
    );
    expect(origin.ranges, isEmpty, reason: 'Reconciliation must be offline.');
  });

  test(
    'publish recovery rejects a different target with the same size',
    () async {
      final task = await manager.add(
        origin.url('/range'),
        directory: destination.path,
        connections: 4,
      );
      await _terminal(task);
      expect(task.status, DownloadStatus.complete, reason: task.error);
      await manager.close();
      await _simulateUncommittedPublish(Directory('${root.path}/state'), task);
      final externalBytes = Uint8List.fromList(origin.bytes);
      // A mismatch late in the final segment catches first-chunk-only comparisons.
      externalBytes[externalBytes.length - 17] ^= 0xff;
      await File(task.path).writeAsBytes(externalBytes, flush: true);
      manager = await DownloadManager.open(Directory('${root.path}/state'));
      final restored = manager.tasks.single;
      expect(restored.status, isNot(DownloadStatus.complete));
      expect(
        await File(restored.path).readAsBytes(),
        orderedEquals(externalBytes),
      );
      await manager.resume(restored.id);
      await _terminal(restored);
      expect(restored.status, DownloadStatus.failed);
      expect(
        await File(restored.path).readAsBytes(),
        orderedEquals(externalBytes),
      );
    },
  );

  test('redirect and zero-byte response complete correctly', () async {
    final redirected = await manager.add(
      origin.url('/redirect'),
      directory: destination.path,
    );
    await _terminal(redirected);
    expect(
      redirected.status,
      DownloadStatus.complete,
      reason: redirected.error,
    );
    expect(
      await File(redirected.path).readAsBytes(),
      orderedEquals(origin.bytes),
    );
    final empty = await manager.add(
      origin.url('/empty'),
      directory: destination.path,
    );
    await _terminal(empty);
    expect(empty.status, DownloadStatus.complete, reason: empty.error);
    expect(await File(empty.path).length(), 0);
  });
  test('chunked response without Content-Length downloads to EOF', () async {
    final task = await manager.add(
      origin.url('/unknown-length'),
      directory: destination.path,
    );
    await _terminal(task);
    expect(task.status, DownloadStatus.complete, reason: task.error);
    expect(await File(task.path).readAsBytes(), orderedEquals(origin.bytes));
  });

  test(
    'HTTP error never turns an error page into a completed download',
    () async {
      final task = await manager.add(
        origin.url('/missing'),
        directory: destination.path,
      );
      await _terminal(task);
      expect(task.status, DownloadStatus.failed);
      expect(await File(task.path).exists(), isFalse);
    },
  );
}

/// Recreate the on-disk crash window after final publication but before the
/// completion manifest commit and cleanup of the already-written part files.
Future<void> _simulateUncommittedPublish(
  Directory state,
  DownloadTask task,
) async {
  final manifest = File('${state.path}/downloads.json');
  final document =
      jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
  final saved = (document['tasks'] as List).single as Map<String, dynamic>;
  saved['status'] = 'downloading';
  final original = await File(task.path).readAsBytes();
  final parts = await Directory(
    '${state.path}/parts/${task.id}',
  ).create(recursive: true);
  final segments = saved['segments'] as List;
  for (var i = 0; i < segments.length; i++) {
    final segment = segments[i] as Map<String, dynamic>;
    await File('${parts.path}/$i.part').writeAsBytes(
      original.sublist(segment['start'] as int, (segment['end'] as int) + 1),
      flush: true,
    );
  }
  await manifest.writeAsString(jsonEncode(document), flush: true);
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for a transfer state change.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _terminal(DownloadTask task) => _until(
  () =>
      task.status == DownloadStatus.complete ||
      task.status == DownloadStatus.failed,
);

class _Origin {
  _Origin(this.server);
  final HttpServer server;
  Uint8List bytes = Uint8List.fromList(
    List<int>.generate(2 * 1024 * 1024, (i) => (i * 31 + 7) % 251),
  );
  String etag = '"version-1"';
  final ranges = <String>[];
  final _handlers = <Future<void>>[];
  int _activeBodies = 0;
  int maximumActiveBodies = 0;

  static Future<_Origin> start() async {
    final origin = _Origin(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    origin.server.listen((request) {
      origin._handlers.add(origin._handle(request));
    });
    return origin;
  }

  String url(String path) => 'http://127.0.0.1:${server.port}$path';

  void replaceContent() {
    bytes = Uint8List.fromList(bytes.map((value) => value ^ 0xff).toList());
    etag = '"version-2"';
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    var counted = false;
    try {
      final path = request.uri.path;
      if (path == '/redirect') {
        await response.redirect(Uri.parse(url('/range')));
        return;
      }
      if (path == '/empty') {
        response.contentLength = 0;
        await response.close().timeout(const Duration(seconds: 1));
        return;
      }
      if (path == '/missing') {
        response.statusCode = HttpStatus.notFound;
        response.write('This file does not exist.');
        await response.close().timeout(const Duration(seconds: 1));
        return;
      }
      final content = path == '/small-slow'
          ? Uint8List.sublistView(bytes, 0, 256 * 1024)
          : bytes;
      // Snapshot the body and validator so replacing origin content never changes
      // a response already in flight.
      if (path != '/unvalidated-slow') {
        response.headers.set(HttpHeaders.etagHeader, etag);
      }
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.contentType = ContentType.binary;
      var start = 0;
      var end = content.length - 1;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) ranges.add(range);
      if (range != null &&
          path != '/plain' &&
          path != '/plain-slow' &&
          path != '/unknown-length') {
        final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
        if (match == null) throw StateError('Unexpected Range: $range');
        start = int.parse(match[1]!);
        end = match[2]!.isEmpty ? end : int.parse(match[2]!);
        if (start >= content.length || end >= content.length || end < start) {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes */${content.length}',
          );
          await response.close().timeout(const Duration(seconds: 1));
          return;
        }
        response.statusCode = HttpStatus.partialContent;
        final wrongStart = path == '/bad-range' && range != 'bytes=0-0';
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes ${wrongStart ? start + 1 : start}-$end/${content.length}',
        );
      }
      final length = end - start + 1;
      if (path != '/unknown-length') response.contentLength = length;
      if (request.method == 'HEAD') {
        await response.close().timeout(const Duration(seconds: 1));
        return;
      }
      final isBody = length > 1;
      if (isBody) {
        counted = true;
        _activeBodies++;
        if (_activeBodies > maximumActiveBodies) {
          maximumActiveBodies = _activeBodies;
        }
      }
      if (path == '/short' && isBody) {
        // Detach before headers are emitted, then intentionally violate the
        // advertised body length. HttpResponse itself correctly forbids this.
        final socket = await response.detachSocket(writeHeaders: false);
        socket.write(
          'HTTP/1.1 ${range == null ? '200 OK' : '206 Partial Content'}\r\n'
          'Content-Length: $length\r\n'
          'ETag: $etag\r\n'
          '${range == null ? '' : 'Content-Range: bytes $start-$end/${content.length}\r\n'}'
          'Connection: close\r\n\r\n',
        );
        socket.add(content.sublist(start, start + length ~/ 2));
        await socket.flush();
        socket.destroy();
        return;
      }
      final slow =
          path == '/slow' ||
          path == '/small-slow' ||
          path == '/plain-slow' ||
          path == '/unvalidated-slow';
      if (!slow || !isBody) {
        response.add(content.sublist(start, end + 1));
      } else {
        for (var offset = start; offset <= end; offset += 4096) {
          final next = offset + 4096 < end + 1 ? offset + 4096 : end + 1;
          response.add(content.sublist(offset, next));
          await response.flush().timeout(const Duration(seconds: 1));
          await Future<void>.delayed(const Duration(milliseconds: 4));
        }
      }
      await response.close().timeout(const Duration(seconds: 1));
    } on HttpException {
      // Cancellation/short bodies deliberately terminate fixture connections.
    } on TimeoutException {
      // Cancelling an HTTP client may leave a server flush awaiting drain.
    } on SocketException {
      // Pause and failed-header tests deliberately cancel active responses.
    } finally {
      if (counted) _activeBodies--;
    }
  }

  Future<void> close() async {
    await server.close(force: true);
    await Future.wait(_handlers);
  }
}
