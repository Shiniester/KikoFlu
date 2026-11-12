import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'audio_backend_native_contract_test.dart' as audio_backend;
import 'audio_effects_production_test.dart' as audio_effects;

// Run both suites in one test APK.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  group('Packaged Android audio effects', audio_effects.main);
  group('Android native audio backend', audio_backend.main);
}
