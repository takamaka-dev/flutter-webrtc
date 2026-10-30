# C182 (iOS, D-6): OUR WebRTC.xcframework = webrtc-sdk/webrtc 67c45788 + tkm_sframe.patch tkm.10 (the Android AAR's
# transformer + the Obj-C RTCSFrameKeyStore / RTCSFrameCryptor: the S-7 per-receiver leg binding — bindLeg /
# setRequireLegBinding / the `wrong-leg` drop — and, since tkm.10 (Iris §7.117 item 2, 2026-10-30), the binding
# REQUIRED by default with a one-way latch + ever_bound, plus the native nits), to be built by takamaka-dev/webrtc-build
# tkm-ios.yml from the native fork fix/iris-7117-native 8549219 and published as the pre-release ios-c182-sframe.3
# (slices ios-arm64 + ios-arm64_x86_64-simulator). tkm.10 = the same patch level as android/build.gradle's AAR
# (android-c182-sframe.4). The twin of android/build.gradle's B-0 fetch: CocoaPods downloads the zip by release tag
# and REFUSES it unless its sha256 is the pinned one.
#
# ⚠ The tkm.10 xcframework does NOT exist yet (no Mac/CI run): the sha256 below is a placeholder, so `pod install`
# fails until the release is published and the real digest is pinned here — accepted under R1 (iOS calls fail closed
# until the framework ships). Replace the URL's tag/asset and the sha256 TOGETHER when the run lands.
#
# The version is honest (150.7871.03-tkm.10, not the stock 150.7871.01): flutter_webrtc.podspec depends on exactly
# this version, which exists in no spec repo, so an app Podfile that forgets to declare this podspec fails at
# `pod install` instead of silently linking the stock framework (whose binding compiles to the fail-closed
# `sframe-unavailable`).
# In the app's ios/Podfile, inside `target 'Runner'`, after flutter_install_all_ios_pods:
#   pod 'WebRTC-SDK', :podspec => '.symlinks/plugins/flutter_webrtc/ios/tkm/WebRTC-SDK.podspec'
# and align livekit_client's WebRTC-SDK pin to the same version (see c182-call-example's ios/Podfile).
# A new framework = a new release tag + version + sha256 here, together. History: tkm.5 = ios-c182-sframe.1
# (run 38243403064, sha256 7563a11f...); tkm.9 = ios-c182-sframe.2 (webrtc-build 5414b86, run 40911940077,
# sha256 efdfe80a...), pinned on chore/ios-tkm9-pin 88f90e5.
Pod::Spec.new do |s|
  s.name     = 'WebRTC-SDK'
  s.version  = '150.7871.03-tkm.10'
  s.summary  = 'WebRTC.xcframework with the C182 SFrame transformer + S-7 leg binding required by default (tkm.10)'
  s.homepage = 'https://github.com/takamaka-dev/webrtc-build'
  s.license  = { :type => 'BSD', :file => 'WebRTC.xcframework/LICENSE' }
  s.author   = 'takamaka-dev'
  s.source   = {
    :http   => 'https://github.com/takamaka-dev/webrtc-build/releases/download/ios-c182-sframe.3/WebRTC-150.7871.03-tkm.10.xcframework.zip',
    :type   => 'zip',
    # PLACEHOLDER until ios-c182-sframe.3 is built: no real zip has this digest, so the pod is refused (R1).
    :sha256 => '0000000000000000000000000000000000000000000000000000000000000000'
  }
  s.ios.deployment_target = '13.0'
  s.vendored_frameworks = 'WebRTC.xcframework'
end
