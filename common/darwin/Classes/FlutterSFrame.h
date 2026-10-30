// C182 / DR-055 — the SFrame binding on Apple platforms (twin of android/.../FlutterSFrame.java).
//
// With a WebRTC.framework that carries our RFC 9605 transformer (RTCSFrameKeyStore / RTCSFrameCryptor: the
// iOS xcframework of takamaka-dev/webrtc-build, workflow tkm-ios.yml, 150.7871.03-tkm.5+), the "sframe*" methods
// drive it exactly as on Android, including AUTO-ATTACH (every sender gets a sealing transformer inside the call that
// created it, every receiver an opening one before Dart hears of it).
//
// With a framework WITHOUT it (the stock WebRTC-SDK pod, macOS): FAIL CLOSED — every "sframe*" method answers
// FlutterError "sframe-unavailable" and "sframeAvailable" answers NO. Decided at compile time by
// __has_include(<WebRTC/RTCSFrameKeyStore.h>), so a stock framework can never pretend to seal.
#if TARGET_OS_IPHONE
#import <Flutter/Flutter.h>
#elif TARGET_OS_OSX
#import <FlutterMacOS/FlutterMacOS.h>
#endif

#import <WebRTC/WebRTC.h>

#import "FlutterWebRTCPlugin.h"

@interface FlutterWebRTCPlugin (SFrame)

/// YES when [call] is an "sframe*" method (answered here), NO otherwise.
- (BOOL)handleSFrameMethodCall:(nonnull FlutterMethodCall*)call result:(nonnull FlutterResult)result;

/// Auto-attach hook: a sender was just created by addTrack / addTransceiver, before its result goes to Dart.
/// [kind] "audio" / "video" when known from the transceiver (a sender may have no track yet).
- (void)sframeOnSenderCreated:(nullable RTCRtpSender*)sender
             peerConnectionId:(nonnull NSString*)peerConnectionId
                         kind:(nullable NSString*)kind;

/// Auto-attach hook: a remote receiver was added (didAddReceiver), before the onTrack event goes to Dart.
/// [mid] is the receiver's transceiver mid (nil: unknown). Iris §7.117 1-B (twin of FlutterSFrame.java): the
/// endpoint is keyed by that mid — never by the receiver id, which libwebrtc takes from the relay-chosen msid track
/// id — a FRESH transformer is attached on every sighting (unbound until Dart binds it), a receiver id seen on two
/// mids raises the `duplicate-receiver` store event, and the attached transformer is returned as
/// @{@"sframeCryptorId", @"sframeStreamId"} for the onTrack event's receiver map (nil when nothing was attached).
/// Never throws (8p2 parity).
- (nullable NSDictionary*)sframeOnReceiverAdded:(nullable RTCRtpReceiver*)receiver
                               peerConnectionId:(nonnull NSString*)peerConnectionId
                                            mid:(nullable NSString*)mid;

@end
