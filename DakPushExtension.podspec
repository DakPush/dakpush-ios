# Names and URLs are temporary until the DakPush domain is bought.
Pod::Spec.new do |s|
  s.name          = 'DakPushExtension'
  s.version       = '0.2.0'
  s.summary       = 'DakPush notification service extension: images, buttons and delivery receipts.'
  s.description   = <<-DESC
For the notification service extension of an app that uses DakPush: attaches
the push's image, adds its buttons, counts badge increments, and reports the
delivery to the app's DakPush server through the App Group it shares with the
app. Safe for app extensions.
                    DESC
  s.homepage      = 'https://github.com/DakPush/dakpush-ios'
  s.license       = { :type => 'MIT', :file => 'LICENSE' }
  s.author        = 'Md Shoriful Haque Hridoy'
  s.source        = { :git => 'https://github.com/DakPush/dakpush-ios.git', :tag => s.version.to_s }
  s.platform      = :ios, '15.0'
  s.swift_version = '5.9'
  s.source_files  = 'Sources/DakPushExtension/**/*.swift'
  s.resource_bundles = { 'DakPushExtension_Privacy' => ['Sources/DakPushExtension/PrivacyInfo.xcprivacy'] }
  s.frameworks    = 'UserNotifications'
end
