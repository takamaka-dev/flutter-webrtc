#import "FlutterSFrame.h"

// C182 / DR-055 — see FlutterSFrame.h. When the CI-built framework with RTCSFrameCryptor lands, this file is
// replaced by the real binding (the Android FlutterSFrame.java is the model); until then nothing here may succeed.
static NSString* const kSFrameUnavailable = @"sframe-unavailable";

@implementation FlutterWebRTCPlugin (SFrame)

- (BOOL)handleSFrameMethodCall:(nonnull FlutterMethodCall*)call result:(nonnull FlutterResult)result {
  NSString* method = call.method;
  if (![method hasPrefix:@"sframe"]) {
    return NO;
  }
  if ([method isEqualToString:@"sframeAvailable"]) {
    result(@NO);
    return YES;
  }
  result([FlutterError
      errorWithCode:kSFrameUnavailable
            message:[NSString stringWithFormat:@"%@: the SFrame transformer is not in this WebRTC.framework "
                                               @"(iOS build of takamaka-dev/webrtc-build owed) — media must not start",
                                               method]
            details:nil]);
  return YES;
}

@end
