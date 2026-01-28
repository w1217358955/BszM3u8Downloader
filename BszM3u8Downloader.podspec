Pod::Spec.new do |s|
  s.name             = 'BszM3u8Downloader'
  s.version          = '0.1.1'
  s.summary          = 'An Objective-C M3U8 downloader Manager'

  s.description      = <<-DESC
An Objective-C library that downloads HLS (m3u8) playlists and their TS segments to local storage, provides rich callbacks and simple multi-task management, and optionally exposes a local HTTP server for playback.
  DESC

  s.homepage         = 'https://github.com/w1217358955/BszM3u8Downloader'
  s.author           = { 'Bin' => 'w1217358955@163.com' }
  s.source           = { :git => 'https://github.com/w1217358955/BszM3u8Downloader.git', :tag => s.version.to_s }
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.ios.deployment_target = '12.0'

  s.requires_arc     = true

  s.subspec 'Core' do |ss|
    ss.source_files = 'BszM3u8Downloader/*.{h,m}',
              'BszM3u8Downloader/Manager/**/*.{h,m}'
  end

  s.subspec 'LocalServer' do |ss|
    ss.dependency 'BszM3u8Downloader/Core'
    ss.source_files = 'BszM3u8Downloader/LocalServer/**/*.{h,m}'
    ss.dependency 'GCDWebServer', '~> 3.0'
  end

  s.default_subspec = 'Core'
end
