// C182: on a platform whose WebRTC binary has no SFrame transformer (iOS/macOS today) the plugin answers every
// "sframe*" call with `sframe-unavailable`. The Dart API must surface that as SframeUnavailableException and
// `available()` must be false — never a key store that silently does nothing.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('FlutterWebRTC.Method');
  final calls = <String>[];

  void answer(Object? Function(MethodCall c) f) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (c) async {
      calls.add(c.method);
      if (c.method == 'initialize') return null;
      return f(c);
    });
  }

  setUp(calls.clear);

  test('the Apple plugin (sframe-unavailable): available() is false, create() throws SframeUnavailableException',
      () async {
    answer((c) => c.method == 'sframeAvailable'
        ? false
        : throw PlatformException(code: 'sframe-unavailable', message: '${c.method}: not in this framework'));
    expect(await SframeKeyStore.available(), isFalse);
    await expectLater(SframeKeyStore.create(), throwsA(isA<SframeUnavailableException>()));
    await expectLater(SframeKeyStore.vectorSeal(Uint8List(32), 0x10001, 0, Uint8List(4), 1),
        throwsA(isA<SframeUnavailableException>()));
    expect(calls, containsAll(['sframeAvailable', 'sframeKeyStoreCreate', 'sframeVectorSeal']));
  });

  test('a binary with no handler at all (MissingPluginException) is unavailable too', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (c) async {
      if (c.method == 'initialize') return null;
      throw MissingPluginException();
    });
    expect(await SframeKeyStore.available(), isFalse);
    await expectLater(SframeKeyStore.create(), throwsA(isA<SframeUnavailableException>()));
  });

  test('Android (the AAR answers true): available() is true, other platform errors are not masked', () async {
    answer((c) => c.method == 'sframeAvailable'
        ? true
        : throw PlatformException(code: 'sframeKeyStoreCreateFailed', message: 'boom'));
    expect(await SframeKeyStore.available(), isTrue);
    await expectLater(SframeKeyStore.create(),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'sframeKeyStoreCreateFailed')));
  });
}
