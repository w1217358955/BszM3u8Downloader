Pod::Spec.new do |s|
  s.name             = 'BszM3u8Downloader'
  s.version          = '0.1.0'
  s.summary          = 'An Objective-C M3U8 downloader Manager'

  s.description      = <<-DESC
An Objective-C library that downloads HLS (m3u8) playlists and their TS segments to local storage, provides rich callbacks and simple multi-task management, and optionally exposes a local HTTP server for playback.
  DESC

  s.homepage         = 'https://github.com/w1217358955/BszM3u8Downloader.git'
  s.author           = { 'Bin' => 'w1217358955@163.com' }
  s.source           = { :git => 'https://github.com/w1217358955/BszM3u8Downloader.git', :tag => s.version.to_s }

  s.ios.deployment_target = '11.0'

  s.requires_arc     = true

  # Core 下载功能（不包含本地 HTTP Server）
  s.subspec 'Core' do |ss|
    # 核心下载器及管理器源码（注意这里的相对路径与当前目录结构一致）
    ss.source_files = 'BszM3u8Downloader/*.{h,m}',
                      'BszM3u8Downloader/Manager/**/*.{h,m}'
  end

  # 本地 HTTP Server，用于播放本地 m3u8/ts
  s.subspec 'LocalServer' do |ss|
    ss.dependency 'BszM3u8Downloader/Core'
    ss.source_files = 'BszM3u8Downloader/LocalServer/**/*.{h,m}'
    ss.dependency 'GCDWebServer', '~> 3.0'
  end

  s.default_subspec = 'Core'
end
