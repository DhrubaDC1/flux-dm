import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'model.dart';

class DownloadException implements Exception {
  DownloadException(this.message, {this.retryable = false});
  final String message;
  final bool retryable;
  @override
  String toString() => message;
}

class _Run {
  final client = HttpClient()..autoUncompress = false;
  final finished = Completer<void>();
  bool cancelled = false;
  void cancel() {
    cancelled = true;
    client.close(force: true);
  }

  void check() {
    if (cancelled) throw DownloadException('Transfer stopped');
  }
}

class _Probe {
  _Probe(this.total, this.ranges, this.etag, this.modified);
  final int? total;
  final bool ranges;
  final String? etag;
  final String? modified;
  String? get validator =>
      etag != null && !etag!.startsWith('W/') ? etag : modified;
}

/// Shared foreground engine. Native background execution is a separate adapter.
class DownloadManager {
  DownloadManager._(this.stateDirectory, this._lock);
  final Directory stateDirectory;
  final RandomAccessFile _lock;
  final List<DownloadTask> _tasks = [];
  List<DownloadTask> get tasks => List.unmodifiable(_tasks);
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  final Map<String, _Run> _active = {};
  final Set<String> _eligible = {};
  final Set<String> _reservedPaths = {};
  static final Set<String> _openDirectories = {};
  Future<void> _saveTail = Future.value();
  int _maxConcurrent = 2;
  int _defaultConnections = 8;
  bool _queueRunning = false;
  bool _closing = false;
  bool _closed = false;
  bool _suspendPump = false;
  bool get queueRunning => _queueRunning;
  int get maxConcurrent => _maxConcurrent;
  set maxConcurrent(int value) {
    if (value < 1 || value > 16) {
      throw ArgumentError('Concurrent downloads must be 1–16');
    }
    _maxConcurrent = value;
    _emit();
    _pump();
  }

  int get defaultConnections => _defaultConnections;
  set defaultConnections(int value) {
    if (value < 1 || value > 32) {
      throw ArgumentError('Connections must be 1–32');
    }
    _defaultConnections = value;
    _emit();
  }

  Future<void> configure({
    required int maxConcurrent,
    required int connections,
  }) async {
    _checkOpen();
    if (maxConcurrent < 1 ||
        maxConcurrent > 16 ||
        connections < 1 ||
        connections > 32) {
      throw ArgumentError(
        'Choose 1–16 simultaneous files and 1–32 connections',
      );
    }
    _maxConcurrent = maxConcurrent;
    _defaultConnections = connections;
    await _save();
    _emit();
    _pump();
  }

  static Future<DownloadManager> open(Directory stateDirectory) async {
    await stateDirectory.create(recursive: true);
    final path = stateDirectory.absolute.path;
    if (!_openDirectories.add(path)) {
      throw StateError('Download database already open');
    }
    RandomAccessFile? lock;
    try {
      lock = await File('$path/manager.lock').open(mode: FileMode.append);
      await lock.lock(FileLock.exclusive);
      final manager = DownloadManager._(stateDirectory.absolute, lock);
      final manifest = File('$path/downloads.json');
      if (await manifest.exists()) {
        final data =
            jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
        if (data['version'] != 1) {
          throw StateError('Unsupported download database version');
        }
        manager._maxConcurrent = (data['maxConcurrent'] as int? ?? 2).clamp(
          1,
          16,
        );
        manager._defaultConnections = (data['defaultConnections'] as int? ?? 8)
            .clamp(1, 32);
        for (final json in data['tasks'] as List) {
          final task = DownloadTask.fromJson(json as Map<String, dynamic>);
          if (!RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(task.id) ||
              safeFilename(task.filename) != task.filename ||
              task.connections < 1 ||
              task.connections > 32) {
            throw const FormatException('Invalid task metadata');
          }
          if (task.status == DownloadStatus.downloading) {
            task.status = DownloadStatus.paused;
          }
          await manager._recover(task);
          if (task.status != DownloadStatus.complete &&
              await manager._matchesPublishedParts(task)) {
            // Recover a crash after publication but before the manifest commit.
            // Compare contents, not just sizes: an unrelated file must be safe.
            task.status = DownloadStatus.complete;
            task.error = null;
          }
          manager._tasks.add(task);
        }
      }
      await manager._save();
      return manager;
    } catch (_) {
      await lock?.close();
      _openDirectories.remove(path);
      rethrow;
    }
  }

