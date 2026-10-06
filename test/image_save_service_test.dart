import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/widgets/image_save_service.dart';

class _SavePicker extends FilePicker {
  String? outputPath;
  String? suggestedName;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    suggestedName = fileName;
    return outputPath;
  }
}

void main() {
  testWidgets(
    'desktop save writes full bytes and handles cancel and failure',
    (tester) async {
      final picker = _SavePicker();
      FilePicker.platform = picker;
      final directory = Directory.systemTemp.createTempSync('reader-save-');
      addTearDown(() => directory.deleteSync(recursive: true));
      late BuildContext saveContext;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) {
                saveContext = context;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      final bytes = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);
      await saveReaderImage(saveContext, bytes, 'Page: 1');
      await tester.pump();
      expect(picker.suggestedName, 'Page_ 1.png');
      expect(find.byType(SnackBar), findsNothing);

      picker.outputPath = '${directory.path}/page.png';
      await tester.runAsync(
        () => saveReaderImage(saveContext, bytes, 'Page: 1'),
      );
      await tester.pump();
      expect(File(picker.outputPath!).readAsBytesSync(), orderedEquals(bytes));
      expect(find.textContaining(picker.outputPath!), findsOneWidget);

      ScaffoldMessenger.of(saveContext).removeCurrentSnackBar();
      await tester.pumpAndSettle();
      picker.outputPath = '${directory.path}/missing/page.png';
      await tester.runAsync(
        () => expectLater(
          saveReaderImage(saveContext, bytes, 'Page: 1'),
          throwsA(isA<FileSystemException>()),
        ),
      );
      await tester.pump();
      expect(find.byType(SnackBar), findsNothing);
    },
    skip: Platform.isAndroid || Platform.isIOS,
  );
}
