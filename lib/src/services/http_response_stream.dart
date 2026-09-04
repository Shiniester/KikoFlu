import 'dart:async';
import 'dart:io';

/// Makes cancellation interrupt an HTTP response even after headers arrived.
Stream<List<int>> cancellableHttpResponseStream({
  required HttpClientRequest request,
  required HttpClientResponse response,
  required Future<void> whenCancelled,
  required bool Function() isCancelled,
  required String cancellationMessage,
}) async* {
  final iterator = StreamIterator<List<int>>(response);
  final cancellationError = HttpException(cancellationMessage);
  final cancellation = whenCancelled.then<bool>((_) {
    request.abort(cancellationError);
    throw cancellationError;
  });
  try {
    while (await Future.any<bool>([iterator.moveNext(), cancellation])) {
      yield iterator.current;
    }
  } finally {
    if (isCancelled()) {
      request.abort(cancellationError);
    }
    await iterator.cancel();
  }
}
