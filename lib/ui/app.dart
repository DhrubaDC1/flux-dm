import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/manager.dart';
import '../core/model.dart';
import 'dialogs.dart';
import 'format.dart';

class FluxApp extends StatelessWidget {
  const FluxApp({
    super.key,
    required this.manager,
    required this.defaultDirectory,
  });
  final DownloadManager manager;
  final String defaultDirectory;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Flux Download Manager',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: false,
      brightness: Brightness.light,
      primaryColor: const Color(0xff28659c),
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff28659c)),
      scaffoldBackgroundColor: Colors.white,
      visualDensity: VisualDensity.compact,
      textTheme: const TextTheme(
        bodyMedium: TextStyle(fontSize: 13),
        bodySmall: TextStyle(fontSize: 12),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        isDense: true,
      ),
      dividerColor: const Color(0xffd6dbe1),
      dialogTheme: const DialogThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
        ),
      ),
      tooltipTheme: const TooltipThemeData(
        waitDuration: Duration(milliseconds: 500),
      ),
    ),
    home: DownloadWindow(manager: manager, defaultDirectory: defaultDirectory),
  );
}

class DownloadWindow extends StatefulWidget {
  const DownloadWindow({
    super.key,
    required this.manager,
    required this.defaultDirectory,
  });
  final DownloadManager manager;
  final String defaultDirectory;

  @override
  State<DownloadWindow> createState() => _DownloadWindowState();
}

