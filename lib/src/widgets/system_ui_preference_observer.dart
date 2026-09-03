import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/settings_provider.dart';
import '../utils/system_ui_style.dart';

class SystemUiPreferenceObserver extends ConsumerStatefulWidget {
  const SystemUiPreferenceObserver({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SystemUiPreferenceObserver> createState() =>
      _SystemUiPreferenceObserverState();
}

class _SystemUiPreferenceObserverState
    extends ConsumerState<SystemUiPreferenceObserver>
    with WidgetsBindingObserver {
  bool? _lastAppliedValue;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(SystemUiModeCoordinator.instance.reapply());
    }
  }

  void _apply(bool hideStatusBar) {
    if (_lastAppliedValue == hideStatusBar) return;
    _lastAppliedValue = hideStatusBar;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        SystemUiModeCoordinator.instance.setPreference(
          hideStatusBar: hideStatusBar,
          useEdgeToEdge: Platform.isAndroid,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    _apply(ref.watch(hideStatusBarProvider));
    return widget.child;
  }
}
