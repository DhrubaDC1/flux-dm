import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'core/manager.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final support = await getApplicationSupportDirectory();
    final documents = await getApplicationDocumentsDirectory();
    final downloads = Platform.isAndroid || Platform.isIOS
        ? null
        : await getDownloadsDirectory();
    final directory =
        downloads ??
        Directory('${documents.path}${Platform.pathSeparator}Downloads');
    await directory.create(recursive: true);
    final manager = await DownloadManager.open(support);
    runApp(FluxApp(manager: manager, defaultDirectory: directory.path));
  } catch (error) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: SelectableText(
                'Flux Download Manager could not start.\n\n$error',
              ),
            ),
          ),
        ),
      ),
    );
  }
}