class _DownloadWindowState extends State<DownloadWindow>
    with WidgetsBindingObserver {
  StreamSubscription<void>? _subscription;
  late final AppLifecycleListener _lifecycleListener;
  String? _selection;
  String _filter = 'All downloads';
  String _search = '';
  int _sortColumn = 5;
  bool _ascending = false;
  final _searchController = TextEditingController();

  DownloadManager get manager => widget.manager;
  DownloadTask? get selected {
    for (final task in manager.tasks) {
      if (task.id == _selection) return task;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lifecycleListener = AppLifecycleListener(
      onExitRequested: () async {
        await manager.close();
        return AppExitResponse.exit;
      },
    );
    _subscription = manager.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) unawaited(manager.close());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lifecycleListener.dispose();
    _subscription?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _perform(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> _add() =>
      showAddDownload(context, manager, widget.defaultDirectory);

  Future<void> _delete() async {
    final task = selected;
    if (task == null || task.status == DownloadStatus.downloading) return;
    if (task.status != DownloadStatus.complete) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Delete download?'),
          content: Text(
            'Remove "${task.filename}" from the list and discard its unfinished download data?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await _perform(() => manager.remove(task.id));
    if (mounted) setState(() => _selection = null);
  }

  Future<void> _deleteCompleted() => _perform(() async {
    for (final task
        in manager.tasks
            .where((task) => task.status == DownloadStatus.complete)
            .toList()) {
      await manager.remove(task.id);
    }
  });

  Future<void> _options() async {
    var concurrent = manager.maxConcurrent;
    var connections = manager.defaultConnections;
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Options'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Connection',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<int>(
                  initialValue: concurrent,
                  decoration: const InputDecoration(
                    labelText: 'Simultaneous downloads',
                  ),
                  items: List.generate(
                    16,
                    (i) =>
                        DropdownMenuItem(value: i + 1, child: Text('${i + 1}')),
                  ),
                  onChanged: (value) =>
                      setDialogState(() => concurrent = value!),
                ),
                const SizedBox(height: 18),
                DropdownButtonFormField<int>(
                  initialValue: connections,
                  decoration: const InputDecoration(
                    labelText: 'Default connections per download',
                  ),
                  items: List.generate(32, (index) => index + 1)
                      .map(
                        (value) => DropdownMenuItem(
                          value: value,
                          child: Text('$value'),
                        ),
                      )
                      .toList(),
                  onChanged: (value) =>
                      setDialogState(() => connections = value!),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Connection settings apply to new downloads. Existing downloads retain their segment layout.',
                  style: TextStyle(color: Color(0xff606770), fontSize: 12),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (save == true) {
      await _perform(() async {
        await manager.configure(
          maxConcurrent: concurrent,
          connections: connections,
        );
      });
      if (mounted) setState(() {});
    }
  }

  Future<void> _queues() => showDialog<void>(
    context: context,
    builder: (context) => StreamBuilder<void>(
      stream: manager.changes,
      builder: (context, _) => AlertDialog(
        title: const Text('Main download queue'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                manager.queueRunning ? 'Queue is running' : 'Queue is stopped',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              Text(
                '${manager.tasks.where((task) => task.status == DownloadStatus.queued).length} waiting · ${manager.tasks.where((task) => task.status == DownloadStatus.downloading).length} downloading',
              ),
              const SizedBox(height: 8),
              Text('Download up to ${manager.maxConcurrent} files at a time.'),
              const SizedBox(height: 18),
              const Text(
                'Use Download later to add files to this queue. Start queue begins waiting downloads; Stop queue pauses its transfers.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => _perform(manager.startQueue),
            child: const Text('Start now'),
          ),
          TextButton(
            onPressed: () => _perform(manager.stopQueue),
            child: const Text('Stop queue'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    ),
  );

  List<DownloadTask> get visibleTasks {
    final result = manager.tasks.where((task) {
      final included = switch (_filter) {
        'All downloads' => true,
        'Unfinished' => task.status != DownloadStatus.complete,
        'Finished' => task.status == DownloadStatus.complete,
        'Main download queue' =>
          task.status == DownloadStatus.queued ||
              task.status == DownloadStatus.downloading,
        _ => task.category == _filter,
      };
      return included &&
          '${task.filename} ${task.description} ${task.url}'
              .toLowerCase()
              .contains(_search.toLowerCase());
    }).toList();
    result.sort((a, b) {
      final order = switch (_sortColumn) {
        0 => a.filename.toLowerCase().compareTo(b.filename.toLowerCase()),
        1 => (a.totalBytes ?? -1).compareTo(b.totalBytes ?? -1),
        2 => a.status.index.compareTo(b.status.index),
        3 => (a.remaining?.inSeconds ?? -1).compareTo(
          b.remaining?.inSeconds ?? -1,
        ),
        4 => a.speed.compareTo(b.speed),
        5 => a.createdAt.compareTo(b.createdAt),
        _ => a.description.compareTo(b.description),
      };
      return _ascending ? order : -order;
    });
    return result;
  }

  void _setFilter(String filter, {bool closeDrawer = false}) {
    setState(() {
      _filter = filter;
      _selection = null;
    });
    if (closeDrawer) Navigator.pop(context);
  }

  Widget _categories({bool inDrawer = false}) => Container(
    width: 208,
    color: const Color(0xfff7f9fb),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 18, 12, 10),
          child: Text(
            'Categories',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: Color(0xff44515f),
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 4),
            children: [
              for (final entry in [
                ('All downloads', Icons.folder_copy_outlined),
                ('Unfinished', Icons.downloading_outlined),
                ('Finished', Icons.task_alt),
                ('Compressed', Icons.folder_zip_outlined),
                ('Documents', Icons.description_outlined),
                ('Music', Icons.music_note_outlined),
                ('Programs', Icons.apps_outlined),
                ('Video', Icons.movie_outlined),
              ])
                _category(entry.$1, entry.$2, closeDrawer: inDrawer),
              const Divider(indent: 12, endIndent: 12, height: 28),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 12, 6),
                child: Text(
                  'Queues',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Color(0xff44515f),
                  ),
                ),
              ),
              _category(
                'Main download queue',
                Icons.queue,
                closeDrawer: inDrawer,
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _category(String name, IconData icon, {required bool closeDrawer}) =>
      Material(
        color: _filter == name ? const Color(0xffdceafb) : Colors.transparent,
        child: InkWell(
          onTap: () => _setFilter(name, closeDrawer: closeDrawer),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 19,
                  color: _filter == name
                      ? const Color(0xff28659c)
                      : const Color(0xff6c7c8f),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    name,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: _filter == name
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  Widget _menuBar() => Container(
    height: 32,
    color: const Color(0xfff7f9fb),
    padding: const EdgeInsets.symmetric(horizontal: 6),
    child: Row(
      children: [
        PopupMenuButton<String>(
          tooltip: 'Tasks',
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Text('Tasks'),
          ),
          onSelected: (action) {
            switch (action) {
              case 'add':
                _add();
              case 'delete':
                _delete();
              case 'clear':
                _deleteCompleted();
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(
              value: 'add',
              child: Text('Add new download…    Ctrl+N'),
            ),
            PopupMenuItem(
              value: 'delete',
              enabled:
                  selected != null &&
                  selected!.status != DownloadStatus.downloading,
              child: const Text('Delete selected'),
            ),
            PopupMenuItem(
              value: 'clear',
              enabled: manager.tasks.any(
                (task) => task.status == DownloadStatus.complete,
              ),
              child: const Text('Delete completed'),
            ),
          ],
        ),
        PopupMenuButton<String>(
          tooltip: 'Downloads',
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Text('Downloads'),
          ),
          onSelected: (action) {
            switch (action) {
              case 'resume':
                _perform(() => manager.resume(selected!.id));
              case 'stop':
                _perform(() => manager.pause(selected!.id));
              case 'all':
                _perform(manager.stopAll);
              case 'startQueue':
                _perform(manager.startQueue);
              case 'stopQueue':
                _perform(manager.stopQueue);
              case 'options':
                _options();
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'resume',
              enabled: _canResume,
              child: const Text('Resume download'),
            ),
            PopupMenuItem(
              value: 'stop',
              enabled: _canStop,
              child: const Text('Stop download'),
            ),
            const PopupMenuItem(
              value: 'all',
              child: Text('Stop all downloads'),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem(
              value: 'startQueue',
              child: Text('Start queue'),
            ),
            const PopupMenuItem(value: 'stopQueue', child: Text('Stop queue')),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'options', child: Text('Options…')),
          ],
        ),
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: Colors.black87,
            textStyle: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.normal,
            ),
          ),
          onPressed: () => showAboutDialog(
            context: context,
            applicationName: 'Flux Download Manager',
            applicationVersion: '0.1.0',
            applicationIcon: const Icon(
              Icons.download,
              size: 40,
              color: Color(0xff28659c),
            ),
            children: [
              const Text(
                'An open-source, cross-platform download manager. Core milestone: HTTP downloads, persistent transfers, pause/resume and a main download queue.',
              ),
            ],
          ),
          child: const Text('Help'),
        ),
      ],
    ),
  );

  bool get _canResume =>
      selected != null &&
      selected!.status != DownloadStatus.complete &&
      selected!.status != DownloadStatus.downloading;
  bool get _canStop =>
      selected?.status == DownloadStatus.downloading ||
      selected?.status == DownloadStatus.queued;

  Widget _toolbar() => Container(
    height: 80,
    decoration: const BoxDecoration(
      color: Color(0xfff2f5f8),
      border: Border(bottom: BorderSide(color: Color(0xffced5dd))),
    ),
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
      child: Row(
        children: [
          _Tool('Add URL', Icons.add_link, const Color(0xff3579b6), _add),
          _Tool(
            'Resume',
            Icons.play_circle_fill,
            const Color(0xff37a04e),
            _canResume
                ? () => _perform(() => manager.resume(selected!.id))
                : null,
          ),
          _Tool(
            'Stop',
            Icons.stop_circle,
            const Color(0xffd75a47),
            _canStop ? () => _perform(() => manager.pause(selected!.id)) : null,
          ),
          _Tool(
            'Stop all',
            Icons.pause_circle_filled,
            const Color(0xffca423b),
            manager.tasks.any(
                  (task) =>
                      task.status == DownloadStatus.downloading ||
                      task.status == DownloadStatus.queued,
                )
                ? () => _perform(manager.stopAll)
                : null,
          ),
          const VerticalDivider(indent: 5, endIndent: 5, width: 16),
          _Tool(
            'Delete',
            Icons.delete_outline,
            const Color(0xff71819b),
            selected != null && selected!.status != DownloadStatus.downloading
                ? _delete
                : null,
          ),
          _Tool(
            'Delete completed',
            Icons.playlist_remove,
            const Color(0xff71819b),
            manager.tasks.any((task) => task.status == DownloadStatus.complete)
                ? _deleteCompleted
                : null,
          ),
          const VerticalDivider(indent: 5, endIndent: 5, width: 16),
          _Tool(
            'Options',
            Icons.settings_outlined,
            const Color(0xff748594),
            _options,
          ),
          _Tool(
            'Queues',
            Icons.view_list_outlined,
            const Color(0xff7b70ab),
            _queues,
          ),
          _Tool(
            'Start queue',
            Icons.playlist_play,
            const Color(0xffbb9540),
            () => _perform(manager.startQueue),
          ),
          _Tool(
            'Stop queue',
            Icons.playlist_remove,
            const Color(0xffbd7750),
            () => _perform(manager.stopQueue),
          ),
        ],
      ),
    ),
  );

  Widget _empty() => Center(
    child: Padding(
      padding: const EdgeInsets.all(30),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.download_outlined,
            size: 46,
            color: Color(0xffaebdcb),
          ),
          const SizedBox(height: 14),
          Text(
            _search.isEmpty
                ? 'No downloads in this view'
                : 'No matching downloads',
            style: const TextStyle(fontSize: 16, color: Color(0xff4d5c6a)),
          ),
          const SizedBox(height: 8),
          const Text(
            'Add a URL to start downloading, or save it to the queue.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xff798897)),
          ),
          const SizedBox(height: 18),
          OutlinedButton.icon(
            onPressed: _add,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add URL'),
          ),
        ],
      ),
    ),
  );

  Widget _desktopList(List<DownloadTask> tasks) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: constraints.maxWidth > 1270 ? constraints.maxWidth : 1270,
              child: Column(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      child: SizedBox(
                        width: double.infinity,
                        child: DataTable(
                          headingRowHeight: 36,
                          dataRowMinHeight: 38,
                          dataRowMaxHeight: 38,
                          columnSpacing: 18,
                          horizontalMargin: 14,
                          showCheckboxColumn: false,
                          sortColumnIndex: _sortColumn,
                          sortAscending: _ascending,
                          headingRowColor: const WidgetStatePropertyAll(
                            Color(0xfff4f6f8),
                          ),
                          headingTextStyle: const TextStyle(
                            fontSize: 12,
                            color: Color(0xff44515f),
                            fontWeight: FontWeight.w600,
                          ),
                          dataTextStyle: const TextStyle(
                            fontSize: 12,
                            color: Color(0xff303a45),
                          ),
                          columns: [
                            for (final (index, label) in [
                              'File name',
                              'Size',
                              'Status',
                              'Time left',
                              'Transfer rate',
                              'Date added',
                              'Description',
                            ].indexed)
                              DataColumn(
                                columnWidth: FixedColumnWidth(
                                  const [
                                    270.0,
                                    110.0,
                                    170.0,
                                    140.0,
                                    170.0,
                                    180.0,
                                    230.0,
                                  ][index],
                                ),
                                label: Flexible(
                                  child: Text(
                                    label,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                onSort: (column, ascending) => setState(() {
                                  _sortColumn = column;
                                  _ascending = ascending;
                                }),
                              ),
                          ],
                          rows: tasks
                              .map(
                                (task) => DataRow(
                                  key: ValueKey(task.id),
                                  selected: _selection == task.id,
                                  onSelectChanged: (_) =>
                                      setState(() => _selection = task.id),
                                  onLongPress: () => showDownloadDetails(
                                    context,
                                    manager,
                                    task,
                                  ),
                                  cells: [
                                    DataCell(
                                      SizedBox(
                                        width: 220,
                                        child: Row(
                                          children: [
                                            Icon(
                                              _fileIcon(task.category),
                                              size: 17,
                                              color: const Color(0xff5883a8),
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                task.filename,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      onTap: () =>
                                          setState(() => _selection = task.id),
                                      onTapDown: (_) =>
                                          setState(() => _selection = task.id),
                                      onDoubleTap: () => showDownloadDetails(
                                        context,
                                        manager,
                                        task,
                                      ),
                                    ),
                                    DataCell(
                                      Text(formatBytes(task.totalBytes)),
                                    ),
                                    DataCell(
                                      SizedBox(
                                        width: 120,
                                        child: _status(task),
                                      ),
                                    ),
                                    DataCell(
                                      Text(formatRemaining(task.remaining)),
                                    ),
                                    DataCell(
                                      Text(
                                        task.status ==
                                                DownloadStatus.downloading
                                            ? '${formatBytes(task.speed)}/sec'
                                            : '—',
                                      ),
                                    ),
                                    DataCell(Text(formatDate(task.createdAt))),
                                    DataCell(
                                      SizedBox(
                                        width: 170,
                                        child: Text(
                                          task.description,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              )
                              .toList(),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      if (selected != null && tasks.any((task) => task.id == _selection))
        _selectionBar(selected!),
    ],
  );

  Widget _status(DownloadTask task) => Row(
    children: [
      if (task.status == DownloadStatus.complete)
        const Icon(Icons.check_circle, color: Color(0xff2f9648), size: 14),
      if (task.status == DownloadStatus.failed)
        const Icon(Icons.error_outline, color: Color(0xffce5146), size: 14),
      if (task.status == DownloadStatus.complete ||
          task.status == DownloadStatus.failed)
        const SizedBox(width: 5),
      Expanded(
        child: Text(
          task.status == DownloadStatus.downloading && task.progress != null
              ? '${(task.progress! * 100).toStringAsFixed(1)}%'
              : statusLabel(task.status),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ],
  );

  Widget _selectionBar(DownloadTask task) => Container(
    decoration: const BoxDecoration(
      color: Color(0xfff7f9fb),
      border: Border(top: BorderSide(color: Color(0xffd6dbe1))),
    ),
    padding: const EdgeInsets.all(12),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                task.filename,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 5),
              if (task.error != null)
                Text(
                  task.error!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xffb44138),
                    fontSize: 12,
                  ),
                )
              else
                Text(
                  '${formatBytes(task.received)} of ${formatBytes(task.totalBytes)} · ${statusLabel(task.status)}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xff657585),
                  ),
                ),
              const SizedBox(height: 7),
              LinearProgressIndicator(value: taskProgress(task), minHeight: 4),
            ],
          ),
        ),
        const SizedBox(width: 16),
        OutlinedButton(
          onPressed: () => showDownloadDetails(context, manager, task),
          child: const Text('Details'),
        ),
      ],
    ),
  );

  Widget _mobileList(List<DownloadTask> tasks) => ListView.separated(
    itemCount: tasks.length,
    separatorBuilder: (_, _) => const Divider(height: 1),
    itemBuilder: (context, index) {
      final task = tasks[index];
      return ListTile(
        selected: _selection == task.id,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Icon(_fileIcon(task.category), color: const Color(0xff5883a8)),
        title: Text(
          task.filename,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 5),
            Text(
              '${statusLabel(task.status)} · ${formatBytes(task.received)} / ${formatBytes(task.totalBytes)}',
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: taskProgress(task), minHeight: 3),
            if (task.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  task.error!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xffb44138),
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
        trailing: IconButton(
          tooltip: task.status == DownloadStatus.downloading
              ? 'Pause'
              : 'Details',
          icon: Icon(
            task.status == DownloadStatus.downloading
                ? Icons.pause
                : Icons.info_outline,
          ),
          onPressed: () {
            setState(() => _selection = task.id);
            if (task.status == DownloadStatus.downloading) {
              _perform(() => manager.pause(task.id));
            } else {
              showDownloadDetails(context, manager, task);
            }
          },
        ),
        onTap: () {
          setState(() => _selection = task.id);
          showDownloadDetails(context, manager, task);
        },
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final tasks = visibleTasks;
    final mobile = MediaQuery.sizeOf(context).width < 720;
    final active = manager.tasks
        .where((task) => task.status == DownloadStatus.downloading)
        .length;
    final speed = manager.tasks.fold<double>(
      0,
      (sum, task) => sum + task.speed,
    );
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.keyN, control: true): _AddIntent(),
        SingleActivator(LogicalKeyboardKey.keyN, meta: true): _AddIntent(),
        SingleActivator(LogicalKeyboardKey.delete): _DeleteIntent(),
      },
      child: Actions(
        actions: {
          _AddIntent: CallbackAction<_AddIntent>(
            onInvoke: (_) {
              _add();
              return null;
            },
          ),
          _DeleteIntent: CallbackAction<_DeleteIntent>(
            onInvoke: (_) {
              _delete();
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            appBar: mobile
                ? AppBar(
                    title: const Text(
                      'Flux Download Manager',
                      style: TextStyle(fontSize: 17),
                    ),
                    backgroundColor: const Color(0xff28659c),
                    actions: [
                      IconButton(
                        tooltip: 'Options',
                        onPressed: _options,
                        icon: const Icon(Icons.settings_outlined),
                      ),
                      IconButton(
                        tooltip: 'Queues',
                        onPressed: _queues,
                        icon: const Icon(Icons.queue),
                      ),
                    ],
                  )
                : null,
            drawer: mobile
                ? Drawer(child: SafeArea(child: _categories(inDrawer: true)))
                : null,
            floatingActionButton: mobile
                ? FloatingActionButton(
                    onPressed: _add,
                    tooltip: 'Add URL',
                    child: const Icon(Icons.add),
                  )
                : null,
            body: SafeArea(
              child: Column(
                children: [
                  if (!mobile) _menuBar(),
                  if (!mobile) _toolbar(),
                  Expanded(
                    child: Row(
                      children: [
                        if (!mobile) _categories(),
                        if (!mobile) const VerticalDivider(width: 1),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 10,
                                ),
                                child: Row(
                                  children: [
                                    if (!mobile) ...[
                                      Text(
                                        _filter,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const Spacer(),
                                    ],
                                    SizedBox(
                                      width: mobile
                                          ? MediaQuery.sizeOf(context).width -
                                                32
                                          : 240,
                                      child: TextField(
                                        controller: _searchController,
                                        style: const TextStyle(fontSize: 12),
                                        decoration: InputDecoration(
                                          hintText: 'Search downloads',
                                          prefixIcon: const Icon(
                                            Icons.search,
                                            size: 18,
                                          ),
                                          suffixIcon: _search.isEmpty
                                              ? null
                                              : IconButton(
                                                  tooltip: 'Clear search',
                                                  onPressed: () {
                                                    _searchController.clear();
                                                    setState(
                                                      () => _search = '',
                                                    );
                                                  },
                                                  icon: const Icon(
                                                    Icons.close,
                                                    size: 16,
                                                  ),
                                                ),
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                                vertical: 10,
                                                horizontal: 12,
                                              ),
                                        ),
                                        onChanged: (value) =>
                                            setState(() => _search = value),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const Divider(height: 1),
                              Expanded(
                                child: mobile
                                    ? (tasks.isEmpty
                                          ? _empty()
                                          : _mobileList(tasks))
                                    : Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          _desktopList(tasks),
                                          if (tasks.isEmpty)
                                            Positioned.fill(
                                              top: 36,
                                              child: _empty(),
                                            ),
                                        ],
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    height: 28,
                    decoration: const BoxDecoration(
                      color: Color(0xfff2f5f8),
                      border: Border(top: BorderSide(color: Color(0xffced5dd))),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        Text(
                          '${tasks.length} download${tasks.length == 1 ? '' : 's'}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xff5a6878),
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '$active active · ${formatBytes(speed)}/sec',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xff5a6878),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

IconData _fileIcon(String category) => switch (category) {
  'Compressed' => Icons.folder_zip_outlined,
  'Documents' => Icons.description_outlined,
  'Music' => Icons.music_note_outlined,
  'Programs' => Icons.apps,
  'Video' => Icons.movie_outlined,
  _ => Icons.insert_drive_file_outlined,
};

class _Tool extends StatelessWidget {
  const _Tool(this.label, this.icon, this.color, this.onTap);
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    child: SizedBox(
      width: label.length > 13 ? 112 : 76,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(5),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 29,
                  color: onTap == null ? const Color(0xffb7c0c8) : color,
                ),
                const SizedBox(height: 5),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    color: onTap == null
                        ? const Color(0xff909ba5)
                        : const Color(0xff344352),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _AddIntent extends Intent {
  const _AddIntent();
}

class _DeleteIntent extends Intent {
  const _DeleteIntent();
}
