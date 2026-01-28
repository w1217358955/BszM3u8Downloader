#import <Foundation/Foundation.h>
#import "BszM3u8DownloaderCore.h"

@class BszM3u8Downloader;

/// 任务信息模型（用于 UI 展示/查询）。
@interface BszM3u8DownloadTaskInfo : NSObject

/// 任务 id（用于管理/查询）。未指定时内部会回退使用 urlString 作为 taskId。
@property (nonatomic, copy, nullable) NSString *taskId;
/// 原始 m3u8 URL 字符串。
@property (nonatomic, copy, nonnull) NSString *urlString;
/// 本地输出目录（绝对路径）。
@property (nonatomic, copy, nullable) NSString *outputDir;
/// 扩展信息（业务自定义），仅支持字符串键值。
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSString *> *ext;
/// 整体进度 0.0 ~ 1.0。
@property (nonatomic, assign) float progress;
/// 瞬时速度（字节/秒）。仅运行期有效，不落盘。
@property (nonatomic, assign) double speedBytesPerSecond;
/// 任务状态。
@property (nonatomic, assign) BszM3u8DownloadStatus status;
/// 创建时间戳（秒）。
@property (nonatomic, strong, nullable) NSNumber *createdAt;

@end

NS_ASSUME_NONNULL_BEGIN

@class BszM3u8DownloadManager;

/// Manager 级别统一事件回调（推荐：多任务只订阅这里）。
@protocol BszM3u8DownloadManagerDelegate <NSObject>
@optional
/// 任务信息发生变化时回调。
///
/// - Parameters:
///   - manager: 管理器单例
///   - taskInfo: 最新任务信息（包含 progress/status/outputDir 等）
///   - error: 仅在“失败/异常”时非空；普通进度/状态变更为 nil
- (void)downloadManager:(BszM3u8DownloadManager *)manager
	 didUpdateTaskInfo:(BszM3u8DownloadTaskInfo *)taskInfo
			 error:(nullable NSError *)error;
@end

/// 全局下载管理器（对外推荐的主入口）。
///
/// - 负责任务创建、并发控制、暂停/恢复/删除
/// - 负责任务持久化（重启后可恢复任务状态与目录）
@interface BszM3u8DownloadManager : NSObject

/// 统一事件回调（弱引用）。
@property (nonatomic, weak, nullable) id<BszM3u8DownloadManagerDelegate> delegate;

/// 单例。
+ (instancetype)sharedManager;

/// 设置下载根目录；每个任务会在该目录下创建自己的子目录。
///
/// 传入 nil/空字符串会恢复默认目录。
- (void)setDownloadRootDirectory:(nullable NSString *)directoryPath;

/// 返回所有任务列表（按 createdAt 排序）。
- (NSArray<BszM3u8DownloadTaskInfo *> *)allDownloadersAscending:(BOOL)ascending;

/// 返回未完成任务列表（Downloading/Paused/Ready/...，按 createdAt 排序）。
- (NSArray<BszM3u8DownloadTaskInfo *> *)currentDownloadingTasksAscending:(BOOL)ascending;

/// 返回已完成任务列表（按 createdAt 排序）。
- (NSArray<BszM3u8DownloadTaskInfo *> *)completedTasksAscending:(BOOL)ascending;

/// 返回所有任务字典（所有 value 均为字符串；按 createdAt 排序）。
- (NSArray<NSDictionary<NSString *, NSString *> *> *)allTaskDicsAscending:(BOOL)ascending;

/// 返回未完成任务字典（所有 value 均为字符串；按 createdAt 排序）。
- (NSArray<NSDictionary<NSString *, NSString *> *> *)currentDownloadingTaskDicsAscending:(BOOL)ascending;

/// 返回已完成任务字典（所有 value 均为字符串；按 createdAt 排序）。
- (NSArray<NSDictionary<NSString *, NSString *> *> *)completedTaskDicsAscending:(BOOL)ascending;

/// 暂停所有任务。
- (void)pauseAll;
/// 暂停指定任务。
- (void)pauseTaskForTaskId:(NSString *)taskId;
/// 恢复指定任务。
///
/// @param taskId 任务 id
/// @param error 失败原因（如任务不存在/参数错误等）
/// @return 是否成功触发恢复（或进入等待队列）
- (BOOL)resumeTaskForTaskId:(NSString *)taskId error:(NSError **)error;
/// 恢复所有任务。
- (void)resumeAll;
/// 查询任务信息（若内存中存在 downloader，会返回最新状态）。
- (nullable BszM3u8DownloadTaskInfo *)taskInfoForTaskId:(NSString *)taskId;

/// 查询任务信息字典（所有 value 均为字符串；若内存中存在 downloader，会返回最新状态）。
- (nullable NSDictionary<NSString *, NSString *> *)taskDicForTaskId:(NSString *)taskId;

/// 创建并启动任务。
///
/// @param taskId 自定义任务 id；传 nil 时默认使用 urlString 作为 taskId
/// @param urlString m3u8 URL 字符串
/// @param ext 业务扩展字段（字符串键值）
/// @param error 创建失败原因
/// @return 是否成功创建并触发启动/排队
- (BOOL)createAndStartTaskWithTaskId:(nullable NSString *)taskId
													 urlString:(NSString *)urlString
																 ext:(nullable NSDictionary<NSString *, NSString *> *)ext
															 error:(NSError **)error;

/// 删除指定任务（包含本地文件与持久化记录）。
- (void)deleteTaskForTaskId:(NSString *)taskId;

/// 仅查询内存中已存在的 downloader（不会创建新任务/不会触发持久化）。
- (nullable BszM3u8Downloader *)existingDownloaderForTaskId:(NSString *)taskId;

/// 停止并删除所有未完成任务及其文件。
- (void)stopAll;

/// 删除所有已完成任务及其文件。
- (void)deleteAll;

@end

NS_ASSUME_NONNULL_END
