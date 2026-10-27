import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/history_record.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/providers/history_provider.dart';
import 'package:kikoeru_flutter/src/screens/history_screen.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/widgets/work_cover_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _LoadedHistory extends HistoryNotifier {
  _LoadedHistory(super._ref, HistoryRecord record)
    : super(now: () => DateTime(2026)) {
    state = HistoryState(records: [record], totalCount: 1, hasMore: false);
  }

  @override
  Future<void> load({
    bool refresh = false,
    bool force = false,
    int? targetPage,
  }) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('history screen list cover matches its four-line title', (
    tester,
  ) async {
    const title = 'One\nTwo\nThree\nFour';
    const work = Work(id: 90210, title: title);
    SharedPreferences.setMockInitialValues({
      'collection_history_layout_type': 'list',
    });
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    final record = HistoryRecord(work: work, lastPlayedTime: DateTime(2026));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          historyProvider.overrideWith((ref) => _LoadedHistory(ref, record)),
        ],
        child: const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(320, 800),
              textScaler: TextScaler.linear(1.3),
            ),
            child: HistoryScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final titleFinder = find.text(title);
    final coverFinder = find.byType(WorkCoverImage).first;
    final coverSize = tester.getSize(coverFinder);
    expect(coverSize.height, closeTo(tester.getSize(titleFinder).height, 0.1));
    expect(coverSize.width / coverSize.height, 4 / 3);
    expect(tester.widget<Text>(titleFinder).maxLines, 4);
    expect(tester.takeException(), isNull);
  });
}
