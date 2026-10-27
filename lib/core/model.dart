import 'dart:convert';
import 'dart:io';

enum DownloadStatus { queued, downloading, paused, complete, failed }

class DownloadSegment {
  DownloadSegment(this.start, this.end, {this.received = 0});
  final int start;
  final int? end;
  int received;
  int? get length => end == null ? null : end! - start + 1;
  Map<String, dynamic> toJson() => {'start': start, 'end': end};
  factory DownloadSegment.fromJson(Map<String, dynamic> json) =>
      DownloadSegment(json['start'] as int, json['end'] as int?);
}

class DownloadTask {
  DownloadTask({
    required this.id,
    required this.url,
    required this.filename,
    required this.directory,
    this.description = '',
    this.connections = 8,
    DateTime? createdAt,
    this.status = DownloadStatus.queued,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  final String url;
  final String filename;
  final String directory;
  final String description;
  final int connections;
  final DateTime createdAt;
  DownloadStatus status;
  int? totalBytes;
  bool supportsResume = false;
  String? etag;
  String? lastModified;
  String? error;
  double speed = 0;
  List<DownloadSegment> segments = [];

  String get path => '$directory${Platform.pathSeparator}$filename';
  int get received => segments.fold(0, (n, segment) => n + segment.received);
  double? get progress => totalBytes == null
      ? null
      : totalBytes == 0
      ? (status == DownloadStatus.complete ? 1 : 0)
      : (received / totalBytes!).clamp(0, 1);
  Duration? get remaining => speed > 0 && totalBytes != null
      ? Duration(
          seconds: ((totalBytes! - received) / speed).ceil().clamp(0, 1 << 31),
        )
      : null;
  String get category {
    final extension = filename.split('.').last.toLowerCase();
    if ({'zip', '7z', 'rar', 'gz', 'xz', 'tar', 'bz2'}.contains(extension)) {
      return 'Compressed';
    }
    if ({'mp3', 'flac', 'wav', 'aac', 'ogg', 'm4a'}.contains(extension)) {
      return 'Music';
    }
    if ({'mp4', 'mkv', 'webm', 'mov', 'avi'}.contains(extension)) {
      return 'Video';
    }
    if ({
      'exe',
      'msi',
      'apk',
      'dmg',
      'deb',
      'rpm',
      'appimage',
    }.contains(extension)) {
      return 'Programs';
    }
    if ({
      'pdf',
      'txt',
      'doc',
      'docx',
      'csv',
      'epub',
      'odt',
    }.contains(extension)) {
      return 'Documents';
    }
    return 'Other';
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'url': url,
    'filename': filename,
    'directory': directory,
    'description': description,
    'connections': connections,
    'createdAt': createdAt.toIso8601String(),
    'status': status.name,
    'totalBytes': totalBytes,
    'supportsResume': supportsResume,
    'etag': etag,
    'lastModified': lastModified,
    'error': error,
    'segments': segments.map((s) => s.toJson()).toList(),
  };

  factory DownloadTask.fromJson(Map<String, dynamic> json) {
    final task = DownloadTask(
      id: json['id'] as String,
      url: json['url'] as String,
      filename: json['filename'] as String,
      directory: json['directory'] as String,
      description: json['description'] as String? ?? '',
      connections: json['connections'] as int,
      createdAt: DateTime.parse(json['createdAt'] as String),
      status: DownloadStatus.values.byName(json['status'] as String),
    );
    task.totalBytes = json['totalBytes'] as int?;
    task.supportsResume = json['supportsResume'] as bool? ?? false;
    task.etag = json['etag'] as String?;
    task.lastModified = json['lastModified'] as String?;
    task.error = json['error'] as String?;
    task.segments = (json['segments'] as List)
        .map((s) => DownloadSegment.fromJson(s as Map<String, dynamic>))
        .toList();
    return task;
  }
}

/// All user and server-derived filenames pass the same cross-platform rules.
String safeFilename(String value) {
  var name = value
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
      .replaceAll(RegExp(r'[. ]+$'), '')
      .trim();
  if (name.isEmpty || name == '.' || name == '..') name = 'download';
  if (RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
    caseSensitive: false,
  ).hasMatch(name)) {
    name = '_$name';
  }
  // Leave room for duplicate suffixes within common 255-byte filesystem limits.
  if (utf8.encode(name).length > 200) {
    final dot = name.lastIndexOf('.');
    final extension = dot > 0 && utf8.encode(name.substring(dot)).length < 30
        ? name.substring(dot)
        : '';
    final stem = extension.isEmpty ? name : name.substring(0, dot);
    final buffer = StringBuffer();
    var size = 0;
    for (final rune in stem.runes) {
      final character = String.fromCharCode(rune);
      size += utf8.encode(character).length;
      if (size > 170) break;
      buffer.write(character);
    }
    name = '$buffer$extension';
  }
  return name;
}
