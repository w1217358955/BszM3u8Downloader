#import "BszM3u8TaskStore.h"

static inline void BszExcludeFromBackupAtPath(NSString *path) {
    if (![path isKindOfClass:[NSString class]] || path.length == 0) {
        return;
    }
    NSURL *url = [NSURL fileURLWithPath:path isDirectory:YES];
    NSError *error = nil;
    [url setResourceValue:@(YES) forKey:NSURLIsExcludedFromBackupKey error:&error];
    (void)error;
}

@interface BszM3u8TaskStore ()
@property (nonatomic, strong) dispatch_queue_t persistenceQueue;
@property (nonatomic, assign) uint64_t pendingSaveToken;
@end

@implementation BszM3u8TaskStore

- (instancetype)init {
    self = [super init];
    if (self) {
        _persistenceQueue = dispatch_queue_create("com.bszm3u8.taskstore.persistence", DISPATCH_QUEUE_SERIAL);
        _pendingSaveToken = 0;
    }
    return self;
}

- (NSURL *)tasksStoreURL {
    NSString *dir = [self storeDirectoryPath];
    NSString *filePath = [dir stringByAppendingPathComponent:@"tasks.plist"]; 
    return [NSURL fileURLWithPath:filePath];
}

- (NSString *)storeDirectoryPath {
    // 默认不放 Caches：Caches 可能被系统/用户清理，导致任务目录和索引丢失。
    // 使用 Documents：更方便通过 Finder/iTunes/Files 观察与导出离线资源。
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDir = paths.firstObject;
    if (documentsDir.length == 0) {
        // 极端情况下回退到 Library
        NSArray<NSString *> *libPaths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
        documentsDir = libPaths.firstObject;
    }
    if (documentsDir.length == 0) {
        documentsDir = NSTemporaryDirectory();
    }
    NSString *dir = [documentsDir stringByAppendingPathComponent:@"BszM3u8Downloader"]; 
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    BszExcludeFromBackupAtPath(dir);
    return dir;
}

- (NSDictionary<NSString *, NSDictionary *> *)loadRecords {
    NSURL *url = [self tasksStoreURL];
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data) {
        return @{};
    }

    NSError *error = nil;
    id obj = [NSPropertyListSerialization propertyListWithData:data
                                                      options:NSPropertyListMutableContainersAndLeaves
                                                       format:NULL
                                                        error:&error];
    if (error || ![obj isKindOfClass:[NSArray class]]) {
        return @{};
    }

    NSArray *array = (NSArray *)obj;
    NSMutableDictionary<NSString *, NSDictionary *> *records = [NSMutableDictionary dictionary];
    for (id item in array) {
        if (![item isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSDictionary *dict = (NSDictionary *)item;

        // 只认 taskId；必要时回退 url
        NSString *identifier = dict[@"taskId"];
        if (identifier.length == 0) {
            identifier = dict[@"url"];
        }
        if (identifier.length == 0) {
            continue;
        }

        records[identifier] = dict;
    }

    return records;
}

- (void)scheduleSaveWithRecordsSnapshot:(NSArray<NSDictionary *> *)records {
    if (!records) {
        return;
    }

    @synchronized (self) {
        self.pendingSaveToken += 1;
        uint64_t token = self.pendingSaveToken;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), self.persistenceQueue, ^{
            BOOL shouldSave = NO;
            @synchronized (self) {
                shouldSave = (token == self.pendingSaveToken);
            }
            if (!shouldSave) {
                return;
            }
            [self writeRecordsSnapshot:records];
        });
    }
}

- (void)saveImmediatelyWithRecordsSnapshot:(NSArray<NSDictionary *> *)records {
    if (!records) {
        return;
    }

    dispatch_async(self.persistenceQueue, ^{
        [self writeRecordsSnapshot:records];
    });
}

- (void)writeRecordsSnapshot:(NSArray<NSDictionary *> *)records {
    NSURL *url = [self tasksStoreURL];
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:records
                                                             format:NSPropertyListBinaryFormat_v1_0
                                                            options:0
                                                              error:&error];
    if (error || !data) {
        return;
    }
    [data writeToURL:url atomically:YES];
}

@end
