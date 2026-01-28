#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 本地 HTTP Server（基于 GCDWebServer），用于播放已下载到本地的 m3u8/ts。
///
/// 典型用法：下载完成后调用 `playURLForTaskId:error:` 得到 `index.m3u8` 的 URL，交给播放器播放。
@interface BszM3u8LocalServer : NSObject

/// 当前服务器根地址，例如：http://127.0.0.1:12345
@property (nonatomic, copy, readonly, nullable) NSString *baseURLString;

/// 单例。
+ (instancetype)sharedServer;

/// 启动/切换映射目录。
///
/// @param rootDirectory 需要映射的本地目录（目录下应包含 index.m3u8 与 ts/key 文件）
/// @param error 启动失败原因
- (BOOL)startWithRootDirectory:(NSString *)rootDirectory error:(NSError **)error;

/// 启动/切换 rootDirectory，并返回可直接播放的 index.m3u8 URL。
///
/// @param rootDirectory 本地目录
/// @param error 若目录不存在或 index.m3u8 尚未生成，会返回 nil 并填充 error
- (nullable NSString *)playURLForRootDirectory:(NSString *)rootDirectory error:(NSError **)error;

/// 通过 taskId 获取可播放的 index.m3u8 URL。
///
/// 内部会查询任务对应 outputDir 并复用/启动 Server。
/// 若任务不存在或 index.m3u8 缺失，会返回 nil 并填充 error。
- (nullable NSString *)playURLForTaskId:(NSString *)taskId error:(NSError **)error;

/// 停止服务器。
- (void)stop;

@end

NS_ASSUME_NONNULL_END
