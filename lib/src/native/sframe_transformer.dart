// Takamaka E2EE calls (C182 / DR-055): the RFC 9605 SFrame transformer of our webrtc-sdk fork, for Dart.
//
// Replaces the stock FrameCryptor path for our calls (livekit_client's own E2EE stays OFF). Spec:
// rschat-docs/security/E2EE_CALLS_PROTOCOL_SPEC_v1.md §9.2 — suite 5 AES_256_GCM_SHA512, KID = leg_index·2^16 +
// (epoch mod 2^16), AAD = SFrame header ‖ clear codec prefix, replay window 128, storm rule, fail closed: a sender
// with no send KID drops every frame, a receiver drops every frame it cannot authenticate.
//
// Android only for now. iOS/macOS: the plugin answers every "sframe*" call with `sframe-unavailable` until the
// CI-built WebRTC.framework carries the transformer — here that is [SframeUnavailableException], and
// [SframeKeyStore.available] is false: the app must not start media (fail closed, never a silent pass-through).
// Method names are new ("sframe*"): on a binary without them the calls fail instead of silently running another
// cipher.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:webrtc_interface/webrtc_interface.dart';

import 'rtc_rtp_receiver_impl.dart';
import 'rtc_rtp_sender_impl.dart';
import 'utils.dart';

/// Thrown by every SFrame call on a platform whose WebRTC binary has no SFrame transformer (iOS/macOS today).
/// A caller that sees it must not publish or render any media of the call.
class SframeUnavailableException implements Exception {
  SframeUnavailableException(this.method, this.message);

  final String method;
  final String? message;

  @override
  String toString() => 'SframeUnavailableException($method: ${message ?? 'unavailable'})';
}

Future<T?> _sframeCall<T>(String method, [dynamic param]) async {
  try {
    return await WebRTC.invokeMethod<T, dynamic>(method, param);
  } on PlatformException catch (e) {
    if (e.code == 'sframe-unavailable') throw SframeUnavailableException(method, e.message);
    rethrow;
  } on MissingPluginException {
    throw SframeUnavailableException(method, 'no native SFrame binding on this platform');
  }
}

enum SframeSetKeyResult { changed, unchanged, invalid }

enum SframeMediaKind { audio, video }

/// One transformer event (spec §9.2 [0.2] engagement + storm rule; [0.3] C-24 `held` / `released`).
class SframeEvent {
  SframeEvent(this.type, this.streamId, this.reason, this.kid, this.consecutive, {this.count = 0});

  factory SframeEvent.fromMap(Map<dynamic, dynamic> m) => SframeEvent(
      m['event'] as String,
      m['streamId'] as String? ?? '',
      m['reason'] as String? ?? '',
      (m['kid'] as num?)?.toInt() ?? -1,
      (m['consecutive'] as num?)?.toInt() ?? 0,
      count: (m['count'] as num?)?.toInt() ?? 0);

  /// `engaged`, `first-pass`, `dropping`, `storm`, `recovered`, `resumed`, `key-expired`, `key-evicted`.
  final String type;
  final String streamId;

  /// Drop reason for `dropping` / `storm` (the web worker's names), else empty.
  final String reason;

  /// -1 when none.
  final int kid;
  final int consecutive;

  /// `released`: the held frames opened and delivered when the key of [kid] arrived (C-24); else 0.
  final int count;

  @override
  String toString() =>
      'SframeEvent($type, $streamId${reason.isEmpty ? '' : ', $reason'}${kid < 0 ? '' : ', kid 0x${kid.toRadixString(16)}'})';
}

/// Counters of one transformer (no key material).
class SframeStreamStats {
  SframeStreamStats(this.raw);

  factory SframeStreamStats.fromJson(String json) =>
      SframeStreamStats(jsonDecode(json) as Map<String, dynamic>);

  final Map<String, dynamic> raw;

  String get streamId => raw['streamId'] as String;
  String get role => raw['role'] as String;
  String get kind => raw['kind'] as String;
  int get frames => raw['frames'] as int;
  int get keyframes => raw['keyframes'] as int;
  int get passed => raw['passed'] as int;
  int get bytesIn => raw['bytesIn'] as int;
  int get bytesOut => raw['bytesOut'] as int;
  Map<String, int> get dropped =>
      (raw['dropped'] as Map<String, dynamic>).map((k, v) => MapEntry(k, v as int));
  int get droppedTotal => dropped.values.fold(0, (a, b) => a + b);

