#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 任务持久化存储（内部使用）。
///
/// 说明：该类用于管理 tasks.plist 的读写与目录定位，通常业务方无需直接调用。
@interface BszM3u8TaskStore : NSObject

/// 创建 store（会在默认目录下读写 tasks.plist）。
- (instancetype)init;

/// 持久化根目录（绝对路径）。
- (NSString *)storeDirectoryPath;

/// 读取已保存的任务记录。
///
/// @return 字典：taskId -> record（record 为可序列化字典）
- (NSDictionary<NSString *, NSDictionary *> *)loadRecords;

/// 异步/防抖保存（推荐）。
- (void)scheduleSaveWithRecordsSnapshot:(NSArray<NSDictionary *> *)records;

/// 立即保存（会阻塞当前线程直到写入完成）。
- (void)saveImmediatelyWithRecordsSnapshot:(NSArray<NSDictionary *> *)records;

@end

NS_ASSUME_NONNULL_END
