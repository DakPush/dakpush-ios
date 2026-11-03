# Names and URLs are temporary until the DakPush domain is bought.
Pod::Spec.new do |s|
  s.name          = 'DakPush'
  s.version       = '0.1.0'
  s.summary       = 'iOS SDK for DakPush, a self-hosted push notification server.'
  s.description   = <<-DESC
Registers the iPhone with a DakPush server straight through APNs (no
Firebase), keeps its user, tags and subscription in step, and reports taps and
deliveries.
                    DESC
  s.homepage      = 'https://github.com/hridoyrocks/dak-push-ios'
  s.license       = { :type => 'MIT', :file => 'LICENSE' }
  s.author        = 'Md Shoriful Haque Hridoy'
  s.source        = { :git => 'https://github.com/hridoyrocks/dak-push-ios.git', :tag => s.version.to_s }
  s.platform      = :ios, '15.0'
  s.swift_version = '5.9'
  s.source_files  = 'Sources/DakPush/**/*.swift'
  s.resource_bundles = { 'DakPush_Privacy' => ['Sources/DakPush/PrivacyInfo.xcprivacy'] }
  s.frameworks    = 'UIKit', 'UserNotifications', 'Security', 'CryptoKit'
  s.dependency 'DakPushExtension', s.version.to_s
end
