# BszM3u8Downloader

一个轻量的 Objective-C HLS（m3u8）离线下载库，面向“业务侧可落地”的多任务管理与本地播放：

- 统一的多任务管理入口：`BszM3u8DownloadManager`（推荐业务侧只使用 manager）
- 统一事件回调：只需要实现一个 delegate 方法即可驱动 UI（回调在主线程）
- 默认落盘目录稳定可观察：`Documents/BszM3u8Downloader/`（并做目录自愈）
- 默认不进 iCloud 备份（对离线大文件更安全）
- 可选本地 HTTP Server：用于 WKWebView/AVPlayer/三方播放器播放本地 m3u8（支持 Range/CORS/OPTIONS 等常见兼容点）
- 支持 `#EXT-X-KEY`：会尝试把 key 下载到本地并改写 m3u8 引用（不等同于 DRM）

> 如果你只想“能跑起来”：跳到「快速上手」。

---

## 目录结构预览

默认会在沙盒 `Documents` 下创建：

```
Documents/
  BszM3u8Downloader/
    tasks.plist
    downloads/
      <stableDirName_1>/
        index.m3u8
        0001.ts
        ...
      <stableDirName_2>/
        index.m3u8
        ...
```

- `tasks.plist`：任务索引/持久化记录
- `downloads/`：每个任务一个稳定子目录（由 taskId/url 生成，避免目录名过长且尽量可读）

---

## 安装

### CocoaPods

默认只包含下载功能（不含本地播放 server）：

```ruby
pod 'BszM3u8Downloader'
```

需要本地 HTTP Server 播放（依赖 `GCDWebServer`）：

```ruby
pod 'BszM3u8Downloader/LocalServer'
```

- 最低 iOS：11.0

### 本仓库本地集成（开发调试）

例如你的 App 与本仓库中的 `BszM3u8Downloader` 同级：

```ruby
pod 'BszM3u8Downloader', :path => '../BszM3u8Downloader'
```

### 运行示例工程（Example）

仓库内自带示例工程，包含：单任务/多任务/文件浏览（用于验证落盘与重启恢复）。

1. 进入 `BszM3u8Downloader/Example/`
2. 执行 `pod install`
3. 打开 `m3u8Example.xcworkspace` 运行

---

## 快速上手（最小可用示例）

### 1) 引入头文件

业务侧推荐只 import 入口文件（默认只暴露 manager）：

```objc
#import <BszM3u8Downloader/BszM3u8Downloader.h>
```

如需本地 HTTP 播放，再额外引入：

```objc
#import <BszM3u8Downloader/BszM3u8LocalServer.h>
```

### 2) 设置 delegate（统一接收状态/进度）

建议在 App 启动早期设置（例如 `AppDelegate` / `SceneDelegate` / 根 VC）。

```objc
@interface ViewController () <BszM3u8DownloadManagerDelegate>
@end

- (void)viewDidLoad {
    [super viewDidLoad];
    [BszM3u8DownloadManager sharedManager].delegate = self;
}

- (void)downloadManager:(BszM3u8DownloadManager *)manager
       didUpdateTaskInfo:(BszM3u8DownloadTaskInfo *)taskInfo
                   error:(NSError *)error {
    // 回调在主线程（便于直接更新 UI）
    NSLog(@"task=%@ status=%ld progress=%.3f speed=%.0f dir=%@ err=%@",
          taskInfo.taskId,
          (long)taskInfo.status,
          taskInfo.progress,
          taskInfo.speedBytesPerSecond,
          taskInfo.outputDir,
          error.localizedDescription);
}
```

### 3) 创建并启动任务

```objc
NSError *error = nil;
BOOL ok = [[BszM3u8DownloadManager sharedManager] createAndStartTaskWithTaskId:@"movie_001"
                                                                     urlString:@"https://example.com/a/index.m3u8"
                                                                           ext:@{ @"name": @"测试影片" }
                                                                         error:&error];
if (!ok) {
    NSLog(@"start failed: %@", error.localizedDescription);
}
```

### 4) 暂停 / 恢复 / 删除

