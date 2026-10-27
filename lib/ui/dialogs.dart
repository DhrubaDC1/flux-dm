import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../core/manager.dart';
import '../core/model.dart';
import 'format.dart';

Future<void> showAddDownload(
  BuildContext context,
  DownloadManager manager,
  String defaultDirectory,
) async {
  final url = await showDialog<String>(
    context: context,
    builder: (context) => const _UrlDialog(),
  );
  if (url == null || !context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => _SaveDialog(
      manager: manager,
      url: url,
      defaultDirectory: defaultDirectory,
    ),
  );
}

class _UrlDialog extends StatefulWidget {
  const _UrlDialog();

  @override
  State<_UrlDialog> createState() => _UrlDialogState();
}

class _UrlDialogState extends State<_UrlDialog> {
  final _controller = TextEditingController();
  final _form = GlobalKey<FormState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_form.currentState!.validate()) {
      Navigator.pop(context, _controller.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add URL'),
    content: SizedBox(
      width: 560,
      child: Form(
        key: _form,
        child: TextFormField(
          key: const Key('download-url'),
          controller: _controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Address',
            hintText: 'https://example.com/file.zip',
          ),
          validator: (value) {
            final uri = Uri.tryParse(value?.trim() ?? '');
            if (uri == null ||
                !['http', 'https'].contains(uri.scheme) ||
                uri.host.isEmpty) {
              return 'Enter a complete HTTP or HTTPS download URL.';
            }
            return null;
          },
          onFieldSubmitted: (_) => _submit(),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      ElevatedButton(onPressed: _submit, child: const Text('Next')),
    ],
  );
}

class _SaveDialog extends StatefulWidget {
  const _SaveDialog({
    required this.manager,
    required this.url,
    required this.defaultDirectory,
  });

  final DownloadManager manager;
  final String url;
  final String defaultDirectory;

  @override
  State<_SaveDialog> createState() => _SaveDialogState();
}

class _SaveDialogState extends State<_SaveDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _filename;
  late final TextEditingController _directory;
  final _description = TextEditingController();
  late int _connections;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final uri = Uri.parse(widget.url);
    _filename = TextEditingController(
      text: uri.pathSegments.isEmpty ? '' : safeFilename(uri.pathSegments.last),
    );
    _directory = TextEditingController(text: widget.defaultDirectory);
    _connections = widget.manager.defaultConnections;
  }

  @override
  void dispose() {
    _filename.dispose();
    _directory.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _chooseFolder() async {
    try {
      final path = await getDirectoryPath(initialDirectory: _directory.text);
      if (path != null && mounted) setState(() => _directory.text = path);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Folder selection is unavailable here. Use the app download folder or enter a writable path.',
        );
      }
    }
  }

  Future<void> _save(bool start) async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.manager.add(
        widget.url,
        directory: _directory.text.trim(),
        filename: _filename.text.trim().isEmpty ? null : _filename.text.trim(),
        description: _description.text.trim(),
        connections: _connections,
        start: start,
      );
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Download file information'),
    content: SizedBox(
      width: 600,
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SelectableText(widget.url, style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 20),
              TextFormField(
                key: const Key('download-filename'),
                controller: _filename,
                decoration: const InputDecoration(
                  labelText: 'File name',
                  hintText: 'Use the name from the download URL',
                ),
                validator: (value) {
                  if (value != null &&
                      (value.contains(RegExp(r'[\\/:*?"<>|]')) ||
                          value == '.' ||
                          value == '..')) {
                    return 'Enter a file name without path separators.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextFormField(
                      key: const Key('download-directory'),
                      controller: _directory,
                      decoration: const InputDecoration(labelText: 'Save to'),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? 'Choose a download folder.'
                          : null,
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    tooltip: 'Choose folder',
                    onPressed: _busy ? null : _chooseFolder,
                    icon: const Icon(Icons.folder_open),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _description,
                decoration: const InputDecoration(labelText: 'Description'),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<int>(
                initialValue: _connections,
                decoration: const InputDecoration(labelText: 'Connections'),
                items: List.generate(32, (index) => index + 1)
                    .map(
                      (value) =>
                          DropdownMenuItem(value: value, child: Text('$value')),
                    )
                    .toList(),
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _connections = value!),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      OutlinedButton(
        onPressed: _busy ? null : () => _save(false),
        child: const Text('Download later'),
      ),
      ElevatedButton(
        key: const Key('start-download'),
        onPressed: _busy ? null : () => _save(true),
        child: Text(_busy ? 'Adding…' : 'Start download'),
      ),
    ],
  );
}

Future<void> showDownloadDetails(
  BuildContext context,
  DownloadManager manager,
  DownloadTask task,
) => showDialog<void>(
  context: context,
  builder: (context) => StreamBuilder<void>(
    stream: manager.changes,
    builder: (context, _) => AlertDialog(
      title: Text(task.filename),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _Detail('URL', task.url),
              _Detail('Status', statusLabel(task.status)),
              _Detail('Size', formatBytes(task.totalBytes)),
              _Detail(
                'Resume capability',
                task.segments.isEmpty
                    ? 'Not yet checked'
                    : task.supportsResume
                    ? 'Yes'
                    : 'Not available',
              ),
              _Detail('Downloaded', formatBytes(task.received)),
              _Detail('Transfer rate', '${formatBytes(task.speed)}/sec'),
              _Detail('Time left', formatRemaining(task.remaining)),
              _Detail('Save to', task.path),
              if (task.description.isNotEmpty)
                _Detail('Description', task.description),
              const SizedBox(height: 14),
              LinearProgressIndicator(value: taskProgress(task), minHeight: 12),
              const SizedBox(height: 18),
              const Text(
                'Download segments',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              if (task.segments.isEmpty)
                const Text('Segments appear when the transfer starts.'),
              for (var i = 0; i < task.segments.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      SizedBox(width: 26, child: Text('${i + 1}')),
                      Expanded(
                        child: LinearProgressIndicator(
                          value: task.segments[i].end == null
                              ? (task.status == DownloadStatus.downloading
                                    ? null
                                    : 0)
                              : (task.segments[i].received /
                                        (task.segments[i].end! -
                                            task.segments[i].start +
                                            1))
                                    .clamp(0, 1),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 95,
                        child: Text(
                          formatBytes(task.segments[i].received),
                          textAlign: TextAlign.end,
                        ),
                      ),
                    ],
                  ),
                ),
              if (task.error != null) ...[
                const SizedBox(height: 16),
                Text(
                  task.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (task.status == DownloadStatus.downloading)
          TextButton(
            onPressed: () => _runAction(context, () => manager.pause(task.id)),
            child: const Text('Pause'),
          ),
        if (task.status == DownloadStatus.paused ||
            task.status == DownloadStatus.failed ||
            task.status == DownloadStatus.queued)
          TextButton(
            onPressed: () => _runAction(context, () => manager.resume(task.id)),
            child: const Text('Resume'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  ),
);

class _Detail extends StatelessWidget {
  const _Detail(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 110,
          child: Text(
            '$label:',
            style: const TextStyle(color: Color(0xff606770)),
          ),
        ),
        Expanded(child: SelectableText(value)),
      ],
    ),
  );
}

String statusLabel(DownloadStatus status) => switch (status) {
  DownloadStatus.queued => 'Queued',
  DownloadStatus.downloading => 'Downloading',
  DownloadStatus.paused => 'Paused',
  DownloadStatus.complete => 'Complete',
  DownloadStatus.failed => 'Error',
};

/// Waiting and paused downloads do not animate an indeterminate progress bar.
double? taskProgress(DownloadTask task) =>
    task.progress ?? (task.status == DownloadStatus.downloading ? null : 0);

Future<void> _runAction(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }
}
