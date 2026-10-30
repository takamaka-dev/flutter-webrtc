// C182 S-7: the channel shape of the leg binding (SframeKeyStore.bindLeg / create(requireLegBinding)), and how a
// binary without it surfaces: SframeUnavailableException from bindLeg, legBindingRequired false from create — never
// a silent "bound" answer.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_webrtc/src/native/rtc_rtp_receiver_impl.dart';

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

  test('R1 (Iris §7.117): a binary that does not echo requireLegBinding (AAR < tkm.9) → the store is disposed and '
      'create throws SframeUnavailableException, never a store that silently opens every KID', () async {
    answer((c) => c.method == 'sframeKeyStoreCreate' ? {'keyStoreId': 'ks1'} : null);
    await expectLater(SframeKeyStore.create(requireLegBinding: true), throwsA(isA<SframeUnavailableException>()));
    expect(calls.map((c) => c.method), ['sframeKeyStoreCreate', 'sframeKeyStoreDispose']);
    expect((calls[1].arguments as Map)['keyStoreId'], 'ks1');
  });

  test('R1: an explicit requireLegBinding: false echoed false is honoured (vectors / tests only)', () async {
    answer((c) => {'keyStoreId': 'ks1', 'requireLegBinding': false});
    final ks = await SframeKeyStore.create(requireLegBinding: false);
    expect(ks.legBindingRequired, isFalse);
    expect(calls.map((c) => c.method), ['sframeKeyStoreCreate']);
  });

  test('R2 (Iris §7.117): create() asks for the leg binding BY DEFAULT', () async {
    answer((c) => {'keyStoreId': 'ks1', 'requireLegBinding': true});
    final ks = await SframeKeyStore.create();
    expect((calls.single.arguments as Map)['requireLegBinding'], isTrue);
    expect(ks.legBindingRequired, isTrue);
    answer((c) => c.method == 'sframeKeyStoreCreate' ? {'keyStoreId': 'ks2'} : null);
    await expectLater(SframeKeyStore.create(), throwsA(isA<SframeUnavailableException>()),
        reason: 'the default is enforced like an explicit request');
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
    final ks = await SframeKeyStore.create(requireLegBinding: false); // R1: true would already throw at create
    await expectLater(ks.bindLeg('recv:audio:t1', 2), throwsA(isA<SframeUnavailableException>()));
  });

  test('an older binding that does not know the method (notImplemented) is unavailable too', () async {
    answer((c) => switch (c.method) {
          'sframeKeyStoreCreate' => {'keyStoreId': 'ks1'},
          _ => throw MissingPluginException(),
        });
    final ks = await SframeKeyStore.create(requireLegBinding: false);
    await expectLater(ks.bindLeg('recv:audio:t1', 2), throwsA(isA<SframeUnavailableException>()));
  });

  // Iris §7.117 1-B.4: the transformer of a receiver comes from the onTrack event, never from a lookup by the
  // relay-chosen receiver id; the lookup is only a fallback and refuses an ambiguous id.
  group('transformerOfReceiver', () {
    RTCRtpReceiverNative receiver({String? cryptorId, String? streamId}) => RTCRtpReceiverNative.fromMap({
          'receiverId': 'TR_dup',
          'rtpParameters': <String, dynamic>{
            'encodings': [],
            'codecs': [],
            'headerExtensions': [],
            'rtcp': {'cname': 'x', 'reducedSize': false},
          },
          'track': {'id': 'TR_dup', 'label': 'audio', 'kind': 'audio', 'enabled': true, 'readyState': 'live', 'remote': true},
          if (cryptorId != null) 'sframeCryptorId': cryptorId,
          if (streamId != null) 'sframeStreamId': streamId,
        }, peerConnectionId: 'pc1');

    test('prefers the cryptor id carried by the onTrack event: no sframeAttachedFor call, stream label known',
        () async {
      answer((c) => switch (c.method) {
            'sframeKeyStoreCreate' => {'keyStoreId': 'ks1', 'requireLegBinding': true},
            'sframeKeyStoreBindLeg' => true,
            _ => throw StateError('unexpected ${c.method}'),
          });
      final ks = await SframeKeyStore.create();
      final t = await ks.transformerOfReceiver(receiver(cryptorId: 'cr-7', streamId: 'recv:audio:u7'));
      expect(t!.id, 'cr-7');
      expect(t.streamId, 'recv:audio:u7');
      expect(await t.bindLeg(3), isTrue);
      final bind = calls.singleWhere((c) => c.method == 'sframeKeyStoreBindLeg').arguments as Map;
      expect(bind['streamId'], 'recv:audio:u7', reason: 'bound by the event-carried label, no stats call');
      expect(calls.where((c) => c.method == 'sframeAttachedFor' || c.method == 'sframeCryptorGetStats'), isEmpty);
      final r2 = receiver(cryptorId: 'cr-8', streamId: 'recv:audio:u8');
      expect((await ks.transformerOfReceiver(r2))!.id, 'cr-8', reason: 'the same receiver id, its OWN cryptor');
    });

    test('without the event-carried id: the lookup by receiver id, which answers null for an ambiguous id', () async {
      answer((c) => switch (c.method) {
            'sframeKeyStoreCreate' => {'keyStoreId': 'ks1', 'requireLegBinding': true},
            'sframeAttachedFor' => (c.arguments as Map)['rtpReceiverId'] == 'TR_dup' ? null : 'cr-1',
            _ => null,
          });
      final ks = await SframeKeyStore.create();
      expect(await ks.transformerOfReceiver(receiver()), isNull, reason: 'ambiguous (seen on two m-lines): refused');
      final look = calls.singleWhere((c) => c.method == 'sframeAttachedFor').arguments as Map;
      expect(look, {'peerConnectionId': 'pc1', 'rtpReceiverId': 'TR_dup'});
    });
  });

  test('the duplicate-receiver event parses (Iris §7.117 1-B.3)', () {
    final e = SframeEvent.fromMap({
      'event': 'duplicate-receiver',
      'streamId': 'recv:audio:u9',
      'reason': 'receiver TR_dup on pc1/recv/0 and pc1/recv/1',
      'kid': -1,
      'consecutive': 0,
      'count': 0,
    });
    expect(e.type, 'duplicate-receiver');
    expect(e.streamId, 'recv:audio:u9');
    expect(e.reason, contains('pc1/recv/1'));
    expect(e.kid, -1);
  });
}
