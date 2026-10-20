platform :ios, '16.0'
project 'Reel.xcodeproj'

target 'Reel' do
  use_frameworks!
  # VideoLAN's player: MKV, HEVC, DTS/AC3/TrueHD audio, embedded and external subtitles.
  pod 'MobileVLCKit', '~> 3.7'
end

post_install do |installer|
  installer.pods_project.targets.each do |t|
    t.build_configurations.each do |c|
      c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'
      c.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
    end
  end
end
