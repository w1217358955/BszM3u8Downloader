#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 解析并下载 m3u8 中的 EXT-X-KEY 到本地目录，返回 URI -> 本地文件名映射。
///
/// 设计目标：
/// - 与下载器主会话隔离（使用独立 NSURLSession）
/// - 内部线程安全（不向外暴露可变共享状态）
/// - 提供同步接口以便调用方在生成本地 m3u8 前确保 key 已落盘
@interface BszM3u8KeyFetcher : NSObject

- (instancetype)initWithOutputDirectory:(NSString *)outputDirectory NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// 从 playlist 行中解析 EXT-X-KEY 的 URI 并下载到 outputDirectory。
///
/// @param lines playlist 按行拆分的内容
/// @param baseURL playlist 所在目录（用于处理相对 URI）
/// @param timeoutSeconds 最长等待秒数（避免网络异常导致无限阻塞）
/// @param hadError 若任意 key 下载/写入失败，会置为 YES
///
/// @return keyMap: 原始 URI 字符串 -> 本地文件名
- (NSDictionary<NSString *, NSString *> *)fetchKeysForPlaylistLines:(NSArray<NSString *> *)lines
                                                           baseURL:(NSURL *)baseURL
                                                     timeoutSeconds:(NSTimeInterval)timeoutSeconds
                                                          hadError:(BOOL * _Nullable)hadError;

@end

NS_ASSUME_NONNULL_END