  /// Drops other than `empty` (zero-length frames: on receive these are padding-only RTP packets, no media).
  int get droppedMedia => droppedTotal - (dropped['empty'] ?? 0);
  int get consecutive => raw['consecutive'] as int;
  bool get storm => raw['storm'] as bool;
  int get storms => raw['storms'] as int;

  /// C-24 (receive video): frames held for the key of a known leg's next epoch instead of dropped; of which
  /// released when it came; currently held. 0 on a binary without the hold (AAR < tkm.6).
  int get held => (raw['held'] as num?)?.toInt() ?? 0;
  int get heldReleased => (raw['heldReleased'] as num?)?.toInt() ?? 0;
  int get heldNow => (raw['heldNow'] as num?)?.toInt() ?? 0;
  int? get lastKid => raw['lastKid'] as int?;
  int? get firstFrameAtMs => raw['firstFrameAtMs'] as int?;
  int? get firstPassAtMs => raw['firstPassAtMs'] as int?;

  /// The first drops of each reason ("reason len=N first=<hex>"), as the web worker's dropSamples.
  List<String> get dropSamples => [for (final x in (raw['dropSamples'] as List<dynamic>? ?? const [])) x as String];

  @override
  String toString() =>
      '$role/$kind ${streamId.length > 24 ? streamId.substring(0, 24) : streamId}: frames $frames passed $passed '
      'dropped $dropped storms $storms${storm ? ' STORM' : ''}${held == 0 ? '' : ' held $held/$heldReleased (now $heldNow)'}'
      '${dropSamples.isEmpty ? '' : ' samples $dropSamples'}';
}

/// C-25 (2026-10-12): the Android capture tuning of our fork — WebRTC's adaptive digital AGC (AGC2 + limiter) as the
/// ONE software AGC stage, and the API 29+ "microphone towards the user" hint. Call once per call BEFORE the first
/// audio track exists (the hint applies at AudioRecord creation). No-op on iOS/macOS (VPIO already does AGC).
class SframeAudioTuning {
  SframeAudioTuning._();

  /// Returns the live AudioProcessing config string on Android (for logs), '' elsewhere. Throws
  /// [SframeUnavailableException] on a binary without the tuning (AAR < tkm.7).
  /// [levelMeter] (2009b, 2026-10-13): one logcat line per 10 s with the peak / RMS of the APM's capture OUTPUT
  /// (`tkm C-25: [APM out] …`) — the level the far side receives, after AGC2; the raw `[REC] level` line is before it.
  static Future<String> apply(
          {required bool adaptiveDigitalAgc, required bool micTowardsUser, bool levelMeter = false}) async =>
      (await _sframeCall<String>('sframeAudioTuning', <String, dynamic>{
            'adaptiveDigitalAgc': adaptiveDigitalAgc,
            'micTowardsUser': micTowardsUser,
            'levelMeter': levelMeter,
          })) ??
      '';
}

/// KID of spec §9.2: `leg_index·2^16 + (epoch mod 2^16)`.
int sframeKid(int legIndex, int epoch) {
  if (legIndex < 1 || legIndex > 0xffff) throw ArgumentError('leg_index 1..65535');
  return legIndex * 65536 + (epoch % 65536);
}

/// The keys of one call, shared by every transformer of that call (one CTR space per KID, replay window per KID).
class SframeKeyStore {
  SframeKeyStore._(this.id) {
    _events = EventChannel('FlutterWebRTC/sframeEvents/$id')
        .receiveBroadcastStream()
        .map((e) => SframeEvent.fromMap(e as Map<dynamic, dynamic>))
        .asBroadcastStream();
  }

  final String id;
  late final Stream<SframeEvent> _events;
  bool _disposed = false;

  /// Transformer events of every stream of this store.
  Stream<SframeEvent> get events => _events;

