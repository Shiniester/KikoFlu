import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';

import '../services/app_bootstrap_coordinator.dart';
import '../performance/performance_recorder.dart';

class AppBootstrapGate extends StatefulWidget {
  const AppBootstrapGate({
    super.key,
    required this.coordinator,
    required this.readyBuilder,
    this.disposeCoordinator = true,
  });

  final AppBootstrapCoordinator coordinator;
  final WidgetBuilder readyBuilder;
  final bool disposeCoordinator;

  @override
  State<AppBootstrapGate> createState() => _AppBootstrapGateState();
}

class _AppBootstrapGateState extends State<AppBootstrapGate> {
  bool _deferredScheduled = false;

  @override
  void initState() {
    super.initState();
    widget.coordinator.addListener(_handleStateChanged);
    unawaited(widget.coordinator.start());
  }

  @override
  void didUpdateWidget(covariant AppBootstrapGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.coordinator, widget.coordinator)) return;
    oldWidget.coordinator.removeListener(_handleStateChanged);
    widget.coordinator.addListener(_handleStateChanged);
    _deferredScheduled = false;
    unawaited(widget.coordinator.start());
  }

  @override
  void dispose() {
    widget.coordinator.removeListener(_handleStateChanged);
    if (widget.disposeCoordinator) widget.coordinator.dispose();
    super.dispose();
  }

  void _handleStateChanged() {
    if (!mounted) return;
    setState(() {});
    if (widget.coordinator.state.isReady && !_deferredScheduled) {
      _deferredScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        developer.Timeline.instantSync('app.bootstrap.firstInteractive');
        PerformanceRecorder.instance.markFirstInteractive();
        unawaited(widget.coordinator.runDeferred());
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.coordinator.state;
    if (state.isReady) return widget.readyBuilder(context);

    final locale = WidgetsBinding.instance.platformDispatcher.locale;
    final isChinese = locale.languageCode.toLowerCase() == 'zh';
    final failed = state.phase == BootstrapPhase.failed;

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (failed)
                      const Icon(Icons.error_outline, size: 44)
                    else
                      const CircularProgressIndicator(),
                    const SizedBox(height: 20),
                    Text(
                      failed
                          ? (isChinese
                                ? 'KikoFlu 启动失败'
                                : 'KikoFlu failed to start')
                          : (isChinese ? '正在启动 KikoFlu…' : 'Starting KikoFlu…'),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (failed) ...[
                      const SizedBox(height: 12),
                      Text(
                        state.error.toString(),
                        textAlign: TextAlign.center,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: () => unawaited(widget.coordinator.retry()),
                        icon: const Icon(Icons.refresh),
                        label: Text(isChinese ? '重试' : 'Retry'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
