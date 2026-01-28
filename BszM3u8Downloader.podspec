Pod::Spec.new do |s|
  s.name             = 'BszM3u8Downloader'
  s.version          = '0.1.2'
  s.summary          = 'An Objective-C M3U8 downloader Manager'

  s.description      = <<-DESC
An Objective-C library that downloads HLS (m3u8) playlists and their TS segments to local storage, provides rich callbacks and simple multi-task management, and optionally exposes a local HTTP server for playback.
  DESC

  s.homepage         = 'https://github.com/w1217358955/BszM3u8Downloader'
  s.author           = { 'Bin' => 'w1217358955@163.com' }
  s.source           = { :git => 'https://github.com/w1217358955/BszM3u8Downloader.git', :tag => s.version.to_s, :submodules => true }
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.ios.deployment_target = '12.0'

  s.requires_arc     = true

  s.subspec 'Core' do |ss|
    ss.source_files = 'BszM3u8Downloader/*.{h,m}',
              'BszM3u8Downloader/Manager/**/*.{h,m}'
  end

  s.subspec 'LocalServer' do |ss|
    ss.dependency 'BszM3u8Downloader/Core'
    # Vendor GCDWebServer sources via git submodule to avoid lint failures on
    # modern Xcode when the upstream podspec uses a very low deployment target.
    ss.source_files = 'BszM3u8Downloader/LocalServer/**/*.{h,m}',
                      'Vendor/GCDWebServer/GCDWebServer/Core/**/*.{h,m}',
                      'Vendor/GCDWebServer/GCDWebServer/Requests/**/*.{h,m}',
                      'Vendor/GCDWebServer/GCDWebServer/Responses/**/*.{h,m}'

    ss.libraries = 'z'
    ss.xcconfig = {
      'HEADER_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/Vendor/GCDWebServer"'
    }
  end

  s.default_subspec = 'Core'
end
