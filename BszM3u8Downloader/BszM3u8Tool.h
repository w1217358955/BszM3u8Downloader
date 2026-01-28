#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 内部工具类（用于解析 playlist、生成本地化 m3u8）。
///
/// 说明：该类主要供库内部使用；一般业务方无需直接调用。
@interface BszM3u8Tool : NSObject

/// 将分片 URL 转换为稳定的本地文件名（用于 ts/key 等落盘）。
+ (NSString *)localFileNameForURL:(NSURL *)url;

/// 从 m3u8 内容行中提取第一个“变体 playlist”(variant) 的 URI。
/// 返回 nil 表示未发现 variant。
+ (nullable NSString *)firstVariantURIFromLines:(NSArray<NSString *> *)lines;

/// 将 playlist 行解析为分片 URL 列表。
///
/// @param lines playlist 内容按行拆分
/// @param baseURL playlist 的 baseURL（用于处理相对路径）
+ (NSArray<NSURL *> *)segmentURLsFromLines:(NSArray<NSString *> *)lines baseURL:(NSURL *)baseURL;

/// 写入“本地化 playlist”文件。
///
/// - 将分片 URI 改写为本地文件名
/// - 将 key URI 改写为本地 key 文件名（由 keyMap 提供）
///
/// @param lines playlist 内容按行拆分
/// @param baseURL playlist baseURL
/// @param keyMap 原始 key URI -> 本地 key 文件名
/// @param outputDirectory 输出目录
/// @param fileName 输出文件名（如 index.m3u8）
/// @param error 写入失败原因
/// @return 写入后的本地化 m3u8 文件路径（绝对路径）；失败返回 nil
+ (nullable NSString *)writeLocalizedPlaylistWithLines:(NSArray<NSString *> *)lines
                                              baseURL:(NSURL *)baseURL
                                               keyMap:(NSDictionary<NSString *, NSString *> *)keyMap
                                      outputDirectory:(NSString *)outputDirectory
                                             fileName:(NSString *)fileName
                                                error:(NSError * _Nullable * _Nullable)error;

/// 判断 index.m3u8 是否已经本地化完成（用于判断任务是否可播放/可视为完成）。
+ (BOOL)isLocalizedIndexPlaylistCompleteAtPath:(NSString *)indexPath outputDirectory:(NSString *)outputDirectory;

@end

NS_ASSUME_NONNULL_END
