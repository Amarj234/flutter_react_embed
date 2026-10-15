Pod::Spec.new do |s|
  s.name             = 'flutter_react_embed_ios'
  s.version          = '0.1.0'
  s.summary          = 'iOS implementation of flutter_react_embed (WKWebView engine).'
  s.description      = 'Hosts production React SPAs in WKWebView as Flutter platform views.'
  s.homepage         = 'https://github.com/flutter-react-embed/flutter_react_embed'
  s.license          = { :type => 'BSD' }
  s.author           = { 'flutter_react_embed authors' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'flutter_react_embed_ios/Sources/flutter_react_embed_ios/**/*.swift'
  s.resource_bundles = { 'flutter_react_embed_ios_privacy' => ['flutter_react_embed_ios/Sources/flutter_react_embed_ios/PrivacyInfo.xcprivacy'] }
  s.dependency 'Flutter'
  s.frameworks       = 'WebKit', 'CryptoKit'
  s.platform         = :ios, '15.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version    = '5.0'
end
