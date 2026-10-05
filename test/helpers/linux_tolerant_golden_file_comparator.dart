import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

const double _linuxRasterizationTolerance = 0.003;

GoldenFileComparator createPlatformGoldenFileComparator(Uri testFile) {
  return Platform.isLinux
      ? _LinuxTolerantGoldenFileComparator(testFile)
      : goldenFileComparator;
}

class _LinuxTolerantGoldenFileComparator extends LocalFileComparator {
  _LinuxTolerantGoldenFileComparator(super.testFile);

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );
    final passed =
        result.passed || result.diffPercent <= _linuxRasterizationTolerance;
    if (passed) {
      result.dispose();
      return true;
    }

    final error = await generateFailureOutput(result, golden, basedir);
    result.dispose();
    throw FlutterError(error);
  }
}
