import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/services/download_service.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/widgets/file_selection_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('batch download waits for one audio selection confirmation', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    const work = Work(
      id: 4242,
      title: 'Batch work',
      children: [
        AudioFile(
          type: 'folder',
          title: 'WAV',
          children: [
            AudioFile(type: 'file', title: '01.wav', hash: 'batch-wav-1'),
            AudioFile(type: 'file', title: '02.wav', hash: 'batch-wav-2'),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: Scaffold(body: FileSelectionDialog(work: work)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select All'));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(FileSelectionDialog));
    await tester.tap(find.text(S.of(context).downloadN(2)));
    await tester.pumpAndSettle();

    expect(find.text('Select audio version'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('audio-variant-group-WAV/01.wav')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('audio-variant-group-WAV/02.wav')),
      findsOneWidget,
    );
    expect(await DownloadService.instance.getWorkTasks(work.id), isEmpty);

    await tester.tap(
      find.byKey(const ValueKey('audio-variant-selection-cancel')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Select audio version'), findsNothing);
    expect(find.byType(FileSelectionDialog), findsOneWidget);
    expect(await DownloadService.instance.getWorkTasks(work.id), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
