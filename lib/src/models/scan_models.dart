import 'dart:async';

import 'package:flutter/foundation.dart';

@immutable
class ScanRequest {
  const ScanRequest({
    required this.rootPath,
    this.operation = 'scan',
    this.metadata = const {},
  });

  final String rootPath;
  final String operation;
  final Map<String, Object?> metadata;
}

@immutable
class ScanProgress {
  const ScanProgress({
    required this.request,
    required this.scannedEntries,
    this.totalEntries,
    this.currentPath,
  });

  final ScanRequest request;
  final int scannedEntries;
  final int? totalEntries;
  final String? currentPath;

  double? get fraction {
    final total = totalEntries;
    if (total == null || total <= 0) return null;
    return (scannedEntries / total).clamp(0.0, 1.0);
  }
}

@immutable
class ScanResult<T> {
  const ScanResult({
    required this.request,
    required this.value,
    required this.scannedEntries,
    required this.duration,
  });

  final ScanRequest request;
  final T value;
  final int scannedEntries;
  final Duration duration;
}

class ScanCancellationToken {
  final Completer<void> _cancelledCompleter = Completer<void>();
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;
  Future<void> get whenCancelled => _cancelledCompleter.future;

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    _cancelledCompleter.complete();
  }

  void throwIfCancelled() {
    if (_isCancelled) throw const ScanCancelledException();
  }
}

class ScanCancelledException implements Exception {
  const ScanCancelledException();

  @override
  String toString() => 'ScanCancelledException';
}
