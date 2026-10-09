// C182 (Takamaka): a process-wide hook on every remote description before libwebrtc reads it.
//
// Why: the Opus send parameters of spec §9.1 (40 ms frames, 24 kb/s CBR, DTX, in-band FEC) are not exposed by
// livekit_client (2.11 munges only the local offer's video bitrate), and libwebrtc configures its Opus ENCODER
// from the REMOTE description (`a=ptime` + the fmtp line of the answer). The web lab rewrites the relay's answer
// in a hooked RTCPeerConnection for the same reason (chat-web-gui call-media.js); this is the native twin.
//
// The hook is global and opt-in: null (the default) changes nothing. It sees the description's type and SDP and
// returns the SDP to set, or null to leave it as it is. It must be pure and fast; it runs on the caller's thread
// inside setRemoteDescription. See [mungeOpusAnswer] for the Opus rewrite.
import 'package:webrtc_interface/webrtc_interface.dart';

/// `type` is the description's type ('offer' | 'answer' | 'pranswer' | 'rollback'); returns the SDP to set,
/// or null to keep [sdp].
typedef RemoteSdpMunger = String? Function(String type, String sdp);

class RemoteSdpHook {
  RemoteSdpHook._();

  /// The installed munger, or null. Set it BEFORE the peer connection that must see it negotiates; clear it
  /// when the call ends.
  static RemoteSdpMunger? munger;

  /// Applies [munger] to [description]; returns the same object when nothing changes, a new
  /// [RTCSessionDescription] (the caller's object is never mutated) when it does.
  static RTCSessionDescription apply(RTCSessionDescription description) {
    final f = munger;
    final sdp = description.sdp;
    if (f == null || sdp == null) return description;
    final out = f(description.type ?? '', sdp);
    if (out == null || out == sdp) return description;
    return RTCSessionDescription(out, description.type);
  }
}
