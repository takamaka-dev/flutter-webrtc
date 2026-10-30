import 'package:flutter/services.dart';

import 'package:webrtc_interface/webrtc_interface.dart';

import 'media_stream_track_impl.dart';
import 'utils.dart';

class RTCRtpReceiverNative extends RTCRtpReceiver {
  RTCRtpReceiverNative(
      this._id, this._track, this._parameters, this._peerConnectionId,
      {this.sframeCryptorId, this.sframeStreamId});

  factory RTCRtpReceiverNative.fromMap(Map<dynamic, dynamic> map,
      {required String peerConnectionId}) {
    var track = MediaStreamTrackNative.fromMap(map['track'], peerConnectionId);
    var parameters = RTCRtpParameters.fromMap(map['rtpParameters']);
    return RTCRtpReceiverNative(
        map['receiverId'], track, parameters, peerConnectionId,
        sframeCryptorId: map['sframeCryptorId'] as String?,
        sframeStreamId: map['sframeStreamId'] as String?);
  }

  /// C182 (Iris §7.117 1-B.4): the SFrame transformer the plugin auto-attached
  /// to THIS receiver inside onAddTrack, carried on the onTrack event — so the
  /// transformer is never looked up by receiver id, which libwebrtc takes from
  /// the relay-chosen msid track id and lets collide across m-sections. Null on
  /// a receiver the plugin did not attach to (not armed), or from `getReceivers`.
  final String? sframeCryptorId;

  /// Its stream label (`recv:<kind>:<uuid>`), for `SframeKeyStore.bindLeg`.
  final String? sframeStreamId;

  static List<RTCRtpReceiverNative> fromMaps(List<dynamic> map,
      {required String peerConnectionId}) {
    return map
        .map((e) =>
            RTCRtpReceiverNative.fromMap(e, peerConnectionId: peerConnectionId))
        .toList();
  }

  @override
  Future<List<StatsReport>> getStats() async {
    try {
      final response = await WebRTC.invokeMethod('getStats', <String, dynamic>{
        'peerConnectionId': _peerConnectionId,
        'trackId': track.id
      });
      var stats = <StatsReport>[];
      if (response != null) {
        List<dynamic> reports = response['stats'];
        for (var report in reports) {
          stats.add(StatsReport(report['id'], report['type'],
              report['timestamp'], report['values']));
        }
      }
      return stats;
    } on PlatformException catch (e) {
      throw 'Unable to RTCRtpReceiverNative::getStats: ${e.message}';
    }
  }

  /// private:
  String _id;
  String _peerConnectionId;
  MediaStreamTrack _track;
  RTCRtpParameters _parameters;

  /// The WebRTC specification only defines RTCRtpParameters in terms of senders,
  /// but this API also applies them to receivers, similar to ORTC:
  /// http://ortc.org/wp-content/uploads/2016/03/ortc.html#rtcrtpparameters*.
  @override
  RTCRtpParameters get parameters => _parameters;

  @override
  MediaStreamTrack get track => _track;

  @override
  String get receiverId => _id;

  String get peerConnectionId => _peerConnectionId;
}
