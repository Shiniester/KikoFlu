import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/widgets/responsive_dialog.dart';
import 'package:kikoeru_flutter/src/widgets/review_progress_dialog.dart';

class _Auth extends AuthNotifier {
  _Auth() : super(KikoeruApiService()) {
    state = const AuthState(host: 'https://test.invalid');
  }

  @override
  Future<void> enterAnonymous({String? host}) async {}
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
  });

  testWidgets('landscape mark menu opens at the right and returns selection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Map<String, dynamic>? result;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [authProvider.overrideWith((ref) => _Auth())],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await ReviewProgressDialog.show(
                    context: context,
                    currentProgress: 'marked',
                    currentRating: 3,
                  );
                },
                child: const Text('Open mark menu'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open mark menu'));
    await tester.pumpAndSettle();

    final header = find.byType(BottomSheetHeader);
    expect(header, findsOneWidget);
    expect(tester.getRect(header).right, greaterThan(900));
    expect(find.text('Listened'), findsOneWidget);

    await tester.tap(find.text('Listened'));
    await tester.pump();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();

    expect(result, {'progress': 'listened', 'rating': 3});
  });
}
