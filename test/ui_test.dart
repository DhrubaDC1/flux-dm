import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flux_dm/core/manager.dart';
import 'package:flux_dm/core/model.dart';
import 'package:flux_dm/ui/app.dart';

void main() {
  late Directory directory;
  late DownloadManager manager;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('flux-ui-');
    manager = await DownloadManager.open(Directory('${directory.path}/state'));
  });

  tearDown(() async {
    await manager.close();
    await directory.delete(recursive: true);
  });

  Future<void> mount(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      FluxApp(manager: manager, defaultDirectory: directory.path),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Add URL validates then saves a real queued task', (
    tester,
  ) async {
    await mount(tester, const Size(1280, 800));
    expect(find.text('File name'), findsOneWidget);
    await tester.tap(find.text('Add URL').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('download-url')), 'not a URL');
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(
      find.text('Enter a complete HTTP or HTTPS download URL.'),
      findsOneWidget,
    );
    expect(manager.tasks, isEmpty);

    await tester.enterText(
      find.byKey(const Key('download-url')),
      'https://example.com/archive.zip',
    );
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Download file information'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('download-filename')),
      'saved.zip',
    );
    await tester.runAsync(() async {
      final added = manager.changes.first;
      await tester.tap(find.text('Download later'));
      await added.timeout(const Duration(seconds: 3));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(manager.tasks, hasLength(1));
    expect(manager.tasks.single.status, DownloadStatus.queued);
    expect(manager.tasks.single.filename, 'saved.zip');
    expect(find.text('saved.zip'), findsOneWidget);
    expect(find.text('Queued'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop selection exposes details and stop pauses queued task', (
    tester,
  ) async {
    final task = await tester.runAsync(
      () => manager.add(
        'https://example.com/report.pdf',
        directory: directory.path,
        start: false,
      ),
    );
    await mount(tester, const Size(1280, 800));
    await tester.tap(find.text('report.pdf'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('Details'), findsOneWidget);
    await tester.runAsync(() async {
      final paused = manager.changes.first;
      await tester.tap(find.text('Stop').first);
      await paused.timeout(const Duration(seconds: 3));
    });
    await tester.pumpAndSettle();
    expect(task!.status, DownloadStatus.paused);
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            widget.data == 'https://example.com/report.pdf',
      ),
      findsOneWidget,
    );
    expect(find.text('Resume capability:'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile list, drawer and add dialogs fit a narrow viewport', (
    tester,
  ) async {
    await tester.runAsync(
      () => manager.add(
        'https://example.com/video.mp4',
        directory: directory.path,
        start: false,
      ),
    );
    await mount(tester, const Size(390, 844));
    expect(find.text('video.mp4'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Finished'));
    await tester.pumpAndSettle();
    expect(find.text('No downloads in this view'), findsOneWidget);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('download-url')),
      'https://example.com/file.zip',
    );
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Download file information'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
