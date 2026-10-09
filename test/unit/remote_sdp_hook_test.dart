// C182: the process-wide remote-SDP hook runs inside RTCPeerConnectionNative.setRemoteDescription, before the
// platform call; null (the default) changes nothing; the caller's description object is never mutated.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_webrtc/src/native/rtc_peerconnection_impl.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('FlutterWebRTC.Method');
  final sent = <Map<dynamic, dynamic>>[];

  setUp(() {
    sent.clear();
    RemoteSdpHook.munger = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (c) async {
      if (c.method == 'setRemoteDescription') sent.add(c.arguments['description'] as Map);
      return null;
    });
  });

  tearDown(() {
    RemoteSdpHook.munger = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('no munger: the description reaches the platform as given', () async {
    final pc = RTCPeerConnectionNative('pc1', {});
    await pc.setRemoteDescription(RTCSessionDescription('v=0\r\nm=audio 9 X 111\r\n', 'answer'));
    expect(sent.single, {'sdp': 'v=0\r\nm=audio 9 X 111\r\n', 'type': 'answer'});
  });

  test('a munger sees type + sdp and its result is what the platform gets; the input object is untouched',
      () async {
    final seen = <String>[];
    RemoteSdpHook.munger = (type, sdp) {
      seen.add(type);
      return type == 'answer' ? '$sdp' 'a=ptime:40\r\n' : null;
    };
    final pc = RTCPeerConnectionNative('pc1', {});
    final offer = RTCSessionDescription('v=0\r\nm=audio 9 X 111\r\n', 'offer');
    final answer = RTCSessionDescription('v=0\r\nm=audio 9 X 111\r\n', 'answer');
    await pc.setRemoteDescription(offer);
    await pc.setRemoteDescription(answer);
    expect(seen, ['offer', 'answer']);
    expect(sent[0]['sdp'], 'v=0\r\nm=audio 9 X 111\r\n', reason: 'null from the munger = unchanged');
    expect(sent[1]['sdp'], 'v=0\r\nm=audio 9 X 111\r\na=ptime:40\r\n');
    expect(answer.sdp, 'v=0\r\nm=audio 9 X 111\r\n', reason: 'never mutated');
  });

  test('apply() returns the same object when nothing changes', () {
    final d = RTCSessionDescription('x', 'answer');
    expect(identical(RemoteSdpHook.apply(d), d), isTrue);
    RemoteSdpHook.munger = (_, sdp) => sdp;
    expect(identical(RemoteSdpHook.apply(d), d), isTrue);
    RemoteSdpHook.munger = (_, sdp) => '${sdp}y';
    final out = RemoteSdpHook.apply(d);
    expect(identical(out, d), isFalse);
    expect(out.sdp, 'xy');
    expect(out.type, 'answer');
  });

  test('the Opus rewrite through the hook: an answer is munged, an offer is not', () async {
    RemoteSdpHook.munger = (type, sdp) => type == 'answer' ? mungeOpusAnswer(sdp) : null;
    const sdp = 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 opus/48000/2\r\na=fmtp:111 minptime=10\r\n';
    final pc = RTCPeerConnectionNative('pc1', {});
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
    expect(sent[0]['sdp'], sdp);
    expect(sent[1]['sdp'], contains('a=ptime:40\r\na=maxptime:40'));
    expect(sent[1]['sdp'], contains('a=fmtp:111 minptime=10;useinbandfec=1;usedtx=1;cbr=1;maxaveragebitrate=24000'));
  });
}