```objc
[[BszM3u8DownloadManager sharedManager] pauseTaskForTaskId:@"movie_001"];

NSError *err = nil;
BOOL resumed = [[BszM3u8DownloadManager sharedManager] resumeTaskForTaskId:@"movie_001" error:&err];
if (!resumed) {
    NSLog(@"resume failed: %@", err.localizedDescription);
}

[[BszM3u8DownloadManager sharedManager] deleteTaskForTaskId:@"movie_001"];
```

### 5) 列表查询（用于页面初始化/重启恢复展示）

```objc
NSArray<BszM3u8DownloadTaskInfo *> *all = [[BszM3u8DownloadManager sharedManager] allDownloadersAscending:NO];
NSArray<BszM3u8DownloadTaskInfo *> *downloading = [[BszM3u8DownloadManager sharedManager] currentDownloadingTasksAscending:NO];
NSArray<BszM3u8DownloadTaskInfo *> *completed = [[BszM3u8DownloadManager sharedManager] completedTasksAscending:NO];
```

> `BszM3u8DownloadTaskInfo` 会尽量返回“最新状态”：如果该 task 当前内存里存在 downloader，则状态/进度更实时。

---

## 任务模型（BszM3u8DownloadTaskInfo）

核心字段：

- `taskId`：任务 id（用于管理/查询）
- `urlString`：原始 m3u8 URL
- `outputDir`：本地输出目录（绝对路径）
- `ext`：业务扩展字段（只支持字符串键值）
- `progress`：0.0 ~ 1.0
- `speedBytesPerSecond`：瞬时速度（运行期有效，不落盘）
- `status`：任务状态（见下方状态表）
- `createdAt`：创建时间戳（秒，内部用于排序）

### taskId 设计建议

- **稳定且唯一**：建议业务自行生成（如内容 id / 视频 id / 业务唯一 key）
- 可读性：推荐 `movie_001` / `course_123_4` 这种可读格式
- 不想自己管：传 `nil` 会退化为使用 `urlString` 作为 taskId

注意：默认下载目录名是由 task key（taskId 或 url）生成的稳定子目录（会包含短前缀 + hash），以避免过长路径、减少冲突。

---

## 任务状态说明（BszM3u8DownloadStatus）

| 状态 | 含义 | 典型 UI 展示 |
| --- | --- | --- |
| `NotReady` | 未准备（未创建/未进入队列） | 不展示或灰态 |
| `Ready` | 已进入等待队列（排队中） | “等待中” |
| `Starting` | 启动中 | “启动中” |
| `Downloading` | 下载中 | 进度条 + 速度 |
| `Paused` | 已暂停 | “已暂停” |
| `Stopped` | 已停止（错误/中止/失败） | “失败/已停止”，可提供重试 |
| `Completed` | 已完成（index.m3u8 已生成或本地缓存判定完成） | “已完成”，可播放 |

补充：如果并发达到上限，新任务会被标记为 `Ready` 并进入等待队列；等有空位会自动开始。

---

## 本地播放（可选：LocalServer subspec）

下载完成后，你通常会拿到一个本地输出目录 `outputDir`，其中包含 `index.m3u8`、若干 `ts`（以及可能的 key 文件）。

### 1) 通过 taskId 获取可播放 URL

`playURLForTaskId:error:` 内部会自动：

- 查询任务对应 `outputDir`
- 启动/复用本地 HTTP Server
- 返回可直接播放的 `index.m3u8` URL（形如 `http://127.0.0.1:xxxx/index.m3u8`）

```objc
NSError *error = nil;
NSString *playURL = [[BszM3u8LocalServer sharedServer] playURLForTaskId:@"movie_001" error:&error];
if (!playURL) {
    NSLog(@"play url error: %@", error.localizedDescription);
    return;
}

// AVPlayer
AVPlayer *player = [AVPlayer playerWithURL:[NSURL URLWithString:playURL]];
```

### 2) 直接指定 rootDirectory

如果你已经拿到了本地目录（例如来自 `taskInfo.outputDir`）：

```objc
NSError *error = nil;
NSString *playURL = [[BszM3u8LocalServer sharedServer] playURLForRootDirectory:taskInfo.outputDir error:&error];
```

### 3) WKWebView / H5 播放提示

通常把 `playURL` 交给 `<video>` 或三方播放器即可。若遇到播放失败，可优先检查：