  Directory _parts(DownloadTask task) =>
      Directory('${stateDirectory.path}/parts/${task.id}');
  File _part(DownloadTask task, int index) =>
      File('${_parts(task).path}/$index.part');

  Future<bool> _matchesPublishedParts(DownloadTask task) async {
    if (task.totalBytes == null ||
        task.received != task.totalBytes ||
        task.segments.any((s) => s.length == null || s.received != s.length)) {
      return false;
    }
    final file = File(task.path);
    if (!await file.exists() || await file.length() != task.totalBytes) {
      return false;
    }
    final published = await file.open();
    try {
      for (var i = 0; i < task.segments.length; i++) {
        await for (final bytes in _part(task, i).openRead()) {
          final actual = await published.read(bytes.length);
          if (actual.length != bytes.length) return false;
          for (var j = 0; j < bytes.length; j++) {
            if (actual[j] != bytes[j]) return false;
          }
        }
      }
      return true;
    } finally {
      await published.close();
    }
  }

  Future<void> _recover(DownloadTask task) async {
    if (task.status == DownloadStatus.complete) {
      final file = File(task.path);
      if (!await file.exists() ||
          (task.totalBytes != null && await file.length() != task.totalBytes)) {
        task.status = DownloadStatus.failed;
        task.error = 'Completed file is missing or its size changed';
      } else {
        task.segments = [
          DownloadSegment(
            0,
            task.totalBytes == null ? null : task.totalBytes! - 1,
            received: await file.length(),
          ),
        ];
      }
      return;
    }
    var next = 0;
    for (var i = 0; i < task.segments.length; i++) {
      final segment = task.segments[i];
      if (segment.start != next ||
          (segment.end != null && segment.end! < segment.start)) {
        throw const FormatException('Invalid segment layout');
      }
      next = (segment.end ?? -1) + 1;
      final file = _part(task, i);
      segment.received = await file.exists() ? await file.length() : 0;
      if (segment.length != null && segment.received > segment.length!) {
        await file.delete();
        segment.received = 0;
      }
    }
    if (task.segments.isNotEmpty &&
        task.totalBytes != null &&
        next != task.totalBytes) {
      throw const FormatException('Segment layout does not match file size');
    }
  }

