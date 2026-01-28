#import <Foundation/Foundation.h>

/// BszM3u8Downloader 的对外入口头文件。
///
/// 推荐：业务方只 import 这个文件，然后主要使用 `BszM3u8DownloadManager`。
/// 若需要本地 HTTP 播放，请引入 subspec `BszM3u8Downloader/LocalServer` 并使用 `BszM3u8LocalServer`。
#import "BszM3u8DownloadManager.h"