- `index.m3u8` 是否已生成（未完成时会返回 `index.m3u8 not found yet`）
- 播放器是否依赖 Range 请求（本地 server 已针对 Range 做了兼容增强）
- H5 环境是否需要 CORS/OPTIONS（本地 server 已做常见处理）

如果你的 m3u8 包含 `#EXT-X-KEY`（例如 AES-128），离线播放还需要 key 文件也能成功落盘；若 key 获取失败，任务会被标记为 `Stopped`，避免出现“文件不全但误判 Completed”。

---

## 目录与持久化说明

### 默认策略

- 默认 store 根目录：`Documents/BszM3u8Downloader/`
- 会对 store 根目录与 `downloads/` 目录设置 `NSURLIsExcludedFromBackupKey=YES`（不进入 iCloud 备份）
- `tasks.plist` 保存任务的最小信息（url、outputDir、ext、progress/status、createdAt 等），用于 App 重启后恢复列表

### 为什么要存相对路径

iOS 沙盒根路径会随安装/重签名等发生变化。如果持久化保存绝对路径，重启后旧路径可能失效。

因此：`tasks.plist` 内的 `outputDir` 会优先以“相对 store 根目录”的方式持久化，运行时再拼接当前沙盒路径，从而避免“重启后 Completed 变失败/Stopped”的问题。

### 自定义下载根目录

你可以把下载落盘到自己的目录（传 `nil/空字符串` 会恢复默认）：

```objc
[[BszM3u8DownloadManager sharedManager] setDownloadRootDirectory:@"/your/custom/dir"];
```

> 注意：若你使用自定义根目录，持久化可能会保留绝对路径（用于保持你的目录语义）；建议你确保该目录长期可用。

---

## 高级用法（可选）

### 1) 用字典输出对接非 OC 层

如果你需要给 JS/Flutter/React Native 等层使用，可以用字典接口（所有 value 都是字符串，便于序列化）：

```objc
NSArray<NSDictionary<NSString *, NSString *> *> *items = [[BszM3u8DownloadManager sharedManager] allTaskDicsAscending:NO];
```

- `createdAt` 在字典中会以“毫秒字符串”输出，避免同秒并发创建导致排序不稳定。

### 2) 访问底层 downloader（不推荐，除非你确实需要）

大多数场景只用 manager 就够了；如果你确实需要调节更底层参数（例如单任务分片并发数、前后台策略等），可以拿到已存在的 downloader：

```objc
BszM3u8Downloader *d = [[BszM3u8DownloadManager sharedManager] existingDownloaderForTaskId:@"movie_001"];
d.maxConcurrentOperationCount = 3;
d.autoPauseWhenAppDidEnterBackground = YES;
```

---

## 常见问题（FAQ）

### 1) `playURLForTaskId` 返回 `index.m3u8 not found yet`

说明任务尚未完成或落盘目录异常。

- 确认 `taskInfo.status == BszM3u8DownloadStatusCompleted`
- 或检查 `taskInfo.outputDir` 下是否存在 `index.m3u8`

### 2) 重启后任务列表还在，但播放/路径失效

默认实现已通过“相对路径持久化”解决沙盒路径变化问题。

如果你自定义了下载根目录，请确保该目录在重启后仍然存在且可访问。

### 3) WKWebView/三方播放器 404 / 不支持 Range

本地 server 已对常见的 Range/MIME/CORS/OPTIONS 等做了补强；如果仍然 404：

- 确认传入的 rootDirectory 是“任务输出目录”（包含 index.m3u8）
- 确认播放器请求的路径没有越界（server 会拒绝路径穿越）

### 4) 加密流（EXT-X-KEY）下载后仍然无法离线播放

该库会尝试下载 key 并把 m3u8 中的 key URI 改写成本地文件名，但前提是：

- key 的 URI 可被正常访问（不依赖临时 cookie/一次性签名/设备绑定等）
- 播放器在离线播放时会按 m3u8 引用读取本地 key（本地 server 会按文件方式返回）

若你的加密方案属于 DRM/强鉴权，通常无法通过纯离线落盘实现播放。

---

## 致谢

- 自用项目, 但是如果能帮到更多人就更好了。
- 参考了：[AriaM3U8Downloader](https://github.com/moxcomic/AriaM3U8Downloader)
- 特别感谢 @moxcomic 的开源贡献。
