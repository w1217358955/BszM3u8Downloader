Pod::Spec.new do |s|
  s.name             = 'BszM3u8Downloader'
  s.version          = '0.1.3'
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

  # Vendored GCDWebServer sources (via git submodule) so users can simply:
  #   #import <GCDWebServer/GCDWebServer.h>
  # without depending on the upstream GCDWebServer podspec (which uses a very
  # low deployment target and can fail lint on modern Xcode).
  s.subspec 'VendoredGCDWebServer' do |ss|
    # Compile upstream sources from the git submodule.
    # NOTE: We intentionally do NOT expose these headers as public. The local
    # server implementation will use small shim headers under External/ to keep
    # the familiar import path (<GCDWebServer/...>) working during compilation.
    ss.source_files = 'Vendor/GCDWebServer/GCDWebServer/**/*.{m}'

    # Upstream sources use many local includes like "GCDWebServerPrivate.h"
    # (no directory prefix), so we must add the subfolders to the header
    # search paths for the pod target.
    ss.xcconfig = {
      'HEADER_SEARCH_PATHS' => '"$(inherited)" "$(PODS_TARGET_SRCROOT)/Vendor/GCDWebServer/GCDWebServer" "$(PODS_TARGET_SRCROOT)/Vendor/GCDWebServer/GCDWebServer/Core" "$(PODS_TARGET_SRCROOT)/Vendor/GCDWebServer/GCDWebServer/Requests" "$(PODS_TARGET_SRCROOT)/Vendor/GCDWebServer/GCDWebServer/Responses"'
    }

    ss.libraries = 'z'
    ss.frameworks = 'CoreServices', 'CFNetwork'
  end

  s.subspec 'LocalServer' do |ss|
    ss.dependency 'BszM3u8Downloader/Core'
    ss.dependency 'BszM3u8Downloader/VendoredGCDWebServer'
    ss.source_files = 'BszM3u8Downloader/LocalServer/**/*.{h,m}'

    # Make <GCDWebServer/GCDWebServer.h> resolvable via our shim headers.
    ss.xcconfig = {
      'HEADER_SEARCH_PATHS' => '"$(inherited)" "$(PODS_TARGET_SRCROOT)/External" "$(PODS_TARGET_SRCROOT)/Vendor/GCDWebServer"'
    }
  end

  s.default_subspec = 'Core'
end
