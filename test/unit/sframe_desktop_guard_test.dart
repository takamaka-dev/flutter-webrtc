// C182 — Iris §7.117 8p3 (ruling Q7 on desktop / web): no SFrame binding exists outside Android (and iOS with the
// tkm framework). Desktop serves no "sframe*" method at all (common/cpp/src/flutter_frame_cryptor.cc still answers
// the stock methods, never ours), so the channel answers notImplemented → MissingPluginException, and the web stub
// throws. This guard pins that SframeKeyStore.create and available() FAIL CLOSED there — no app of ours may start
// a call on such a platform (tkm_calls gates on available() before any peer connection).
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('FlutterWebRTC.Method');

  setUp(() {
    // The desktop plugin's channel: every "sframe*" method is unknown (notImplemented).
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (c) async {
      if (c.method == 'initialize') return null;
      if (c.method.startsWith('sframe')) throw MissingPluginException('${c.method} is not served on desktop');
      return null;
    });
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  for (final platform in [TargetPlatform.linux, TargetPlatform.windows, TargetPlatform.macOS]) {
    test('8p3: on ${platform.name} SframeKeyStore.create throws and available() is false (fail closed)', () async {
      debugDefaultTargetPlatformOverride = platform;
      expect(await SframeKeyStore.available(), isFalse);
      await expectLater(SframeKeyStore.create(), throwsA(isA<SframeUnavailableException>()));
      await expectLater(SframeKeyStore.create(requireLegBinding: false), throwsA(isA<SframeUnavailableException>()),
          reason: 'not even a store without the binding');
    });
  }
}
