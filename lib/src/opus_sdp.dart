// C182 (Takamaka): the Opus send parameters of spec §9.1, written into the relay's SDP ANSWER.
//
// A Dart port, line for line, of `mungeOpusAnswer` in chat-web-gui's call-media.js (the web lab), so that the
// browser and the native clients negotiate the same thing. libwebrtc takes the encoder's frame size from the
// remote description's `a=ptime` (and `maxptime`), and cbr / maxaveragebitrate / usedtx / useinbandfec from the
// fmtp line of the Opus payload type. Only the publishing connection's ANSWER must be rewritten; the caller
// decides that (see [RemoteSdpHook]).
//
// The rewrite, per `m=audio` section that has `a=rtpmap:<pt> opus/48000`:
//   - every existing `a=ptime:` / `a=maxptime:` line is dropped;
//   - the fmtp line of <pt> gets minptime=min(10, ptime), useinbandfec=1, usedtx=1, cbr=1,
//     maxaveragebitrate=<bitrate> (existing keys are overwritten in place, others are kept; a missing fmtp line
//     is inserted right after the rtpmap line);
//   - `a=ptime:<ptime>` and `a=maxptime:<ptime>` are appended to the section.
// Sections without Opus, and video/data sections, are returned untouched. Line endings are CRLF, as libwebrtc
// writes them.
import 'dart:math' as math;

/// Spec §9.1 defaults: 40 ms frames, 24 kb/s constant bitrate.
const int opusPtimeMs = 40;
const int opusMaxAverageBitrate = 24000;

String mungeOpusAnswer(String sdp, {int ptime = opusPtimeMs, int bitrate = opusMaxAverageBitrate}) {
  final sections = sdp.split(RegExp(r'\r\n(?=m=)'));
  return sections.map((sec) => _mungeSection(sec, ptime, bitrate)).join('\r\n');
}

final RegExp _opusRtpmap = RegExp(r'a=rtpmap:(\d+) opus/48000', caseSensitive: false);
final RegExp _ptimeLine = RegExp(r'^a=(ptime|maxptime):');

String _mungeSection(String sec, int ptime, int bitrate) {
  if (!sec.startsWith('m=audio')) return sec;
  final m = _opusRtpmap.firstMatch(sec);
  if (m == null) return sec;
  final pt = m.group(1)!;
  final lines = sec.split('\r\n').where((l) => !_ptimeLine.hasMatch(l)).toList();
  final fmtpPrefix = 'a=fmtp:$pt ';
  final fmtpIdx = lines.indexWhere((l) => l.startsWith(fmtpPrefix));
  final want = <String, String>{
    'minptime': '${math.min(10, ptime)}',
    'useinbandfec': '1',
    'usedtx': '1',
    'cbr': '1',
    'maxaveragebitrate': '$bitrate',
  };
  // Insertion-ordered, like the JS Map: an overwritten key keeps its place.
  final params = <String, String>{};
  if (fmtpIdx >= 0) {
    for (final kv in lines[fmtpIdx].substring(fmtpPrefix.length).split(';')) {
      final i = kv.indexOf('=');
      if (i > 0) params[kv.substring(0, i).trim()] = kv.substring(i + 1).trim();
    }
  }
  want.forEach((k, v) => params[k] = v);
  final fmtp = fmtpPrefix + params.entries.map((e) => '${e.key}=${e.value}').join(';');
  if (fmtpIdx >= 0) {
    lines[fmtpIdx] = fmtp;
  } else {
    lines.insert(lines.indexWhere((l) => l.startsWith('a=rtpmap:$pt ')) + 1, fmtp);
  }
  // ptime goes after the last a=rtpmap/fmtp line of the section; keep a trailing empty line if present.
  final String? tail = lines.isNotEmpty && lines.last == '' ? lines.removeLast() : null;
  lines
    ..add('a=ptime:$ptime')
    ..add('a=maxptime:$ptime');
  if (tail != null) lines.add(tail);
  return lines.join('\r\n');
}
