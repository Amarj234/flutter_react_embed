Pod::Spec.new do |s|
  s.name             = 'flutter_react_embed_ios'
  s.version          = '1.1.1'
  s.summary          = 'iOS implementation of flutter_react_embed (WKWebView and React Native engines).'
  s.description      = 'Hosts production React SPAs in WKWebView and, opt-in, React Native surfaces as Flutter platform views.'
  s.homepage         = 'https://github.com/Amarj234/flutter_react_embed'
  s.license          = { :type => 'BSD-3-Clause', :file => '../LICENSE' }
  s.author           = { 'Amarj234' => 'https://github.com/Amarj234' }
  s.source           = { :path => '.' }
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version    = '5.0'

  # Installed by Flutter's generated Podfile: the web engine only.
  s.default_subspec  = 'Core'

  s.subspec 'Core' do |core|
    core.source_files     = 'flutter_react_embed_ios/Sources/flutter_react_embed_ios/**/*.swift'
    core.resource_bundles = { 'flutter_react_embed_ios_privacy' => ['flutter_react_embed_ios/Sources/flutter_react_embed_ios/PrivacyInfo.xcprivacy'] }
    core.frameworks       = 'WebKit', 'CryptoKit'
  end

  # Opt-in React Native engine. Add to the app's Podfile, after
  # flutter_install_all_ios_pods and inside a target that calls use_react_native!:
  #
  #   pod 'flutter_react_embed_ios/ReactNative', :path => '.symlinks/plugins/flutter_react_embed_ios/ios'
  s.subspec 'ReactNative' do |rn|
    rn.dependency 'flutter_react_embed_ios/Core'
    rn.source_files = 'flutter_react_embed_ios/ReactNative/**/*.{swift,h,m}'
    rn.pod_target_xcconfig = { 'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => '$(inherited) FRE_REACT_NATIVE' }
    rn.dependency 'React-RCTAppDelegate'
    rn.dependency 'ReactAppDependencyProvider'
    # Defined by react_native_pods.rb when the Podfile requires it; adds
    # React-Core and the New Architecture header search paths.
    if respond_to?(:install_modules_dependencies, true)
      install_modules_dependencies(rn)
    else
      rn.dependency 'React-Core'
    end
  end
end
