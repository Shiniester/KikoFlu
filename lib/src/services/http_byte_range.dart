import 'dart:io';

enum ByteRangeResponseKind { full, partial, alreadyComplete }

class ByteRangeResponsePlan {
  const ByteRangeResponsePlan({
    required this.kind,
    required this.sourceLength,
    required this.responseLength,
  });

  final ByteRangeResponseKind kind;
  final int? sourceLength;
  final int? responseLength;
}

ByteRangeResponsePlan resolveByteRangeResponse({
  required int statusCode,
  required int requestedStart,
  required int? contentLength,
  required String? contentRange,
  int? requestedEndExclusive,
  bool allowUnknownSourceLength = false,
}) {
  if (statusCode == HttpStatus.ok) {
    return ByteRangeResponsePlan(
      kind: ByteRangeResponseKind.full,
      sourceLength: contentLength,
      responseLength: contentLength,
    );
  }
  if (statusCode == HttpStatus.partialContent) {
    final match = RegExp(
      r'^bytes (\d+)-(\d+)/(\d+|\*)$',
    ).firstMatch(contentRange ?? '');
    if (match == null) {
      throw const FormatException('Missing or invalid Content-Range');
    }
    final start = int.parse(match.group(1)!);
    final end = int.parse(match.group(2)!);
    final totalValue = match.group(3)!;
    final total = totalValue == '*' ? null : int.parse(totalValue);
    if (total == null && !allowUnknownSourceLength) {
      throw const FormatException('Content-Range source length is unknown');
    }
    if (start != requestedStart ||
        end < start ||
        (total != null && end >= total) ||
        (requestedEndExclusive != null && end >= requestedEndExclusive)) {
      throw const FormatException('Content-Range does not match request');
    }
    final responseLength = end - start + 1;
    if (contentLength != null && contentLength != responseLength) {
      throw const FormatException(
        'Content-Length conflicts with Content-Range',
      );
    }
    return ByteRangeResponsePlan(
      kind: ByteRangeResponseKind.partial,
      sourceLength: total,
      responseLength: responseLength,
    );
  }
  if (statusCode == HttpStatus.requestedRangeNotSatisfiable) {
    final match = RegExp(r'^bytes \*/(\d+)$').firstMatch(contentRange ?? '');
    final total = match == null ? null : int.parse(match.group(1)!);
    if (total != null && total == requestedStart) {
      return ByteRangeResponsePlan(
        kind: ByteRangeResponseKind.alreadyComplete,
        sourceLength: total,
        responseLength: 0,
      );
    }
    throw const FormatException('Requested byte range is not satisfiable');
  }
  throw HttpException('Unexpected byte range status: $statusCode');
}
