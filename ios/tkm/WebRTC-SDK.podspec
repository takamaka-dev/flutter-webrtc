# C182 (iOS, D-6): OUR WebRTC.xcframework = webrtc-sdk/webrtc 67c45788 + tkm_sframe.patch tkm.9 (the Android AAR's
# transformer + the Obj-C RTCSFrameKeyStore / RTCSFrameCryptor, now with the S-7 per-receiver leg binding:
# bindLeg / setRequireLegBinding / the `wrong-leg` drop), built by takamaka-dev/webrtc-build 5414b86 tkm-ios.yml
# (run 40911940077, patch sha256 4b070e74...) and published as the pre-release ios-c182-sframe.2 (slices ios-arm64 +
# ios-arm64_x86_64-simulator). tkm.9 = the same patch level as android/build.gradle's AAR (android-c182-sframe.3).
# The twin of android/build.gradle's B-0 fetch: CocoaPods downloads the zip by release tag and REFUSES it unless its
# sha256 is the pinned one.
#
# The version is honest (150.7871.03-tkm.9, not the stock 150.7871.01): flutter_webrtc.podspec depends on exactly this
# version, which exists in no spec repo, so an app Podfile that forgets to declare this podspec fails at `pod install`
# instead of silently linking the stock framework (whose binding compiles to the fail-closed `sframe-unavailable`).
# In the app's ios/Podfile, inside `target 'Runner'`, after flutter_install_all_ios_pods:
#   pod 'WebRTC-SDK', :podspec => '.symlinks/plugins/flutter_webrtc/ios/tkm/WebRTC-SDK.podspec'
# and align livekit_client's WebRTC-SDK pin to the same version (see c182-call-example's ios/Podfile).
# A new framework = a new release tag + version + sha256 here, together. History: tkm.5 = ios-c182-sframe.1
# (run 38243403064, sha256 7563a11f...).
Pod::Spec.new do |s|
  s.name     = 'WebRTC-SDK'
  s.version  = '150.7871.03-tkm.9'
  s.summary  = 'WebRTC.xcframework with the C182 SFrame transformer + S-7 leg binding (tkm.9)'
  s.homepage = 'https://github.com/takamaka-dev/webrtc-build'
  s.license  = { :type => 'BSD', :file => 'WebRTC.xcframework/LICENSE' }
  s.author   = 'takamaka-dev'
  s.source   = {
    :http   => 'https://github.com/takamaka-dev/webrtc-build/releases/download/ios-c182-sframe.2/WebRTC-150.7871.03-tkm.9.xcframework.zip',
    :type   => 'zip',
    :sha256 => 'efdfe80a192bd5f12cf3e525ad7a3127743501bebcb3beb51520732e05d7ba2b'
  }
  s.ios.deployment_target = '13.0'
  s.vendored_frameworks = 'WebRTC.xcframework'
end