  /// True only where the native transformer exists (Android with our AAR). False on iOS/macOS today and on any
  /// error: callers gate media on it BEFORE any peer connection is created.
  static Future<bool> available() async {
    try {
      return (await WebRTC.invokeMethod<bool, dynamic>('sframeAvailable')) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<SframeKeyStore> create({int stormThreshold = 30, bool h264 = false}) async {
    final r = await _sframeCall<Map<dynamic, dynamic>>(
        'sframeKeyStoreCreate', <String, dynamic>{'stormThreshold': stormThreshold, 'h264': h264});
    return SframeKeyStore._(r!['keyStoreId'] as String);
  }

  Map<String, dynamic> _a([Map<String, dynamic>? more]) {
    if (_disposed) throw StateError('SframeKeyStore disposed');
    return <String, dynamic>{'keyStoreId': id, ...?more};
  }

  /// Installs the RFC 9605 key + salt of [kid] derived from [baseKey] (= `sender_base_e`, 32 bytes). There is no
  /// separate salt argument: RFC 9605 §4.4.2 derives the salt from the base key and the KID.
  Future<SframeSetKeyResult> setKey(int kid, Uint8List baseKey) async {
    final r = await _sframeCall<String>(
        'sframeKeyStoreSetKey', _a({'kid': kid, 'key': Uint8List.fromList(baseKey)}));
    return SframeSetKeyResult.values.byName(r!);
  }

  Future<bool> removeKey(int kid) async =>
      (await _sframeCall<bool>('sframeKeyStoreRemoveKey', _a({'kid': kid})))!;

  /// Keeps [kid] usable for [retention], then removes it (spec §9.2 receive window).
  Future<bool> retireKey(int kid, Duration retention) async => (await _sframeCall<bool>(
      'sframeKeyStoreRetireKey', _a({'kid': kid, 'retentionMs': retention.inMilliseconds})))!;

  /// The KID every sender of this store seals under. False if no key is installed for it.
  Future<bool> setSendKid(int kid) async =>
      (await _sframeCall<bool>('sframeKeyStoreSetSendKid', _a({'kid': kid})))!;

  Future<void> clearSendKid() => _sframeCall<void>('sframeKeyStoreClearSendKid', _a());

  /// The current send KID, or null.
  Future<int?> sendKid() async {
    final r = await _sframeCall<int>('sframeKeyStoreGetSendKid', _a());
    return r == null || r < 0 ? null : r;
  }

  Future<void> setStormThreshold(int n) =>
      _sframeCall<void>('sframeKeyStoreSetStormThreshold', _a({'n': n}));

  /// C-24 (spec §9.2 [0.3]): how long a receive VIDEO stream holds frames of a known leg's next epoch(s) while their
  /// key is missing (the native default is 10 s = the `retention` default; pass the call's `retention`).
  /// [Duration.zero] turns holding off. Throws [SframeUnavailableException] on a binary without the hold.
  Future<void> setHoldTime(Duration hold) =>
      _sframeCall<void>('sframeKeyStoreSetHoldTime', _a({'holdMs': hold.inMilliseconds}));

  /// Counters of every live transformer of this store.
  Future<List<SframeStreamStats>> stats() async {
    final r = await _sframeCall<String>('sframeKeyStoreGetStats', _a());
    return [for (final m in jsonDecode(r!) as List<dynamic>) SframeStreamStats(m as Map<String, dynamic>)];
  }

  /// Every RtpSender / RtpReceiver created FROM NOW ON by any peer connection of the plugin gets a transformer of
  /// this store, attached natively inside the call that created it (before Dart sees it). Use this with libraries
  /// that create their own transceivers (livekit_client). [enable] false stops attaching new ones.
  Future<void> autoAttach(bool enable) =>
      _sframeCall<void>('sframeAutoAttach', <String, dynamic>{'keyStoreId': enable ? id : null});

  /// Attaches a sealing transformer to [sender] (no-op if one is already attached).
  Future<SframeTransformer> attachToSender(RTCRtpSender sender, SframeMediaKind kind, {String? streamId}) async {
    final s = sender as RTCRtpSenderNative;
    final r = await _sframeCall<Map<dynamic, dynamic>>(
        'sframeAttachToSender',
        _a({
          'peerConnectionId': s.peerConnectionId,
          'rtpSenderId': s.senderId,
          'kind': kind.name,
          'streamId': streamId,
        }));
    return SframeTransformer._(r!['cryptorId'] as String, this);
  }

  /// Attaches an opening transformer to [receiver] (no-op if one is already attached).
  Future<SframeTransformer> attachToReceiver(RTCRtpReceiver receiver, SframeMediaKind kind,
      {String? streamId}) async {
    final rc = receiver as RTCRtpReceiverNative;
    final r = await _sframeCall<Map<dynamic, dynamic>>(
        'sframeAttachToReceiver',
        _a({
          'peerConnectionId': rc.peerConnectionId,
          'rtpReceiverId': rc.receiverId,
          'kind': kind.name,
          'streamId': streamId,
        }));
    return SframeTransformer._(r!['cryptorId'] as String, this);
  }

  /// The transformer attached (by [attachToSender] or auto-attach) to [sender], or null: a sender without one sends
  /// in clear — the caller must not publish on it.
  Future<SframeTransformer?> transformerOfSender(RTCRtpSender sender) async {
    final s = sender as RTCRtpSenderNative;
    final id = await _sframeCall<String>('sframeAttachedFor',
        <String, dynamic>{'peerConnectionId': s.peerConnectionId, 'rtpSenderId': s.senderId});
    return id == null ? null : SframeTransformer._(id, this);
  }

  /// The transformer attached to [receiver], or null (then its media must never be rendered).
  Future<SframeTransformer?> transformerOfReceiver(RTCRtpReceiver receiver) async {
    final rc = receiver as RTCRtpReceiverNative;
    final id = await _sframeCall<String>('sframeAttachedFor',
        <String, dynamic>{'peerConnectionId': rc.peerConnectionId, 'rtpReceiverId': rc.receiverId});
    return id == null ? null : SframeTransformer._(id, this);
  }

  /// Releases the store's handles. Transformers already attached stay attached and keep failing closed.
  Future<void> dispose() async {
    if (_disposed) return;
    await _sframeCall<void>('sframeKeyStoreDispose', _a());
    _disposed = true;
  }

  // ---- vector checks (no live key involved) ------------------------------------------------------------------

  /// Seals ONE Opus/VP8-shaped unit natively with the transformer's own code: key of [kid] derived from [baseKey],
  /// explicit [ctr], clear prefix [prefixLen]. For cross-platform vectors only.
  static Future<Uint8List?> vectorSeal(Uint8List baseKey, int kid, int ctr, Uint8List frame, int prefixLen) =>
      _sframeCall<Uint8List>('sframeVectorSeal', <String, dynamic>{
        'key': Uint8List.fromList(baseKey),
        'kid': kid,
        'ctr': ctr,
        'frame': frame,
        'prefixLen': prefixLen,
      });

  /// Opens ONE unit natively; null on any failure (bad tag, other KID, bad header).
  static Future<Uint8List?> vectorOpen(Uint8List baseKey, int kid, Uint8List unit, int prefixLen) =>
      _sframeCall<Uint8List>('sframeVectorOpen', <String, dynamic>{
        'key': Uint8List.fromList(baseKey),
        'kid': kid,
        'unit': unit,
        'prefixLen': prefixLen,
      });
}

/// The transformer attached to one sender or receiver.
class SframeTransformer {
  SframeTransformer._(this.id, this.store);

  final String id;
  final SframeKeyStore store;

  Future<SframeStreamStats> stats() async => SframeStreamStats.fromJson(
      (await _sframeCall<String>('sframeCryptorGetStats', <String, dynamic>{'cryptorId': id}))!);

  /// Engagement (spec §9.2 [0.2], per subscription): completes when this transformer has handed on
  /// [minPassed] more authenticated frames than at the call (the baseline), or throws on [timeout].
  Future<SframeStreamStats> engaged({int minPassed = 1, Duration timeout = const Duration(seconds: 15)}) async {
    final base = (await stats()).passed;
    final end = DateTime.now().add(timeout);
    while (true) {
      final s = await stats();
      if (s.passed - base >= minPassed) return s;
      if (DateTime.now().isAfter(end)) throw TimeoutException('transformer $id not engaged', timeout);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}
