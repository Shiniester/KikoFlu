import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../services/audio_player_service.dart';
import '../services/automatic_work_marking_service.dart';
import '../services/log_service.dart';
import '../services/storage_service.dart';
import '../services/cache_service.dart';
import '../utils/global_keys.dart';
import '../utils/snackbar_util.dart';
import 'auth_provider.dart';
import 'my_reviews_provider.dart';

final automaticWorkMarkingRevisionProvider = StateProvider<int>((ref) => 0);
final _automaticWorkMarkingSettingProvider = StateProvider<bool>(
  (ref) => StorageService.getBool('automatic_work_marking') ?? false,
);

String? automaticMarkingAccountKey(AuthState auth) =>
    auth.currentUser == null || auth.host == null
    ? null
    : '${auth.host!.replaceFirst(RegExp(r'/+$'), '')}/${auth.currentUser!.name}';

final automaticWorkMarkingProvider = Provider<AutomaticWorkMarkingService>((
  ref,
) {
  final api = ref.read(kikoeruApiServiceProvider);
  void changed() {
    ref.read(automaticWorkMarkingRevisionProvider.notifier).state++;
  }

  void report(Object error) {
    LogService.instance.captureOutput('[AutomaticWorkMarking] $error');
  }

  final service = AutomaticWorkMarkingService(
    enabled: ref.read(_automaticWorkMarkingSettingProvider),
    saved: StorageService.getMap('automatic_work_marking_accounts'),
    account: () {
      final auth = ref.read(authProvider);
      if (!auth.isLoggedIn ||
          auth.currentUser == null ||
          auth.token?.isNotEmpty != true) {
        return null;
      }
      if (!api.isCurrentReviewAccount(
        host: auth.host ?? '',
        username: auth.currentUser!.name,
        token: auth.token!,
      )) {
        return null;
      }
      return automaticMarkingAccountKey(auth);
    },
    fetchProgress: (id, fresh) async {
      final metadata = fresh
          ? await api.getWork(id, forceRefresh: true)
          : await CacheService.getCachedWorkDetail(
              id,
              scope: api.recommendationPreferenceScope,
            );
      if (metadata == null || (!fresh && !metadata.containsKey('progress'))) {
        throw StateError('Cached review progress is unknown');
      }
      return metadata['progress'] as String?;
    },
    writeProgress: (id, progress) async {
      await api.updateAutomaticReviewProgress(id, progress);
    },
    persist: (data) =>
        StorageService.setMap('automatic_work_marking_accounts', data),
    onChanged: changed,
    onConflict: () {
      final context = rootNavigatorKey.currentContext;
      if (context != null) {
        SnackBarUtil.showWarning(
          context,
          S.of(context).automaticMarkingConflict,
        );
      }
    },
    onSynced: () {
      ref.read(myReviewsProvider.notifier).load(refresh: true);
    },
    onError: report,
  );
  final events = AudioPlayerService.instance.automaticMarkingEvents.listen((
    event,
  ) {
    if (service.enabled) unawaited(service.handle(event).catchError(report));
  });
  Timer? timer;
  ProviderSubscription<AuthState>? authSubscription;
  final observer = _AutomaticMarkingLifecycle(() {
    if (service.enabled) {
      unawaited(service.reconcilePending().catchError(report));
    }
  });
  void bind(bool enabled) {
    timer?.cancel();
    authSubscription?.close();
    WidgetsBinding.instance.removeObserver(observer);
    if (!enabled) return;
    timer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(service.reconcilePending().catchError(report));
    });
    WidgetsBinding.instance.addObserver(observer);
    authSubscription = ref.listen(authProvider, (_, __) {
      changed();
      unawaited(service.reconcilePending().catchError(report));
    });
  }

  bind(service.enabled);
  ref.listen(_automaticWorkMarkingSettingProvider, (_, value) {
    unawaited(service.setEnabled(value).catchError(report));
    bind(value);
  });
  ref.onDispose(() {
    timer?.cancel();
    authSubscription?.close();
    unawaited(events.cancel());
    WidgetsBinding.instance.removeObserver(observer);
    service.dispose();
  });
  return service;
});

final automaticWorkMarkingEnabledProvider = Provider<bool>((ref) {
  ref.watch(automaticWorkMarkingRevisionProvider);
  return ref.watch(automaticWorkMarkingProvider).enabled;
});

Future<void> setAutomaticWorkMarkingEnabled(WidgetRef ref, bool value) async {
  ref.read(automaticWorkMarkingProvider);
  await StorageService.setBool('automatic_work_marking', value);
  ref.read(_automaticWorkMarkingSettingProvider.notifier).state = value;
}

class _AutomaticMarkingLifecycle extends WidgetsBindingObserver {
  _AutomaticMarkingLifecycle(this.onResume);
  final VoidCallback onResume;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) onResume();
  }
}
