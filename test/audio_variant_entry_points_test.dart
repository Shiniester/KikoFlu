import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/download_task_change.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/providers/audio_subtitle_generation_provider.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/providers/download_provider.dart';
import 'package:kikoeru_flutter/src/services/downloaded_file_state_scanner.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    show KikoeruApiService;
import 'package:kikoeru_flutter/src/services/player_audio_variant_classifier.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/widgets/file_explorer_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'lyric_translation_confirmed_once': true,
    });
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
  });

  for (final confirm in [true, false]) {
    testWidgets(
      confirm
          ? 'generation honors an audio chosen from the complete work list'
          : 'cancelling audio selection does not enqueue generation',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final downloads = _Downloads();
        addTearDown(downloads.changes.close);
        late _Actions actions;
        final container = ProviderContainer(
          overrides: [
            kikoeruApiServiceProvider.overrideWithValue(_Api()),
            downloadServiceProvider.overrideWithValue(downloads),
            downloadedFileStateScannerProvider.overrideWithValue(
              DownloadedFileStateScanner(
                downloadRootPath: () async => '/downloads',
                resolveDownloadedPath: (_, _) async => null,
                fileExists: (_) async => false,
              ),
            ),
            audioSubtitleActionsProvider.overrideWith(
              (ref) => actions = _Actions(ref),
            ),
          ],
        );
        addTearDown(container.dispose);
        container.read(audioSubtitleActionsProvider);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(
              locale: Locale('en'),
              localizationsDelegates: S.localizationsDelegates,
              supportedLocales: S.supportedLocales,
              home: Scaffold(
                body: CustomScrollView(
                  slivers: [
                    FileExplorerWidget(work: Work(id: 42, title: 'Work')),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Audio'));
        await tester.pumpAndSettle();
        await tester.longPress(find.text('01.wav'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('file-action-generate-subtitles')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Select audio version'), findsOneWidget);
        expect(actions.calls, 0);

        if (confirm) {
          await tester.tap(
            find.byKey(const ValueKey('audio-variant-toggle-all')),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(
              const ValueKey(
                'audio-variant-option-1_wav/01.wav-2_mp3/another-take.mp3',
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('audio-variant-selection-confirm')),
          );
          await tester.pumpAndSettle();
          expect(actions.calls, 1);
          expect(actions.targets.single.fullPath, '1_wav/01.wav');
          expect(
            actions.selected['1_wav/01.wav']?.fullPath,
            '2_mp3/another-take.mp3',
          );
        } else {
          await tester.tap(
            find.byKey(const ValueKey('audio-variant-selection-cancel')),
          );
          await tester.pumpAndSettle();
          expect(actions.calls, 0);
          expect(container.read(audioSubtitleGenerationProvider), isEmpty);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}

class _Api extends KikoeruApiService {
  @override
  Future<List<dynamic>> getWorkTracks(
    int workId, {
    bool forceRefresh = false,
  }) async => [
    {
      'type': 'folder',
      'title': '1_wav',
      'children': [
        {'type': 'audio', 'title': '01.wav', 'hash': 'wav-hash'},
      ],
    },
    {
      'type': 'folder',
      'title': '2_mp3',
      'children': [
        {'type': 'audio', 'title': 'another-take.mp3', 'hash': 'mp3-hash'},
      ],
    },
  ];
}

class _Downloads extends Fake implements DownloadTaskRepository {
  final changes = StreamController<DownloadTaskChange>.broadcast();

  @override
  Stream<DownloadTaskChange> get taskChangesStream => changes.stream;
}

class _Actions extends AudioSubtitleActions {
  _Actions(super.ref);

  int calls = 0;
  List<PlayerAudioVariant> targets = const [];
  Map<String, PlayerAudioVariant> selected = const {};

  @override
  Future<void> startWork({
    required Work work,
    required List<dynamic> fileTree,
    required List<PlayerAudioVariant> variants,
    Map<String, PlayerAudioVariant> selectedVariants = const {},
    String? workDirPath,
    Map<String, bool> downloadedFiles = const {},
    Map<String, String> fileRelativePaths = const {},
  }) async {
    calls++;
    targets = variants;
    selected = selectedVariants;
  }
}
