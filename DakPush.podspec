# Names and URLs are temporary until the DakPush domain is bought.
Pod::Spec.new do |s|
  s.name          = 'DakPush'
  s.version       = '0.2.0'
  s.summary       = 'iOS SDK for DakPush, a self-hosted push notification server.'
  s.description   = <<-DESC
Registers the iPhone with a DakPush server straight through APNs (no
Firebase), keeps its user, tags and subscription in step, reports taps and
deliveries, and shows the server's in-app messages.
                    DESC
  s.homepage      = 'https://github.com/DakPush/dakpush-ios'
  s.license       = { :type => 'MIT', :file => 'LICENSE' }
  s.author        = 'Md Shoriful Haque Hridoy'
  s.source        = { :git => 'https://github.com/DakPush/dakpush-ios.git', :tag => s.version.to_s }
  s.platform      = :ios, '15.0'
  s.swift_version = '5.9'
  s.source_files  = 'Sources/DakPush/**/*.swift'
  s.resource_bundles = { 'DakPush_Privacy' => ['Sources/DakPush/PrivacyInfo.xcprivacy'] }
  s.frameworks    = 'UIKit', 'UserNotifications', 'Security', 'CryptoKit', 'ImageIO', 'SwiftUI'
  s.dependency 'DakPushExtension', s.version.to_s
end
