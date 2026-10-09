// C182: mungeOpusAnswer is a line-for-line port of the web lab's rewrite (chat-web-gui call-media.js); these
// cases pin the exact output shape so Dart and JS keep negotiating the same Opus parameters (spec §9.1).
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

const crlf = '\r\n';

/// A LiveKit-style answer: one audio section with Opus + RED, one video section, one data section.
const answer = 'v=0$crlf'
    'o=- 1 2 IN IP4 127.0.0.1$crlf'
    's=-$crlf'
    't=0 0$crlf'
    'a=group:BUNDLE 0 1 2$crlf'
    'm=audio 9 UDP/TLS/RTP/SAVPF 111 63$crlf'
    'c=IN IP4 0.0.0.0$crlf'
    'a=mid:0$crlf'
    'a=ice-ufrag:abcd$crlf'
    'a=ice-pwd:efghijklmnopqrstuvwxyz$crlf'
    'a=recvonly$crlf'
    'a=rtcp-mux$crlf'
    'a=rtpmap:111 opus/48000/2$crlf'
    'a=rtcp-fb:111 transport-cc$crlf'
    'a=fmtp:111 minptime=10;useinbandfec=1$crlf'
    'a=rtpmap:63 red/48000/2$crlf'
    'a=fmtp:63 111/111$crlf'
    'm=video 9 UDP/TLS/RTP/SAVPF 96$crlf'
    'c=IN IP4 0.0.0.0$crlf'
    'a=mid:1$crlf'
    'a=rtpmap:96 VP8/90000$crlf'
    'a=fmtp:96 x-google-start-bitrate=300$crlf'
    'm=application 9 UDP/DTLS/SCTP webrtc-datachannel$crlf'
    'c=IN IP4 0.0.0.0$crlf'
    'a=mid:2$crlf'
    'a=sctp-port:5000$crlf';

void main() {
  test('the audio section gets the §9.1 parameters; video and data are untouched; CRLF kept', () {
    final out = mungeOpusAnswer(answer);
    final sections = out.split(RegExp(r'\r\n(?=m=)'));
    expect(sections, hasLength(4));
    expect(sections[0], answer.split(RegExp(r'\r\n(?=m=)'))[0], reason: 'session part untouched');
    expect(sections[2], answer.split(RegExp(r'\r\n(?=m=)'))[2], reason: 'video untouched');
    expect(sections[3], answer.split(RegExp(r'\r\n(?=m=)'))[3], reason: 'data untouched');
    final audio = sections[1].split(crlf);
    // existing fmtp line rewritten IN PLACE: its keys keep their order, the new ones follow
    expect(audio, contains('a=fmtp:111 minptime=10;useinbandfec=1;usedtx=1;cbr=1;maxaveragebitrate=24000'));
    expect(audio.indexOf('a=fmtp:111 minptime=10;useinbandfec=1;usedtx=1;cbr=1;maxaveragebitrate=24000'),
        audio.indexOf('a=rtcp-fb:111 transport-cc') + 1);
    // ptime + maxptime at the end of the section (the split consumed the CRLF before m=video)
    expect(audio.sublist(audio.length - 2), ['a=ptime:40', 'a=maxptime:40']);
    expect(out, contains('a=maxptime:40${crlf}m=video'));
    // RED's fmtp is not an Opus line and stays
    expect(audio, contains('a=fmtp:63 111/111'));
    expect(out, isNot(contains('\n\n')));
    expect(out.contains(RegExp(r'[^\r]\n')), isFalse, reason: 'CRLF only');
  });

  test('ptime and bitrate parameters; minptime is min(10, ptime)', () {
    final out = mungeOpusAnswer(answer, ptime: 60, bitrate: 32000);
    expect(out, contains('a=fmtp:111 minptime=10;useinbandfec=1;usedtx=1;cbr=1;maxaveragebitrate=32000$crlf'));
    expect(out, contains('a=ptime:60${crlf}a=maxptime:60$crlf'));
    final small = mungeOpusAnswer(answer, ptime: 5);
    expect(small, contains('minptime=5;'));
  });

  test('existing ptime/maxptime lines are replaced, existing fmtp keys overwritten in place', () {
    final withPtime = answer.replaceFirst('a=rtcp-mux$crlf', 'a=rtcp-mux${crlf}a=ptime:20${crlf}a=maxptime:120$crlf').replaceFirst(
        'a=fmtp:111 minptime=10;useinbandfec=1', 'a=fmtp:111 maxaveragebitrate=510000;stereo=1;useinbandfec=0');
    final out = mungeOpusAnswer(withPtime);
    expect(RegExp(r'a=ptime:').allMatches(out), hasLength(1));
    expect(RegExp(r'a=maxptime:').allMatches(out), hasLength(1));
    expect(out, contains('a=ptime:40${crlf}a=maxptime:40'));
    expect(out, isNot(contains('a=ptime:20')));
    expect(out, contains('a=fmtp:111 maxaveragebitrate=24000;stereo=1;useinbandfec=1;minptime=10;usedtx=1;cbr=1'));
  });

  test('an Opus payload without an fmtp line gets one right after its rtpmap', () {
    final noFmtp = answer.replaceFirst('a=fmtp:111 minptime=10;useinbandfec=1$crlf', '');
    final lines = mungeOpusAnswer(noFmtp).split(crlf);
    final i = lines.indexOf('a=rtpmap:111 opus/48000/2');
    expect(lines[i + 1], 'a=fmtp:111 minptime=10;useinbandfec=1;usedtx=1;cbr=1;maxaveragebitrate=24000');
  });

  test('an audio section without Opus, or an SDP without audio, is returned unchanged', () {
    final pcmu = answer.replaceAll('opus/48000/2', 'PCMU/8000');
    expect(mungeOpusAnswer(pcmu), pcmu);
    final videoOnly = answer.split(RegExp(r'\r\n(?=m=)')).where((s) => !s.startsWith('m=audio')).join(crlf);
    expect(mungeOpusAnswer(videoOnly), videoOnly);
  });

  test('a section without a trailing empty line still ends with ptime/maxptime', () {
    final audioOnly = answer.split(RegExp(r'\r\n(?=m=video)')).first; // ends with 'a=fmtp:63 111/111' (no CRLF)
    expect(audioOnly.endsWith(crlf), isFalse);
    expect(mungeOpusAnswer(audioOnly), endsWith('a=fmtp:63 111/111${crlf}a=ptime:40${crlf}a=maxptime:40'));
  });

  test('idempotent: munging a munged answer changes nothing', () {
    final once = mungeOpusAnswer(answer);
    expect(mungeOpusAnswer(once), once);
  });
}
