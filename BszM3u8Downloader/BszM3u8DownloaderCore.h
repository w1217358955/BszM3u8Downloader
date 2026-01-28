#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 单文件整体进度回调 0.0 ~ 1.0。
typedef void (^BszM3u8DownloadProgressBlock)(float progress);

/// 单个 TS 下载成功回调。
typedef void (^BszM3u8DownloadTSSuccessBlock)(NSString *tsFileName);
/// 单个 TS 下载失败回调。
typedef void (^BszM3u8DownloadTSFailureBlock)(NSString *tsFileName, NSError *error);
/// 下载生命周期回调（开始/暂停/恢复/停止/完成等）。
typedef void (^BszM3u8DownloadSimpleEventBlock)(void);
/// TS 数量状态回调（已完成/总数）。
typedef void (^BszM3u8DownloadStatusBlock)(NSInteger finishedCount, NSInteger totalCount);
/// 下载速度回调（字节/秒）。
typedef void (^BszM3u8DownloadSpeedBlock)(double bytesPerSecond);
/// App 前后台切换回调。
typedef void (^BszM3u8DownloadAppLifecycleBlock)(void);

typedef NS_ENUM(NSInteger, BszM3u8DownloadStatus) {
	/// 未准备（未创建/未进入队列）。
	BszM3u8DownloadStatusNotReady = 0,
	/// 就绪（等待开始）。
	BszM3u8DownloadStatusReady,
	/// 启动中。
	BszM3u8DownloadStatusStarting,
	/// 已暂停。
	BszM3u8DownloadStatusPaused,
	/// 已停止（错误/中止/失败）。
	BszM3u8DownloadStatusStopped,
	/// 下载中。
	BszM3u8DownloadStatusDownloading,
	/// 已完成（index.m3u8 已生成或本地缓存已存在）。
	BszM3u8DownloadStatusCompleted
};

/// 单任务下载器（更底层的 API）。
///
/// 多任务/业务接入推荐使用 `BszM3u8DownloadManager`；仅在需要自定义更细粒度回调时才直接使用该类。
@interface BszM3u8Downloader : NSObject

/// m3u8 URL 字符串。
@property (nonatomic, copy, readonly) NSString *urlString;
/// 任务唯一标识（默认等于 urlString；也可由管理器传入自定义 id）。
@property (nonatomic, copy, readonly) NSString *identifier;
/// 输出目录（绝对路径）。
@property (nonatomic, copy, readonly) NSString *outputPath;

/// 扩展信息（业务自定义）。
@property (nonatomic, copy, readonly, nullable) NSDictionary<NSString *, NSString *> *ext;

/// 当前状态。
@property (nonatomic, assign, readonly) BszM3u8DownloadStatus downloadStatus;

/// 当前整体进度 0.0 ~ 1.0。
@property (nonatomic, assign, readonly) float progress;
/// 瞬时速度（字节/秒）。
@property (nonatomic, assign, readonly) double currentSpeedBytesPerSecond;
/// 速度可读字符串（如 "512 KB/s"）。
@property (nonatomic, copy, readonly) NSString *currentSpeedString;

/// 是否由本地缓存直接判定为完成。
@property (nonatomic, assign, readonly) BOOL completedFromCache;

/// 分片并发数上限（默认值由实现决定）。
@property (nonatomic, assign) NSInteger maxConcurrentOperationCount;
/// App 进入后台是否自动暂停（默认 YES）。
@property (nonatomic, assign) BOOL autoPauseWhenAppDidEnterBackground;

/// 单个 TS 下载成功回调。
@property (nonatomic, copy, nullable) BszM3u8DownloadTSSuccessBlock downloadTSSuccessExeBlock;
/// 单个 TS 下载失败回调。
@property (nonatomic, copy, nullable) BszM3u8DownloadTSFailureBlock downloadTSFailureExeBlock;
/// 整体进度回调。
@property (nonatomic, copy, nullable) BszM3u8DownloadProgressBlock downloadFileProgressExeBlock;
/// 开始回调。
@property (nonatomic, copy, nullable) BszM3u8DownloadSimpleEventBlock downloadStartExeBlock;
/// 暂停回调。
@property (nonatomic, copy, nullable) BszM3u8DownloadSimpleEventBlock downloadPausedExeBlock;
/// 恢复回调。
@property (nonatomic, copy, nullable) BszM3u8DownloadSimpleEventBlock downloadResumeExeBlock;
/// 停止回调。
@property (nonatomic, copy, nullable) BszM3u8DownloadSimpleEventBlock downloadStopExeBlock;
/// 完成回调（index.m3u8 已生成）。
@property (nonatomic, copy, nullable) BszM3u8DownloadSimpleEventBlock downloadCompleteExeBlock;
/// TS 数量状态回调（已完成/总数）。
@property (nonatomic, copy, nullable) BszM3u8DownloadStatusBlock downloadM3U8StatusExeBlock;
/// 速度更新回调。
@property (nonatomic, copy, nullable) BszM3u8DownloadSpeedBlock downloadSpeedUpdateExeBlock;
/// 进入后台回调。
@property (nonatomic, copy, nullable) BszM3u8DownloadAppLifecycleBlock downloadDidEnterBackgroundExeBlock;
/// 回到前台回调。
@property (nonatomic, copy, nullable) BszM3u8DownloadAppLifecycleBlock downloadDidBecomeActiveExeBlock;

/// 指定初始化。
///
/// @param urlString m3u8 URL 字符串
/// @param outputPath 输出目录（绝对路径）
/// @param ext 扩展信息
/// @param identifier 自定义标识；传 nil/空时默认等于 urlString
- (instancetype)initWithURLString:(NSString *)urlString
					 outputPath:(NSString *)outputPath
						   ext:(nullable NSDictionary<NSString *, NSString *> *)ext
				  identifier:(nullable NSString *)identifier NS_DESIGNATED_INITIALIZER;

/// 简化初始化（不传 ext/identifier）。
- (instancetype)initWithURLString:(NSString *)urlString
					 outputPath:(NSString *)outputPath;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// 开始下载（若之前暂停，会继续）。
- (void)start;
/// 暂停下载。
- (void)pause;
/// 从暂停恢复。
- (void)resume;
/// 停止并取消下载。
- (void)stop;

/// 工具方法：将字节/秒格式化为可读字符串。
+ (NSString *)formatSpeed:(double)bytesPerSecond;

@end

NS_ASSUME_NONNULL_END