  Future<DownloadTask> add(
    String url, {
    required String directory,
    String? filename,
    String description = '',
    bool start = true,
    int? connections,
  }) async {
    _checkOpen();
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw ArgumentError('Enter an HTTP or HTTPS URL');
    }
    if (uri.userInfo.isNotEmpty) {
      throw ArgumentError('Credentials in URLs are not supported yet');
    }
    if (directory.trim().isEmpty) {
      throw ArgumentError('Choose a destination folder');
    }
    final count = connections ?? defaultConnections;
    if (count < 1 || count > 32) {
      throw ArgumentError('Connections must be 1–32');
    }
    var name = filename?.trim();
    if (name == null || name.isEmpty) {
      name = uri.pathSegments.isEmpty || uri.pathSegments.last.isEmpty
          ? 'download'
          : uri.pathSegments.last;
    }
    name = safeFilename(name);
    final target = Directory(directory).absolute;
    var candidate = name;
    var suffix = 1;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot) : '';
    String destination() => '${target.path}${Platform.pathSeparator}$candidate';
    bool taken() =>
        FileSystemEntity.typeSync(destination(), followLinks: false) !=
            FileSystemEntityType.notFound ||
        _reservedPaths.contains(destination().toLowerCase()) ||
        _tasks.any((t) => t.path.toLowerCase() == destination().toLowerCase());
    while (taken()) {
      candidate = '$stem (${suffix++})$extension';
    }
    final reserved = destination().toLowerCase();
    _reservedPaths.add(reserved);
    try {
      await target.create(recursive: true);
      _checkOpen();
      final task = DownloadTask(
        id: '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}',
        url: uri.removeFragment().toString(),
        filename: candidate,
        directory: target.path,
        description: description,
        connections: count,
      );
      _tasks.add(task);
      try {
        await _save();
      } catch (_) {
        _tasks.remove(task);
        rethrow;
      }
      if (start) _eligible.add(task.id);
      _emit();
      _pump();
      return task;
    } finally {
      _reservedPaths.remove(reserved);
    }
  }

  DownloadTask _task(String id) => _tasks.firstWhere((task) => task.id == id);
  void _checkOpen() {
    if (_closing || _closed) throw StateError('Download manager is closed');
  }

  void _emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void _pump() {
    if (_closing || _closed || _suspendPump) return;
    for (final task in _tasks) {
      if (_active.length >= maxConcurrent) break;
      if (task.status != DownloadStatus.queued ||
          (!_eligible.contains(task.id) && !_queueRunning)) {
        continue;
      }
      _eligible.remove(task.id);
      final run = _Run();
      _active[task.id] = run;
      task.status = DownloadStatus.downloading;
      task.error = null;
      _emit();
      unawaited(_execute(task, run));
    }
  }

  Future<void> pause(String id) async {
    _checkOpen();
    await _pause(id);
  }

  Future<void> _pause(String id) async {
    final task = _task(id);
    _eligible.remove(id);
    final run = _active[id];
    if (run != null) {
      run.cancel();
      await run.finished.future;
    } else if (task.status == DownloadStatus.queued) {
      task.status = DownloadStatus.paused;
      await _save();
    }
    _emit();
  }

  Future<void> resume(String id) async {
    _checkOpen();
    final task = _task(id);
    if (task.status == DownloadStatus.complete || _active.containsKey(id)) {
      return;
    }
    task.status = DownloadStatus.queued;
    task.error = null;
    _eligible.add(id);
    await _save();
    _emit();
    _pump();
  }

  Future<void> remove(String id) async {
    _checkOpen();
    await _pause(id);
    final task = _task(id);
    _tasks.remove(task);
    await _save();
    if (await _parts(task).exists()) await _parts(task).delete(recursive: true);
    // Removing a history row never deletes a user's completed download.
    _emit();
  }

  Future<void> startQueue() async {
    _checkOpen();
    _queueRunning = true;
    for (final task in _tasks) {
      if (task.status == DownloadStatus.paused) {
        task.status = DownloadStatus.queued;
      }
    }
    await _save();
    _emit();
    _pump();
  }

  Future<void> stopQueue() => stopAll();

  Future<void> stopAll() async {
    _checkOpen();
    await _stopAll();
  }

  Future<void> _stopAll({bool includeQueued = true}) async {
    _queueRunning = false;
    _eligible.clear();
    _suspendPump = true;
    try {
      await Future.wait(
        _tasks
            .where(
              (t) =>
                  t.status == DownloadStatus.downloading ||
                  (includeQueued && t.status == DownloadStatus.queued),
            )
            .map((t) => _pause(t.id))
            .toList(),
      );
      await _save();
    } finally {
      _suspendPump = false;
    }
    _emit();
  }

  Future<void> _save() {
    final encoded = jsonEncode({
      'version': 1,
      'maxConcurrent': maxConcurrent,
      'defaultConnections': defaultConnections,
      'tasks': _tasks.map((t) => t.toJson()).toList(),
    });
    final operation = _saveTail.then((_) async {
      final temporary = File('${stateDirectory.path}/downloads.json.tmp');
      await temporary.writeAsString(encoded, flush: true);
      await temporary.rename('${stateDirectory.path}/downloads.json');
    });
    // A failed write is surfaced to its caller, without poisoning subsequent saves.
    _saveTail = operation.then<void>(
      (_) {},
      onError: (Object e, StackTrace s) {},
    );
    return operation;
  }

  Future<HttpClientResponse> _request(
    _Run run,
    DownloadTask task, {
    String? range,
    String? validator,
  }) async {
    run.check();
    final request = await run.client
        .getUrl(Uri.parse(task.url))
        .timeout(const Duration(seconds: 30));
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    request.headers.set(HttpHeaders.userAgentHeader, 'FluxDM/0.1');
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    if (validator != null) {
      request.headers.set(HttpHeaders.ifRangeHeader, validator);
    }
    final response = await request.close().timeout(const Duration(seconds: 30));
    run.check();
    return response;
  }

  Future<void> _discard(HttpClientResponse response) async {
    // Cancelling avoids consuming an entire large body from a non-range server.
    await response.listen((_) {}).cancel();
  }

  Future<_Probe> _probe(_Run run, DownloadTask task) async {
    final response = await _request(run, task, range: 'bytes=0-0');
    try {
      final etag = response.headers.value(HttpHeaders.etagHeader);
      final modified = response.headers.value(HttpHeaders.lastModifiedHeader);
      if (response.statusCode == 206) {
        final range = _parseRange(
          response.headers.value(HttpHeaders.contentRangeHeader),
        );
        if (range == null || range.$1 != 0 || range.$2 != 0) {
          throw DownloadException('Invalid Content-Range in server probe');
        }
        _checkEncoding(response);
        return _Probe(range.$3, true, etag, modified);
      }
      if (response.statusCode == 416 &&
          response.headers.value(HttpHeaders.contentRangeHeader) ==
              'bytes */0') {
        return _Probe(0, false, etag, modified);
      }
      if (response.statusCode != 200) _httpError(response.statusCode);
      _checkEncoding(response);
      return _Probe(
        response.contentLength < 0 ? null : response.contentLength,
        false,
        etag,
        modified,
      );
    } finally {
      await _discard(response);
    }
  }

  (int, int, int)? _parseRange(String? value) {
    final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(value ?? '');
    if (match == null) return null;
    final start = int.parse(match[1]!);
    final end = int.parse(match[2]!);
    final total = int.parse(match[3]!);
    if (start > end || end >= total) return null;
    return (start, end, total);
  }

  Never _httpError(int code) => throw DownloadException(
    'HTTP $code',
    retryable: code == 408 || code == 429 || code >= 500,
  );
  void _checkEncoding(HttpClientResponse response) {
    final encoding = response.headers.value(HttpHeaders.contentEncodingHeader);
    if (encoding != null && encoding.toLowerCase() != 'identity') {
      throw DownloadException(
        'Server sent an unexpected content encoding: $encoding',
      );
    }
  }

  Future<void> _prepare(DownloadTask task, _Run run, _Probe probe) async {
    final previousValidator = task.etag != null && !task.etag!.startsWith('W/')
        ? task.etag
        : task.lastModified;
    final reuse =
        task.segments.isNotEmpty &&
        probe.ranges &&
        task.supportsResume &&
        probe.total == task.totalBytes &&
        probe.validator != null &&
        previousValidator == probe.validator;
    if (!reuse) {
      if (await _parts(task).exists()) {
        await _parts(task).delete(recursive: true);
      }
      task.segments = [];
      if (probe.total != 0) {
        final count =
            probe.ranges && probe.validator != null && probe.total != null
            ? min(task.connections, max(1, probe.total! ~/ (256 * 1024)))
            : 1;
        for (var i = 0; i < count; i++) {
          task.segments.add(
            DownloadSegment(
              probe.total == null ? 0 : probe.total! * i ~/ count,
              probe.total == null ? null : probe.total! * (i + 1) ~/ count - 1,
            ),
          );
        }
      }
    } else {
      await _recover(task);
    }
    task.totalBytes = probe.total;
    task.supportsResume = probe.ranges && probe.validator != null;
    task.etag = probe.etag;
    task.lastModified = probe.modified;
    await _parts(task).create(recursive: true);
    run.check();
    // Commit layout and validators before writing any segment bytes.
    await _save();
    _emit();
  }

  Future<void> _transfer(
    DownloadTask task,
    int index,
    _Run run,
    _Probe probe,
  ) async {
    final segment = task.segments[index];
    if (segment.length != null && segment.received == segment.length) return;
    for (var attempt = 0; ; attempt++) {
      run.check();
      try {
        final start = segment.start + segment.received;
        final ranged = probe.ranges;
        final response = await _request(
          run,
          task,
          range: ranged ? 'bytes=$start-${segment.end}' : null,
          validator: ranged ? probe.validator : null,
        );
        RandomAccessFile? output;
        var subscribed = false;
        try {
          if (ranged) {
            if (response.statusCode != 206) {
              if (response.statusCode != 200) _httpError(response.statusCode);
              throw DownloadException(
                'Server stopped honoring ranges; resume to restart safely',
              );
            }
            final range = _parseRange(
              response.headers.value(HttpHeaders.contentRangeHeader),
            );
            if (range == null ||
                range.$1 != start ||
                range.$2 != segment.end ||
                range.$3 != task.totalBytes) {
              throw DownloadException(
                'Server returned a mismatched Content-Range',
              );
            }
          } else if (response.statusCode != 200) {
            _httpError(response.statusCode);
          }
          _checkEncoding(response);
          final responseEtag = response.headers.value(HttpHeaders.etagHeader);
          final responseModified = response.headers.value(
            HttpHeaders.lastModifiedHeader,
          );
          if ((probe.etag != null &&
                  responseEtag != null &&
                  responseEtag != probe.etag) ||
              (probe.etag == null &&
                  probe.modified != null &&
                  responseModified != null &&
                  responseModified != probe.modified)) {
            throw DownloadException(
              'Remote file changed during download; resume to restart safely',
            );
          }
          if (!ranged) {
            // A sequential response always starts from zero.
            segment.received = 0;
            if (task.totalBytes != null &&
                response.contentLength >= 0 &&
                response.contentLength != task.totalBytes) {
              throw DownloadException(
                'Remote file size changed during download',
              );
            }
          }
          final expected = ranged ? segment.end! - start + 1 : task.totalBytes;
          if (expected != null &&
              response.contentLength >= 0 &&
              response.contentLength != expected) {
            throw DownloadException(
              'Server returned a mismatched content length',
            );
          }
          output = await _part(
            task,
            index,
          ).open(mode: ranged ? FileMode.append : FileMode.write);
          var receivedNow = 0;
          subscribed = true;
          await for (final bytes in response.timeout(
            const Duration(seconds: 30),
          )) {
            run.check();
            receivedNow += bytes.length;
            if (expected != null && receivedNow > expected) {
              throw DownloadException('Response exceeded expected length');
            }
            await output.writeFrom(bytes);
            segment.received += bytes.length;
          }
          if (expected != null && receivedNow != expected) {
            throw DownloadException(
              'Connection ended before all bytes arrived',
              retryable: true,
            );
          }
          await output.flush();
          return;
        } finally {
          await output?.close();
          if (!subscribed) await _discard(response);
        }
      } catch (error) {
        run.check();
        final retryable =
            error is SocketException ||
            error is TimeoutException ||
            error is HttpException ||
            (error is DownloadException && error.retryable);
        if (!retryable || attempt >= 2) rethrow;
        // A server without a validator cannot safely append bytes from another request.
        if (!probe.ranges || probe.validator == null) {
          segment.received = 0;
          final file = _part(task, index);
          if (await file.exists()) await file.delete();
        }
        await Future<void>.delayed(
          Duration(milliseconds: 250 * (1 << attempt)),
        );
      }
    }
  }

  Future<void> _publish(DownloadTask task, _Run run) async {
    run.check();
    final staging = File(
      '${task.directory}${Platform.pathSeparator}.flux-${task.id}.assembling',
    );
    try {
      final output = await staging.open(mode: FileMode.write);
      try {
        for (var i = 0; i < task.segments.length; i++) {
          await for (final bytes in _part(task, i).openRead()) {
            run.check();
            await output.writeFrom(bytes);
          }
        }
        await output.flush();
      } finally {
        await output.close();
      }
      if (task.totalBytes != null &&
          await staging.length() != task.totalBytes) {
        throw DownloadException(
          'Assembled file size does not match expected size',
        );
      }
      run.check();
      // Exclusive reservation prevents overwriting an existing file or symlink.
      final target = File(task.path);
      await target.create(exclusive: true);
      try {
        await staging.rename(task.path);
      } catch (_) {
        await target.delete();
        rethrow;
      }
      task.totalBytes ??= await target.length();
      task.status = DownloadStatus.complete;
      task.speed = 0;
      await _save();
      if (await _parts(task).exists()) {
        await _parts(task).delete(recursive: true);
      }
    } finally {
      if (await staging.exists()) await staging.delete();
    }
  }

  Future<void> _execute(DownloadTask task, _Run run) async {
    var previous = task.received;
    final ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      task.speed = max(0, (task.received - previous) * 4).toDouble();
      previous = task.received;
      _emit();
    });
    try {
      final probe = await _probe(run, task);
      await _prepare(task, run, probe);
      await Future.wait(
        List.generate(
          task.segments.length,
          (index) => _transfer(task, index, run, probe),
        ),
      );
      await _publish(task, run);
    } catch (error) {
      if (task.status != DownloadStatus.complete) {
        task.status = run.cancelled
            ? DownloadStatus.paused
            : DownloadStatus.failed;
        task.error = run.cancelled ? null : error.toString();
      }
      try {
        await _save();
      } catch (writeError) {
        task.error = 'Could not save download state: $writeError';
      }
    } finally {
      ticker.cancel();
      task.speed = 0;
      run.client.close(force: true);
      _active.remove(task.id);
      _emit();
      run.finished.complete();
      _pump();
    }
  }

  Future<void> close() async {
    if (_closed || _closing) return;
    _closing = true;
    try {
      await _stopAll(includeQueued: false);
      await _saveTail;
    } finally {
      _closed = true;
      _openDirectories.remove(stateDirectory.path);
      await _lock.close();
      await _changes.close();
    }
  }
}
