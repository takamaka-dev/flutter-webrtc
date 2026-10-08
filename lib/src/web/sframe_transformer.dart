// C182: the SFrame transformer binding is native (Android) only; the web client uses its own worker
// (chat-web-gui static/js/call/sframe-worker.js). This stub keeps `package:flutter_webrtc` compiling on the web.
import 'dart:typed_data';

enum SframeSetKeyResult { changed, unchanged, invalid }

enum SframeMediaKind { audio, video }

int sframeKid(int legIndex, int epoch) {
  if (legIndex < 1 || legIndex > 0xffff) throw ArgumentError('leg_index 1..65535');
  return legIndex * 65536 + (epoch % 65536);
}

class SframeUnavailableException implements Exception {
  SframeUnavailableException(this.method, this.message);
  final String method;
  final String? message;
  @override
  String toString() => 'SframeUnavailableException($method: ${message ?? 'unavailable'})';
}

class SframeKeyStore {
  static Future<bool> available() async => false;

  static Future<SframeKeyStore> create({int stormThreshold = 30, bool h264 = false}) =>
      throw UnsupportedError('SframeKeyStore: native only (web: use the SFrame worker)');

  static Future<Uint8List?> vectorSeal(Uint8List baseKey, int kid, int ctr, Uint8List frame, int prefixLen) =>
      throw UnsupportedError('native only');

  static Future<Uint8List?> vectorOpen(Uint8List baseKey, int kid, Uint8List unit, int prefixLen) =>
      throw UnsupportedError('native only');
}
