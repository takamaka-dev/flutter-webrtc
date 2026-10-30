#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html
#
Pod::Spec.new do |s|
  s.name             = 'flutter_webrtc'
  s.version          = '1.6.2'
  s.summary          = 'Flutter WebRTC plugin for iOS.'
  s.description      = <<-DESC
A new flutter plugin project.
                       DESC
  s.homepage         = 'https://github.com/cloudwebrtc/flutter-webrtc'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'CloudWebRTC' => 'duanweiwei1982@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files = 'flutter_webrtc/Sources/flutter_webrtc/**/*.{h,m,mm,cpp}'
  s.public_header_files = 'flutter_webrtc/Sources/flutter_webrtc/include/flutter_webrtc/**/*.h'
  s.dependency 'Flutter'
  # C182 (D-6): our framework (ios/tkm/WebRTC-SDK.podspec, the app Podfile must declare it) - not the stock
  # 150.7871.01, which has no RTCSFrame* and would build the fail-closed binding.
  s.dependency 'WebRTC-SDK', '150.7871.03-tkm.10' # Iris §7.117 (2026-10-30): tkm.10 / ios-c182-sframe.3 - framework not built yet (R1: iOS fails closed until it ships)
  s.ios.deployment_target = '13.0'
  s.static_framework = true
  s.pod_target_xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++14',
    'USER_HEADER_SEARCH_PATHS' => '"${PODS_TARGET_SRCROOT}/flutter_webrtc/Sources/flutter_webrtc/include/flutter_webrtc"'
  }
  s.libraries = 'c++'
end
