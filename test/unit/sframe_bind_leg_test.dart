// C182 S-7: the channel shape of the leg binding (SframeKeyStore.bindLeg / create(requireLegBinding)), and how a
// binary without it surfaces: SframeUnavailableException from bindLeg, legBindingRequired false from create — never
// a silent "bound" answer.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('FlutterWebRTC.Method');
  final calls = <MethodCall>[];

  void answer(Object? Function(MethodCall c) f) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (c) async {
      if (c.method == 'initialize') return null;
      calls.add(c);
      return f(c);
    });
  }

  setUp(calls.clear);

  test('create(requireLegBinding: true) asks for it and reports what the binary did', () async {
    answer((c) => {'keyStoreId': 'ks1', 'requireLegBinding': true});
    final ks = await SframeKeyStore.create(requireLegBinding: true);
    expect(calls.single.method, 'sframeKeyStoreCreate');
    expect((calls.single.arguments as Map)['requireLegBinding'], isTrue);
    expect(ks.legBindingRequired, isTrue);
  });

  test('a binary that does not echo requireLegBinding (AAR < tkm.9) is NOT enforcing it', () async {
    answer((c) => {'keyStoreId': 'ks1'});
    final ks = await SframeKeyStore.create(requireLegBinding: true);
    expect(ks.legBindingRequired, isFalse);
  });

  test('bindLeg(streamId, legIndex) / bindLeg(streamId, null) → sframeKeyStoreBindLeg, legIndex -1 = unbind',
      () async {
    answer((c) => switch (c.method) {
          'sframeKeyStoreCreate' => {'keyStoreId': 'ks1', 'requireLegBinding': true},
          'sframeKeyStoreBindLeg' => (c.arguments as Map)['streamId'] == 'recv:audio:t1',
          _ => null,
        });
    final ks = await SframeKeyStore.create(requireLegBinding: true);
    expect(await ks.bindLeg('recv:audio:t1', 3), isTrue);
    expect(await ks.bindLeg('recv:audio:t1', null), isTrue);
    expect(await ks.bindLeg('unknown', 3), isFalse, reason: 'an unknown stream answers false');
    final bind = calls.where((c) => c.method == 'sframeKeyStoreBindLeg').map((c) => c.arguments as Map).toList();
    expect(bind[0], {'keyStoreId': 'ks1', 'streamId': 'recv:audio:t1', 'legIndex': 3});
    expect(bind[1], {'keyStoreId': 'ks1', 'streamId': 'recv:audio:t1', 'legIndex': -1});
    expect(() => ks.bindLeg('s', 0), throwsArgumentError, reason: 'leg_index 0 is reserved');
    expect(() => ks.bindLeg('s', 0x10000), throwsArgumentError);
  });

  test('SframeTransformer.bindLeg binds the stream of that transformer', () async {
    answer((c) => switch (c.method) {
          'sframeKeyStoreCreate' => {'keyStoreId': 'ks1', 'requireLegBinding': true},
          'sframeCryptorGetStats' =>
            '{"streamId":"recv:video:tr9","role":"recv","kind":"video","frames":0,"keyframes":0,"passed":0,'
                '"bytesIn":0,"bytesOut":0,"dropped":{},"consecutive":0,"storm":false,"storms":0,"boundLeg":7}',
          'sframeKeyStoreBindLeg' => true,
          'sframeAttachedFor' => 'cr1',
          _ => null,
        });
    final ks = await SframeKeyStore.create(requireLegBinding: true);
    final stats = SframeStreamStats.fromJson(
        '{"streamId":"x","role":"recv","kind":"video","frames":0,"keyframes":0,"passed":0,"bytesIn":0,'
        '"bytesOut":0,"dropped":{},"consecutive":0,"storm":false,"storms":0}');
    expect(stats.boundLeg, isNull, reason: 'no boundLeg in the stats = unbound / older binary');
    final t = SframeTransformer.forTesting('cr1', ks);
    expect(await t.bindLeg(7), isTrue);
    expect((await t.stats()).boundLeg, 7);
    final bind = calls.singleWhere((c) => c.method == 'sframeKeyStoreBindLeg').arguments as Map;
    expect(bind['streamId'], 'recv:video:tr9');
    expect(bind['legIndex'], 7);
  });

  test('a binary without the binding: bindLeg throws SframeUnavailableException (sframe-unavailable)', () async {
    answer((c) => switch (c.method) {
          'sframeKeyStoreCreate' => {'keyStoreId': 'ks1'},
          _ => throw PlatformException(code: 'sframe-unavailable', message: 'bindLeg needs tkm.9'),
        });
    final ks = await SframeKeyStore.create(requireLegBinding: true);
    await expectLater(ks.bindLeg('recv:audio:t1', 2), throwsA(isA<SframeUnavailableException>()));
  });

  test('an older binding that does not know the method (notImplemented) is unavailable too', () async {
    answer((c) => switch (c.method) {
          'sframeKeyStoreCreate' => {'keyStoreId': 'ks1'},
          _ => throw MissingPluginException(),
        });
    final ks = await SframeKeyStore.create();
    await expectLater(ks.bindLeg('recv:audio:t1', 2), throwsA(isA<SframeUnavailableException>()));
  });
}
