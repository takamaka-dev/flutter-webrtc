// C182 / DR-055 — the SFrame binding on Apple platforms: FAIL CLOSED until the WebRTC.framework carries our
// RFC 9605 transformer (RTCSFrameCryptor, built by the iOS CI of takamaka-dev/webrtc-build — not yet).
//
// Every "sframe*" method answers FlutterError "sframe-unavailable", except "sframeAvailable" which answers NO.
// No key is ever accepted, no transformer is attached, so the Dart side cannot believe media is sealed on iOS.
#if TARGET_OS_IPHONE
#import <Flutter/Flutter.h>
#elif TARGET_OS_OSX
#import <FlutterMacOS/FlutterMacOS.h>
#endif

#import "FlutterWebRTCPlugin.h"

@interface FlutterWebRTCPlugin (SFrame)

/// YES when [call] is an "sframe*" method (answered here), NO otherwise.
- (BOOL)handleSFrameMethodCall:(nonnull FlutterMethodCall*)call result:(nonnull FlutterResult)result;

@end
