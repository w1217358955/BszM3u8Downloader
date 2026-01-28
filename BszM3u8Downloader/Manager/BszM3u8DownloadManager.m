#import "BszM3u8DownloadManager.h"
#import "BszM3u8DownloaderCore.h"
#import "Storage/BszM3u8TaskStore.h"
#import "BszM3u8Tool.h"
#import <objc/runtime.h>
#if __has_include(<UIKit/UIKit.h>)
#import <UIKit/UIKit.h>
#endif

static inline uint32_t BszFNV1a32ForString(NSString *s) {
    if (s.length == 0) {
        return 0;
    }
    NSData *data = [s dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *p = (const uint8_t *)data.bytes;
    uint32_t hash = 2166136261u;
    for (NSUInteger i = 0; i < data.length; i++) {
        hash ^= (uint32_t)p[i];
        hash *= 16777619u;
    }
    return hash;
}

static inline NSString *BszStableDirNameForKey(NSString *key) {
    NSString *k = key.length ? key : @"default";
    uint32_t h = BszFNV1a32ForString(k);

    // 取一个可读的短前缀（来自 key 的最后一段），再拼 hash，避免目录名过长/冲突。
    NSString *prefix = k;
    NSRange lastSlash = [prefix rangeOfString:@"/" options:NSBackwardsSearch];
    if (lastSlash.location != NSNotFound && lastSlash.location + 1 < prefix.length) {
        prefix = [prefix substringFromIndex:lastSlash.location + 1];
    }
    prefix = [prefix stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (prefix.length == 0) {
        prefix = @"task";
    }

    // 过滤常见非法/容易出问题的字符
    NSCharacterSet *invalid = [NSCharacterSet characterSetWithCharactersInString:@"/:\\?&=#\""]; 
    prefix = [[prefix componentsSeparatedByCharactersInSet:invalid] componentsJoinedByString:@"_"];
    if (prefix.length > 40) {
        prefix = [prefix substringToIndex:40];
    }

    return [NSString stringWithFormat:@"%@_%08x", prefix, h];
}

// 状态过滤工具（内联以减少重复代码）
static inline BOOL BszStatusAny(BszM3u8DownloadStatus s) { return YES; }
// 将 Ready 视为“未完成队列中的活跃项”，便于 UI 同时展示排队任务
static inline BOOL BszStatusActive(BszM3u8DownloadStatus s) { return s == BszM3u8DownloadStatusDownloading || s == BszM3u8DownloadStatusStarting || s == BszM3u8DownloadStatusPaused || s == BszM3u8DownloadStatusReady; }
static inline BOOL BszStatusCompleted(BszM3u8DownloadStatus s) { return s == BszM3u8DownloadStatusCompleted; }

static inline NSNumber *BszRecordIntegerNumber(id val) {
    if ([val isKindOfClass:[NSNumber class]]) {
        return (NSNumber *)val;
    }
    if ([val isKindOfClass:[NSString class]]) {
        return @([(NSString *)val integerValue]);
    }
    return nil;
}

static inline NSNumber *BszRecordDoubleNumber(id val) {
    if ([val isKindOfClass:[NSNumber class]]) {
        return (NSNumber *)val;
    }
    if ([val isKindOfClass:[NSString class]]) {
        return @([(NSString *)val doubleValue]);
    }
    return nil;
}

static inline NSString *BszRecordString(id val) {
    return [val isKindOfClass:[NSString class]] ? (NSString *)val : nil;
}

static inline NSDictionary *BszRecordDictionary(id val) {
    return [val isKindOfClass:[NSDictionary class]] ? (NSDictionary *)val : nil;
}

static inline NSString *BszNormalizePathString(NSString *path) {
    if (![path isKindOfClass:[NSString class]] || path.length == 0) {
        return nil;
    }
    NSString *normalized = [path stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([normalized hasPrefix:@"file://"]) {
        NSURL *u = [NSURL URLWithString:normalized];
        if (u.isFileURL && u.path.length > 0) {
            normalized = u.path;
        }
    }
    normalized = [normalized stringByStandardizingPath];
    return normalized.length ? normalized : nil;
}

static inline void BszExcludeFromBackupAtPath(NSString *path) {
    NSString *p = BszNormalizePathString(path);
    if (p.length == 0) {
        return;
    }
    NSURL *url = [NSURL fileURLWithPath:p isDirectory:YES];
    NSError *error = nil;
    [url setResourceValue:@(YES) forKey:NSURLIsExcludedFromBackupKey error:&error];
    (void)error;
}

// 用 queue-specific 避免在同一串行队列上嵌套 dispatch_sync 导致死锁
static void *BszManagerSyncQueueKey = &BszManagerSyncQueueKey;

static inline void BszDispatchSyncSafe(dispatch_queue_t queue, void *key, dispatch_block_t block) {
    if (!queue || !block) {
        return;
    }
    if (dispatch_get_specific(key)) {
        block();
    } else {
        dispatch_sync(queue, block);
    }
}

static inline void BszDispatchAsyncSafe(dispatch_queue_t queue, dispatch_block_t block) {
    if (!queue || !block) {
        return;
    }
    dispatch_async(queue, block);
}

// 内部扩展：用于 deleteAll 时静默取消，不对外暴露
@interface BszM3u8Downloader (DeletionInternal)
- (void)cancelSilentlyForDeletion;
@end

// 内部扩展：允许管理器在排队时更新状态并同步持久化
@interface BszM3u8Downloader (StatusInternal)
@property (nonatomic, assign, readwrite) BszM3u8DownloadStatus downloadStatus;
- (void)syncStatusToManager;
@end

@implementation BszM3u8DownloadTaskInfo
@end

@interface BszM3u8DownloadManager ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, BszM3u8Downloader *> *downloaderMap; // key: taskKey (taskId or urlString)
@property (nonatomic, strong) dispatch_queue_t syncQueue;
@property (nonatomic, strong) BszM3u8TaskStore *taskStore;
// 持久化的任务记录，key 为 taskKey（taskId 或 urlString），value 为字典（taskId/url/outputDir/ext/status/progress/...）
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *storedTaskRecords;
// 运行期记录（不落盘）：速度等，key 为 taskId
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary *> *runtimeTaskRecords;
// 可选的外部指定下载根目录；若为空则使用默认目录（Documents/...）
@property (nonatomic, copy, nullable) NSString *downloadRootDirectory;
// 任务级并发控制队列（按 taskKey 顺序）
@property (nonatomic, strong) NSMutableOrderedSet<NSString *> *pendingStartQueue;
// 任务并发上限（内部使用，外部不可改）
@property (nonatomic, assign, readonly) NSInteger maxConcurrentTasks;
// 全局“全部暂停”开关：为 YES 时，不应启动新的任务
@property (atomic, assign, getter=isAllPaused) BOOL allPaused;
// 全局删除开关：为 YES 时，忽略来自 downloader 的状态持久化
@property (atomic, assign, getter=isDeletingAll) BOOL deletingAll;
#if __has_include(<UIKit/UIKit.h>)
@property (atomic, assign) BOOL hasEnteredBackground;
#endif
@end

static const void *BszManagerCallbacksInstalledKey = &BszManagerCallbacksInstalledKey;

@implementation BszM3u8DownloadManager

// 将持久化的 outputDir（相对/绝对）解析为当前运行时可用的绝对路径
- (NSString *)absoluteOutputDirFromStoredValue:(NSString *)storedOutputDir {
    NSString *v = BszNormalizePathString(storedOutputDir);
    if (v.length == 0) {
        return nil;
    }
    if ([v isAbsolutePath]) {
        return v;
    }

    // 相对路径：拼接当前沙盒下的 storeDirectoryPath
    NSString *baseDir = [self.taskStore storeDirectoryPath];
    if (baseDir.length == 0) {
        return v;
    }
    return [[baseDir stringByAppendingPathComponent:v] stringByStandardizingPath];
}

// 将运行时的绝对 outputDir 转为持久化值：优先保存为相对路径（相对 storeDirectoryPath）
- (NSString *)storedOutputDirValueFromAbsolutePath:(NSString *)absoluteOutputDir {
    NSString *abs = BszNormalizePathString(absoluteOutputDir);
    if (abs.length == 0) {
        return nil;
    }

    // 若在默认 storeDirectoryPath 下，保存为相对路径，避免沙盒根路径变化导致失效
    NSString *baseDir = BszNormalizePathString([self.taskStore storeDirectoryPath]);
    if (baseDir.length > 0 && [abs hasPrefix:baseDir]) {
        NSString *rel = [abs substringFromIndex:baseDir.length];
        while ([rel hasPrefix:@"/"]) {
            rel = [rel substringFromIndex:1];
        }
        if (rel.length > 0) {
            return rel;
        }
    }

    // 其他情况（例如外部自定义 downloadRootDirectory）：保持绝对路径
    return abs;
}

- (void)installManagerCallbacksIfNeededForDownloader:(BszM3u8Downloader *)downloader {
    if (!downloader) {
        return;
    }
    if (objc_getAssociatedObject(downloader, BszManagerCallbacksInstalledKey)) {
        return;
    }
    objc_setAssociatedObject(downloader, BszManagerCallbacksInstalledKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak typeof(self) weakSelf = self;
    NSString *taskId = downloader.identifier ?: downloader.urlString;

    BOOL (^delegateWantsTaskInfo)(void) = ^BOOL{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) { return NO; }
        id<BszM3u8DownloadManagerDelegate> delegate = self.delegate;
        return [delegate respondsToSelector:@selector(downloadManager:didUpdateTaskInfo:error:)];
    };


    void (^emitTaskInfoIfNeeded)(NSError * _Nullable error) = ^(NSError * _Nullable error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) { return; }
        id<BszM3u8DownloadManagerDelegate> delegate = self.delegate;
        if (![delegate respondsToSelector:@selector(downloadManager:didUpdateTaskInfo:error:)]) {
            return;
        }
        BszM3u8DownloadTaskInfo *info = [self taskInfoForTaskId:taskId];
        if (!info) { return; }
        dispatch_async(dispatch_get_main_queue(), ^{
            [delegate downloadManager:self didUpdateTaskInfo:info error:error];
        });
    };

    // progress
    BszM3u8DownloadProgressBlock oldProgress = downloader.downloadFileProgressExeBlock;
    downloader.downloadFileProgressExeBlock = ^(float progress) {
        if (oldProgress) { oldProgress(progress); }
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) { return; }

        // runtime: progress 本身在 downloader 里，额外信息不需要落这里
        if (delegateWantsTaskInfo()) {
            emitTaskInfoIfNeeded(nil);
        }
    };

    // finished/total
    BszM3u8DownloadStatusBlock oldCount = downloader.downloadM3U8StatusExeBlock;
    downloader.downloadM3U8StatusExeBlock = ^(NSInteger finishedCount, NSInteger totalCount) {
        if (oldCount) { oldCount(finishedCount, totalCount); }
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) { return; }

        if (delegateWantsTaskInfo()) {
            emitTaskInfoIfNeeded(nil);
        }
    };

    // speed
    BszM3u8DownloadSpeedBlock oldSpeed = downloader.downloadSpeedUpdateExeBlock;
    downloader.downloadSpeedUpdateExeBlock = ^(double bytesPerSecond) {
        if (oldSpeed) { oldSpeed(bytesPerSecond); }
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) { return; }

        // runtime: 记录速度，供 taskInfo 查询/列表展示
        [self withSyncQueue:^{
            NSMutableDictionary *rt = self.runtimeTaskRecords[taskId];
            if (!rt) {
                rt = [NSMutableDictionary dictionary];
                self.runtimeTaskRecords[taskId] = rt;
            }
            rt[@"speed"] = @(bytesPerSecond);
        }];

        if (delegateWantsTaskInfo()) {
            emitTaskInfoIfNeeded(nil);
        }
    };

    // error
    BszM3u8DownloadTSFailureBlock oldFail = downloader.downloadTSFailureExeBlock;
    downloader.downloadTSFailureExeBlock = ^(NSString *tsFileName, NSError *error) {
        if (oldFail) { oldFail(tsFileName, error); }
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) { return; }

        if (delegateWantsTaskInfo()) {
            emitTaskInfoIfNeeded(error);
        }
    };

    // status - 用生命周期 block 来触发一次状态事件（最终 status 由 downloader.downloadStatus 提供）
    void (^statusEmit)(void) = ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) { return; }
        if (delegateWantsTaskInfo()) {
            emitTaskInfoIfNeeded(nil);
        }
    };

    BszM3u8DownloadSimpleEventBlock oldStart = downloader.downloadStartExeBlock;
    downloader.downloadStartExeBlock = ^{ if (oldStart) { oldStart(); } statusEmit(); };

    BszM3u8DownloadSimpleEventBlock oldPaused = downloader.downloadPausedExeBlock;
    downloader.downloadPausedExeBlock = ^{ if (oldPaused) { oldPaused(); } statusEmit(); };

    BszM3u8DownloadSimpleEventBlock oldResume = downloader.downloadResumeExeBlock;
    downloader.downloadResumeExeBlock = ^{ if (oldResume) { oldResume(); } statusEmit(); };

    BszM3u8DownloadSimpleEventBlock oldStop = downloader.downloadStopExeBlock;
    downloader.downloadStopExeBlock = ^{ if (oldStop) { oldStop(); } statusEmit(); };

    BszM3u8DownloadSimpleEventBlock oldComplete = downloader.downloadCompleteExeBlock;
    downloader.downloadCompleteExeBlock = ^{ if (oldComplete) { oldComplete(); } statusEmit(); };

    // 初始状态也推一次
    statusEmit();
}

+ (instancetype)sharedManager {
    static BszM3u8DownloadManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[BszM3u8DownloadManager alloc] initPrivate];
    });
    return instance;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _downloaderMap = [NSMutableDictionary dictionary];
        _syncQueue = dispatch_queue_create("com.ocm3u8.manager.sync", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_syncQueue, BszManagerSyncQueueKey, BszManagerSyncQueueKey, NULL);
        _taskStore = [[BszM3u8TaskStore alloc] init];
        _storedTaskRecords = [NSMutableDictionary dictionary];
        _runtimeTaskRecords = [NSMutableDictionary dictionary];
        _pendingStartQueue = [NSMutableOrderedSet orderedSet];
        _maxConcurrentTasks = 3;
        _allPaused = NO;
        _deletingAll = NO;
#if __has_include(<UIKit/UIKit.h>)
                _hasEnteredBackground = NO;
                [[NSNotificationCenter defaultCenter] addObserver:self
                                                                                                 selector:@selector(handleDidEnterBackground)
                                                                                                         name:UIApplicationDidEnterBackgroundNotification
                                                                                                     object:nil];
                [[NSNotificationCenter defaultCenter] addObserver:self
                                                                                                 selector:@selector(handleDidBecomeActive)
                                                                                                         name:UIApplicationDidBecomeActiveNotification
                                                                                                     object:nil];
#endif
        [self loadStoredTasksIfNeeded];
    }
    return self;
}

#pragma mark - SyncQueue helpers

- (void)withSyncQueue:(dispatch_block_t)block {
    BszDispatchSyncSafe(self.syncQueue, BszManagerSyncQueueKey, block);
}

- (instancetype)init {
    @throw [NSException exceptionWithName:@"BszM3u8DownloadManagerInitError"
                                   reason:@"Use +[BszM3u8DownloadManager sharedManager] instead."
                                 userInfo:nil];
}

#if __has_include(<UIKit/UIKit.h>)
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)handleDidEnterBackground {
    self.hasEnteredBackground = YES;
    [self pauseAll];
}

- (void)handleDidBecomeActive {
    if (!self.hasEnteredBackground) {
        return;
    }
    self.hasEnteredBackground = NO;
    // 只有“真的进入过后台”的场景才自动恢复。
    // 冷启动/被杀进程重启不会触发 handleDidEnterBackground，因此不会自动恢复。
    [self resumeAll];
}
#endif

// 根据任务 key 生成默认输出目录（位于应用沙盒的 BszM3u8Downloader/downloads/ 下；默认不使用 Caches）
- (NSString *)defaultOutputDirForKey:(NSString *)key {
    NSString *downloadsDir = nil;
    if (self.downloadRootDirectory.length > 0) {
        downloadsDir = self.downloadRootDirectory;
    } else {
        NSString *baseDir = [self.taskStore storeDirectoryPath];
        downloadsDir = [baseDir stringByAppendingPathComponent:@"downloads"];
    }
    [[NSFileManager defaultManager] createDirectoryAtPath:downloadsDir withIntermediateDirectories:YES attributes:nil error:nil];
    BszExcludeFromBackupAtPath(downloadsDir);

    NSString *stableDirName = BszStableDirNameForKey(key);
    return [downloadsDir stringByAppendingPathComponent:stableDirName];
}

- (void)setDownloadRootDirectory:(NSString *)directoryPath {
    if (directoryPath.length == 0) {
        self.downloadRootDirectory = nil;
        return;
    }
    // 确保目录存在
    [[NSFileManager defaultManager] createDirectoryAtPath:directoryPath withIntermediateDirectories:YES attributes:nil error:nil];
    BszExcludeFromBackupAtPath(directoryPath);
    self.downloadRootDirectory = [directoryPath copy];
}

- (BszM3u8Downloader *)existingDownloaderForTaskId:(NSString *)taskId {
    if (taskId.length == 0) {
        return nil;
    }
    __block BszM3u8Downloader *d = nil;
    [self withSyncQueue:^{
        d = self.downloaderMap[taskId];
    }];
    return d;
}


- (BszM3u8Downloader *)startTaskWithTaskId:(NSString *)taskId
                       urlString:(NSString *)urlString
                           ext:(NSDictionary<NSString *, NSString *> *)ext {
    if (urlString.length == 0) {
        return nil;
    }

    NSString *identifier = taskId; // 内部仍以 identifier 作为 key
    NSString *key = identifier.length ? identifier : urlString;
    __block BszM3u8Downloader *downloader = nil;
    __block BOOL needCreateRecord = NO;
    __block BOOL isNewDownloader = NO;
    __block NSString *resolvedOutputDir = nil;
    __block BOOL hasRecord = NO;
    __block NSNumber *recordStatusNumber = nil;
    __block NSNumber *recordProgressNumber = nil;

    [self withSyncQueue:^{
        NSDictionary *record = self.storedTaskRecords[key];
        hasRecord = (record != nil);
        recordStatusNumber = BszRecordIntegerNumber(record[@"status"]);
        recordProgressNumber = BszRecordDoubleNumber(record[@"progress"]);
        if (!resolvedOutputDir.length) {
            NSString *storedDir = BszRecordString(record[@"outputDir"]);
            if (storedDir.length) {
                resolvedOutputDir = [self absoluteOutputDirFromStoredValue:storedDir] ?: storedDir;
            }
        }
        if (!resolvedOutputDir.length) {
            resolvedOutputDir = [self defaultOutputDirForKey:key];
        }

        // 如果记录已被删除但本地目录仍存在（可能上次删除失败），清理旧目录以避免误判“已完成”
        if (!hasRecord && resolvedOutputDir.length) {
            BOOL isDir = NO;
            if ([[NSFileManager defaultManager] fileExistsAtPath:resolvedOutputDir isDirectory:&isDir] && isDir) {
                NSError *removeError = nil;
                if (![[NSFileManager defaultManager] removeItemAtPath:resolvedOutputDir error:&removeError]) {
#if DEBUG
                    NSLog(@"[BszM3u8DownloadManager] cleanup leftover dir failed: %@ | error=%@", resolvedOutputDir, removeError.localizedDescription ?: @"unknown");
#endif
                }
                NSError *createError = nil;
                if (![[NSFileManager defaultManager] createDirectoryAtPath:resolvedOutputDir withIntermediateDirectories:YES attributes:nil error:&createError]) {
#if DEBUG
                    NSLog(@"[BszM3u8DownloadManager] recreate dir failed: %@ | error=%@", resolvedOutputDir, createError.localizedDescription ?: @"unknown");
#endif
                }
            }
        }

        downloader = self.downloaderMap[key];
        if (!downloader) {
            downloader = [[BszM3u8Downloader alloc] initWithURLString:urlString
                                                                    outputPath:resolvedOutputDir
                                                                           ext:ext
                                                                identifier:identifier];

            // 如果已有持久化记录，尽量沿用其状态（避免新建实例把任务看成 NotReady）
            if (recordStatusNumber) {
                BszM3u8DownloadStatus st = (BszM3u8DownloadStatus)recordStatusNumber.integerValue;
                if (st != BszM3u8DownloadStatusCompleted) {
                    downloader.downloadStatus = st;
                }
            }
            self.downloaderMap[key] = downloader;

            if (!record) {
                needCreateRecord = YES;
            }
            isNewDownloader = YES;
        }
    }];

    if (needCreateRecord) {
                [self updateStoredRecordForTaskId:key
                                     urlString:urlString
                                     outputDir:resolvedOutputDir
                                           ext:ext
                                       status:downloader.downloadStatus
                                     progress:downloader.progress
                                     createdAt:nil];
    }

    // 如果是新创建的 downloader 但已有持久化记录，补齐 createdAt 并同步记录其余字段
    if (isNewDownloader && !needCreateRecord) {
                NSNumber *createdAt = [self createdAtForIdentifier:key allowCreate:YES];
                BszM3u8DownloadStatus preservedStatus = (BszM3u8DownloadStatus)(recordStatusNumber ? recordStatusNumber.integerValue : downloader.downloadStatus);
                double preservedProgress = recordProgressNumber ? recordProgressNumber.doubleValue : downloader.progress;
        [self updateStoredRecordForTaskId:key
                                     urlString:urlString
                                     outputDir:resolvedOutputDir
                                           ext:ext
                                                                             status:preservedStatus
                                                                         progress:preservedProgress
                                     createdAt:createdAt];
    }

    // 统一回调出口：确保每个 downloader 都安装一次 manager 回调汇聚器
    [self installManagerCallbacksIfNeededForDownloader:downloader];
    return downloader;
}

- (NSArray<BszM3u8Downloader *> *)allDownloaderInstances {
    __block NSArray<BszM3u8Downloader *> *list = nil;
    [self withSyncQueue:^{
        list = self.downloaderMap.allValues;
    }];
    return list ?: @[];
}

// 获取任务创建时间；直接以持久化记录为准，必要时补写
- (NSNumber *)createdAtForIdentifier:(NSString *)identifier allowCreate:(BOOL)allowCreate {
    if (identifier.length == 0) {
        return nil;
    }

    __block NSNumber *recordTs = nil;
    [self withSyncQueue:^{
        NSDictionary *record = self.storedTaskRecords[identifier];
        id val = record[@"createdAt"];
        if ([val isKindOfClass:[NSNumber class]]) {
            recordTs = val;
        } else if ([val isKindOfClass:[NSString class]]) {
            recordTs = @([(NSString *)val doubleValue]);
        }
        if (!recordTs && allowCreate) {
            NSNumber *nowTs = @([[NSDate date] timeIntervalSince1970]);
            NSMutableDictionary *mutable = [record mutableCopy] ?: [NSMutableDictionary dictionary];
            mutable[@"createdAt"] = nowTs;
            self.storedTaskRecords[identifier] = [mutable copy];
            recordTs = nowTs;
            [self saveStoredTasksSafely];
        }
    }];

    return recordTs;
}

#pragma mark - Task-level concurrency

- (NSInteger)currentActiveDownloadingCountLocked {
    // 调用方需确保已在 syncQueue 内
    __block NSInteger count = 0;
    [self.downloaderMap enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, BszM3u8Downloader * _Nonnull d, BOOL * _Nonnull stop) {
        if (d.downloadStatus == BszM3u8DownloadStatusStarting ||
            d.downloadStatus == BszM3u8DownloadStatusDownloading) {
            count += 1;
        }
    }];
    return count;
}

// 线程安全统计当前“活跃下载”数量
- (NSInteger)currentActiveDownloadingCount {
    __block NSInteger count = 0;
    [self withSyncQueue:^{
        count = [self currentActiveDownloadingCountLocked];
    }];
    return count;
}

- (BOOL)requestStartForDownloader:(BszM3u8Downloader *)downloader {
    if (!downloader.identifier.length) {
        return YES; // 无标识时不做并发限制
    }

    __block BOOL allow = YES;
    NSString *identifier = downloader.identifier;

    [self withSyncQueue:^{
        if (self.allPaused) {
            // 允许用户手动启动单个任务：此时认为用户已解除“全局暂停”。
            // 全局暂停只应阻止“自动拉起队列任务”，不应让手动点击 Start 变成 Ready 卡住。
            self.allPaused = NO;
        }

        NSInteger max = self.maxConcurrentTasks;
        if (max <= 0) {
            // 不限制任务级并发
            allow = YES;
            [self.pendingStartQueue removeObject:identifier];
            return;
        }

        NSInteger activeCount = [self currentActiveDownloadingCountLocked];
        if (activeCount >= max) {
            allow = NO;
            if (![self.pendingStartQueue containsObject:identifier]) {
                [self.pendingStartQueue addObject:identifier];
            }
        } else {
            allow = YES;
            [self.pendingStartQueue removeObject:identifier];
        }
    }];

    return allow;
}

- (void)downloader:(BszM3u8Downloader *)downloader didChangeStatus:(BszM3u8DownloadStatus)status {
    if (!downloader.identifier.length) {
        return;
    }

    if (self.deletingAll) {
        return;
    }

    // 全局暂停期间，不自动拉起任何等待任务
    if (self.allPaused) {
        return;
    }

    // 仅当任务从“活跃”退出时，尝试拉起队列中的下一个
    if (status == BszM3u8DownloadStatusStarting || status == BszM3u8DownloadStatusDownloading) {
        return;
    }

    BszDispatchAsyncSafe(self.syncQueue, ^{
        if (status == BszM3u8DownloadStatusPaused ||
            status == BszM3u8DownloadStatusStopped ||
            status == BszM3u8DownloadStatusCompleted) {
            [self.pendingStartQueue removeObject:downloader.identifier];
        }

        [self startQueuedDownloadersIfPossibleInternal];
    });
}

// 在锁内挑选可启动的任务，锁外触发 start/resume，避免死锁
- (void)startQueuedDownloadersIfPossibleInternal {
    __block NSArray<BszM3u8Downloader *> *toStart = nil;

    void (^collectBlock)(void) = ^{
        if (self.allPaused) {
            toStart = @[];
            return;
        }
        NSInteger max = self.maxConcurrentTasks;
        if (max <= 0 || self.pendingStartQueue.count == 0) {
            toStart = @[];
            return;
        }

        NSInteger activeCount = [self currentActiveDownloadingCountLocked];
        if (activeCount >= max) {
            toStart = @[];
            return;
        }

        NSMutableArray<BszM3u8Downloader *> *list = [NSMutableArray array];
        while (activeCount < max && self.pendingStartQueue.count > 0) {
            // 选出“最早创建”的任务优先启动，保持与创建时序一致
            NSString *selectedIdentifier = nil;
            NSNumber *selectedTs = nil;
            for (NSString *identifier in self.pendingStartQueue) {
                NSNumber *ts = [self createdAtForIdentifier:identifier allowCreate:YES];
                if (!selectedIdentifier) {
                    selectedIdentifier = identifier;
                    selectedTs = ts;
                    continue;
                }
                if (ts && selectedTs) {
                    if ([ts compare:selectedTs] == NSOrderedAscending) {
                        selectedIdentifier = identifier;
                        selectedTs = ts;
                    }
                } else if (ts && !selectedTs) {
                    selectedIdentifier = identifier;
                    selectedTs = ts;
                }
            }
            if (!selectedIdentifier) {
                selectedIdentifier = self.pendingStartQueue.firstObject;
            }
            [self.pendingStartQueue removeObject:selectedIdentifier];

            BszM3u8Downloader *pendingDownloader = self.downloaderMap[selectedIdentifier];
            if (!pendingDownloader) {
                continue;
            }
            if (pendingDownloader.downloadStatus == BszM3u8DownloadStatusCompleted) {
                continue;
            }

            [list addObject:pendingDownloader];
            activeCount += 1;
        }

        toStart = list.copy;
    };

    [self withSyncQueue:collectBlock];

    for (BszM3u8Downloader *pending in toStart) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (pending.downloadStatus == BszM3u8DownloadStatusPaused) {
                [pending resume];
            } else {
                [pending start];
            }
        });
    }
}

- (void)startQueuedDownloadersIfPossible {
    [self startQueuedDownloadersIfPossibleInternal];
}

// 通用构建任务列表，带状态过滤、去重、可选 index.m3u8 校验，并按创建时间排序
- (NSArray<BszM3u8DownloadTaskInfo *> *)taskInfosMatching:(BOOL (*)(BszM3u8DownloadStatus status))predicate
                                  needIndexCheck:(BOOL)needIndexCheck
                                      ascending:(BOOL)ascending {
    __block NSDictionary<NSString *, NSDictionary *> *runtimeSnapshot = nil;
    [self withSyncQueue:^{
        runtimeSnapshot = self.runtimeTaskRecords.copy;
    }];

    NSMutableArray<BszM3u8DownloadTaskInfo *> *result = [NSMutableArray array];
    // 按 identifier 去重（taskId 唯一；若为空回退 url）
    NSMutableSet<NSString *> *existingIds = [NSMutableSet set];

    // 1) 内存中的 downloader
    for (BszM3u8Downloader *d in [self allDownloaderInstances]) {
        BszM3u8DownloadStatus status = d.downloadStatus;
        if (predicate && !predicate(status)) {
            continue;
        }

        NSString *identifier = d.identifier ?: d.urlString;
        BszM3u8DownloadTaskInfo *info = [[BszM3u8DownloadTaskInfo alloc] init];
        info.taskId = identifier;
        info.urlString = d.urlString;
        info.outputDir = d.outputPath;
        info.ext = d.ext;
        info.progress = d.progress;
        info.status = status;
        NSDictionary *rt = runtimeSnapshot[identifier];
        if ([rt isKindOfClass:[NSDictionary class]]) {
            NSNumber *speedNum = rt[@"speed"]; if ([speedNum isKindOfClass:[NSNumber class]]) { info.speedBytesPerSecond = speedNum.doubleValue; }
        }
        NSNumber *createdAt = [self createdAtForIdentifier:identifier allowCreate:YES];
        info.createdAt = createdAt;
        [result addObject:info];
        if (identifier.length) {
            [existingIds addObject:identifier];
        }

           [self updateStoredRecordForTaskId:identifier
                                      urlString:d.urlString
                                      outputDir:d.outputPath
                                           ext:d.ext
                                      status:status
                                    progress:d.progress
                                     createdAt:createdAt];
    }

    // 2) 持久化记录
    [self withSyncQueue:^{
        [self.storedTaskRecords enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, NSDictionary * _Nonnull obj, BOOL * _Nonnull stop) {
            NSNumber *statusNum = obj[@"status"];
            BszM3u8DownloadStatus status = (BszM3u8DownloadStatus)statusNum.integerValue;
            if (predicate && !predicate(status)) {
                return;
            }

            NSString *url = obj[@"url"];
            if ([existingIds containsObject:key]) {
                return;
            }

            NSString *outputDir = [self absoluteOutputDirFromStoredValue:BszRecordString(obj[@"outputDir"])];
            NSDictionary *ext = obj[@"ext"];
            NSNumber *progressNum = obj[@"progress"];

            // 自愈：若离线目录被外部清理/删除（例如用户清理存储、卸载重装后残留记录等），
            // 则回退为 Stopped，并清空无效 outputDir，避免后续本地播放 404 / 路径不存在。
            if (outputDir.length > 0) {
                BOOL outIsDir = NO;
                if (![[NSFileManager defaultManager] fileExistsAtPath:outputDir isDirectory:&outIsDir] || !outIsDir) {
                    status = BszM3u8DownloadStatusStopped;
                    NSMutableDictionary *newObj = obj.mutableCopy;
                    newObj[@"status"] = @(status);
                    newObj[@"progress"] = @(0.0f);
                    [newObj removeObjectForKey:@"outputDir"];
                    self.storedTaskRecords[key] = newObj.copy;
                    outputDir = nil;
                    progressNum = @(0.0f);
                }
            }

            if (needIndexCheck && outputDir.length > 0) {
                BOOL isDir = NO;
                NSString *indexPath = [outputDir stringByAppendingPathComponent:@"index.m3u8"];
                if (![[NSFileManager defaultManager] fileExistsAtPath:indexPath isDirectory:&isDir] || isDir) {
                    return;
                }
            }

            BszM3u8DownloadTaskInfo *info = [[BszM3u8DownloadTaskInfo alloc] init];
            info.taskId = key;
            info.urlString = url;
            info.outputDir = outputDir;
            info.ext = ext;
            info.progress = progressNum.floatValue;
            info.status = status;
            NSDictionary *rt = runtimeSnapshot[key];
            if ([rt isKindOfClass:[NSDictionary class]]) {
                NSNumber *speedNum = rt[@"speed"]; if ([speedNum isKindOfClass:[NSNumber class]]) { info.speedBytesPerSecond = speedNum.doubleValue; }
            }
            info.createdAt = obj[@"createdAt"];
            [result addObject:info];
            if (key.length) {
                [existingIds addObject:key];
            }
        }];
    }];

    // 按创建时间排序（默认正序；ascending=NO 时倒序）
    [result sortUsingComparator:^NSComparisonResult(BszM3u8DownloadTaskInfo * _Nonnull a, BszM3u8DownloadTaskInfo * _Nonnull b) {
        double ca = a.createdAt.doubleValue;
        double cb = b.createdAt.doubleValue;
        if (ca == cb) {
            return NSOrderedSame;
        }
        NSComparisonResult cmp = (ca < cb) ? NSOrderedAscending : NSOrderedDescending;
        return ascending ? cmp : (cmp == NSOrderedAscending ? NSOrderedDescending : (cmp == NSOrderedDescending ? NSOrderedAscending : cmp));
    }];

    [self saveStoredTasksSafely];
    return result.copy;
}

- (NSArray<BszM3u8DownloadTaskInfo *> *)allDownloadersAscending:(BOOL)ascending {
    return [self taskInfosMatching:BszStatusAny needIndexCheck:NO ascending:ascending];
}

- (NSDictionary<NSString *, NSString *> *)dictionaryFromTaskInfo:(BszM3u8DownloadTaskInfo *)info {
    if (!info) {
        return @{};
    }

    // 先统一写回持久化，保证输出字典基于最新记录
    NSString *taskId = info.taskId.length ? info.taskId : info.urlString;
    if (taskId.length && info.urlString.length && info.outputDir.length) {
                [self updateStoredRecordForTaskId:taskId
                                      urlString:info.urlString
                                      outputDir:info.outputDir
                                            ext:info.ext
                                         status:info.status
                                       progress:info.progress
                                       createdAt:info.createdAt];
    }

    NSMutableDictionary<NSString *, NSString *> *dict = [NSMutableDictionary dictionary];
    if (taskId.length) {
        // 新字段
        dict[@"taskId"] = taskId;
    }
    if (info.urlString) {
        dict[@"urlString"] = info.urlString;
    }
    if (info.outputDir) {
        dict[@"outputDir"] = info.outputDir;
    }
    if (info.ext.count > 0) {
        // ext 本身就是 <NSString *, NSString *>，直接序列化为 JSON 字符串存放
        NSError *error = nil;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:info.ext options:0 error:&error];
        if (jsonData && !error) {
            NSString *extString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
            if (extString.length > 0) {
                dict[@"ext"] = extString;
            }
        }
    }
    dict[@"progress"] = [NSString stringWithFormat:@"%.6f", info.progress];
    dict[@"status"] = [NSString stringWithFormat:@"%ld", (long)info.status];
    if (info.speedBytesPerSecond > 0) {
        dict[@"speed"] = [NSString stringWithFormat:@"%.0f", info.speedBytesPerSecond];
    }
    if (info.createdAt) {
        // taskDic 对外用于排序：使用毫秒时间戳字符串，避免并发创建落在同一秒导致顺序不稳定
        long long createdAtMs = (long long)llround(info.createdAt.doubleValue * 1000.0);
        dict[@"createdAt"] = [NSString stringWithFormat:@"%lld", createdAtMs];
    }
    return dict.copy;
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)allTaskDicsAscending:(BOOL)ascending {
    return [self taskDicsMatching:BszStatusAny needIndexCheck:NO ascending:ascending];
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)currentDownloadingTaskDicsAscending:(BOOL)ascending {
    return [self taskDicsMatching:BszStatusActive needIndexCheck:NO ascending:ascending];
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)completedTaskDicsAscending:(BOOL)ascending {
    return [self taskDicsMatching:BszStatusCompleted needIndexCheck:YES ascending:ascending];
}

// 通用生成任务字典数组
- (NSArray<NSDictionary<NSString *, NSString *> *> *)taskDicsMatching:(BOOL (*)(BszM3u8DownloadStatus status))predicate
                                                      needIndexCheck:(BOOL)needIndexCheck
                                                           ascending:(BOOL)ascending {
    NSArray<BszM3u8DownloadTaskInfo *> *infos = [self taskInfosMatching:predicate needIndexCheck:needIndexCheck ascending:ascending];
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *result = [NSMutableArray arrayWithCapacity:infos.count];
    for (BszM3u8DownloadTaskInfo *info in infos) {
        [result addObject:[self dictionaryFromTaskInfo:info]];
    }
    return result.copy;
}

- (NSArray<BszM3u8DownloadTaskInfo *> *)currentDownloadingTasksAscending:(BOOL)ascending {
    return [self taskInfosMatching:BszStatusActive needIndexCheck:NO ascending:ascending];
}

- (NSArray<BszM3u8DownloadTaskInfo *> *)completedTasksAscending:(BOOL)ascending {
    return [self taskInfosMatching:BszStatusCompleted needIndexCheck:YES ascending:ascending];
}

- (void)pauseAll {
    // 清空等待队列，防止已有等待任务被拉起
    [self withSyncQueue:^{
        self.allPaused = YES;
        [self.pendingStartQueue removeAllObjects];
    }];

    for (BszM3u8Downloader *d in [self allDownloaderInstances]) {
        BszM3u8DownloadStatus status = d.downloadStatus;
        if (status == BszM3u8DownloadStatusPaused) {
            continue;
        }
        if (status == BszM3u8DownloadStatusReady) {
            d.downloadStatus = BszM3u8DownloadStatusPaused;
            [d syncStatusToManager];
            continue;
        }
        [d pause];
    }
}

- (void)pauseTaskForTaskId:(NSString *)taskId {
    if (taskId.length == 0) {
        return;
    }

    __block BszM3u8Downloader *downloader = nil;
    __block BOOL updatedRecord = NO;

    [self withSyncQueue:^{
        // 1) 从等待队列移除，避免后续被自动拉起
        [self.pendingStartQueue removeObject:taskId];

        // 2) 若内存中存在 downloader，优先走 downloader.pause
        downloader = self.downloaderMap[taskId];

        // 3) 若仅存在持久化记录，也应能“暂停”（本质：把状态落为 Paused）
        if (!downloader) {
            NSDictionary *record = self.storedTaskRecords[taskId];
            if (!record) {
                return;
            }
            NSNumber *statusNum = BszRecordIntegerNumber(record[@"status"]);
            BszM3u8DownloadStatus status = (BszM3u8DownloadStatus)statusNum.integerValue;
            if (status == BszM3u8DownloadStatusCompleted || status == BszM3u8DownloadStatusStopped) {
                return;
            }
            NSMutableDictionary *m = [record mutableCopy];
            m[@"status"] = @(BszM3u8DownloadStatusPaused);
            self.storedTaskRecords[taskId] = [m copy];
            updatedRecord = YES;
        }
    }];

    // 锁外执行 pause，避免 syncStatusToManager 引发嵌套锁
    if (downloader) {
        if (downloader.downloadStatus == BszM3u8DownloadStatusReady) {
            downloader.downloadStatus = BszM3u8DownloadStatusPaused;
            [downloader syncStatusToManager];
        } else {
            [downloader pause];
        }
    }

    if (updatedRecord) {
        [self saveStoredTasksSafely];
    }
}

- (BOOL)resumeTaskForTaskId:(NSString *)taskId error:(NSError **)error {
    if (taskId.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"BszM3u8DownloadManager"
                                         code:-100
                                     userInfo:@{ NSLocalizedDescriptionKey: @"taskId 不能为空" }];
        }
        return NO;
    }

    // 单任务继续：认为用户有明确意图，解除全局 allPaused
    [self withSyncQueue:^{
        self.allPaused = NO;
    }];

    __block BszM3u8Downloader *downloader = nil;
    __block NSString *urlToCreate = nil;
    __block NSDictionary *extToCreate = nil;
    __block BszM3u8DownloadStatus recordStatus = BszM3u8DownloadStatusNotReady;

    [self withSyncQueue:^{
        downloader = self.downloaderMap[taskId];
        if (downloader) {
            return;
        }

        NSDictionary *record = self.storedTaskRecords[taskId];
        if (!record) {
            return;
        }
        NSNumber *statusNum = BszRecordIntegerNumber(record[@"status"]);
        recordStatus = (BszM3u8DownloadStatus)statusNum.integerValue;
        urlToCreate = BszRecordString(record[@"url"]);
        extToCreate = BszRecordDictionary(record[@"ext"]);
    }];

    if (!downloader) {
        if (urlToCreate.length == 0) {
            if (error) {
                *error = [NSError errorWithDomain:@"BszM3u8DownloadManager"
                                             code:-101
                                         userInfo:@{ NSLocalizedDescriptionKey: @"任务不存在或 url 缺失" }];
            }
            return NO;
        }
        downloader = [self startTaskWithTaskId:taskId urlString:urlToCreate ext:extToCreate];
    }

    if (!downloader) {
        if (error) {
            *error = [NSError errorWithDomain:@"BszM3u8DownloadManager"
                                         code:-102
                                     userInfo:@{ NSLocalizedDescriptionKey: @"创建 downloader 失败" }];
        }
        return NO;
    }

    // 已完成任务无需恢复
    if (downloader.downloadStatus == BszM3u8DownloadStatusCompleted || recordStatus == BszM3u8DownloadStatusCompleted) {
        if (error) {
            *error = [NSError errorWithDomain:@"BszM3u8DownloadManager"
                                         code:-103
                                     userInfo:@{ NSLocalizedDescriptionKey: @"任务已完成" }];
        }
        return NO;
    }

    // 并发控制：有槽位就立即启动，否则排队并标 Ready
    __block NSInteger availableSlots = 0;
    [self withSyncQueue:^{
        NSInteger max = self.maxConcurrentTasks;
        if (max <= 0) {
            availableSlots = NSIntegerMax;
        } else {
            NSInteger active = [self currentActiveDownloadingCountLocked];
            availableSlots = MAX(0, max - active);
        }
    }];

    if (availableSlots > 0) {
        if (downloader.downloadStatus == BszM3u8DownloadStatusPaused) {
            [downloader resume];
        } else {
            [downloader start];
        }
    } else {
        [self enqueueDownloaderToFrontIfNeeded:downloader];
        [self syncStatusForQueuePending:downloader];
        [self startQueuedDownloadersIfPossible];
    }
    return YES;
}

- (void)resumeAll {
    // 仅靠 UI 列表（只读持久化）时，可能还没创建任何 downloader。
    // “全部继续”应当能从持久化记录中拉起需要的 downloader。
    __block NSArray<NSDictionary *> *recordsToEnsure = nil;
    [self withSyncQueue:^{
        NSMutableArray<NSDictionary *> *tmp = [NSMutableArray array];
        [self.storedTaskRecords enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull identifier, NSDictionary * _Nonnull record, BOOL * _Nonnull stop) {
            if (identifier.length == 0) {
                return;
            }
            if (self.downloaderMap[identifier]) {
                return;
            }

            NSNumber *statusNum = BszRecordIntegerNumber(record[@"status"]);
            BszM3u8DownloadStatus st = (BszM3u8DownloadStatus)statusNum.integerValue;
            if (st == BszM3u8DownloadStatusCompleted) {
                return;
            }

            NSString *url = BszRecordString(record[@"url"]);
            if (url.length == 0) {
                return;
            }
            NSDictionary *ext = BszRecordDictionary(record[@"ext"]);
            [tmp addObject:@{ @"taskId": identifier, @"url": url, @"ext": ext ?: @{} }];
        }];
        recordsToEnsure = tmp.copy;
    }];

    for (NSDictionary *rec in recordsToEnsure) {
        NSString *identifier = rec[@"taskId"];
        NSString *url = rec[@"url"];
        NSDictionary *ext = rec[@"ext"];
        [self startTaskWithTaskId:identifier urlString:url ext:ext];
    }

    [self withSyncQueue:^{
        self.allPaused = NO;
    }];

    NSArray<BszM3u8Downloader *> *all = [self allDownloaderInstances];

    // 计算当前活跃数与可用槽位
    __block NSInteger availableSlots = 0;
    [self withSyncQueue:^{
        NSInteger max = self.maxConcurrentTasks;
        if (max <= 0) {
            availableSlots = NSIntegerMax;
        } else {
            NSInteger active = [self currentActiveDownloadingCountLocked];
            availableSlots = MAX(0, max - active);
        }
        // 清空等待队列，稍后按优先级重新入队
        [self.pendingStartQueue removeAllObjects];
    }];

    // 收集需要启动/恢复的候选（排除已完成、已在下载/启动中的）
    NSMutableArray<BszM3u8Downloader *> *candidates = [NSMutableArray array];
    for (BszM3u8Downloader *d in all) {
        if (d.downloadStatus == BszM3u8DownloadStatusCompleted ||
            d.downloadStatus == BszM3u8DownloadStatusDownloading ||
            d.downloadStatus == BszM3u8DownloadStatusStarting) {
            continue;
        }
        [candidates addObject:d];
    }

    // 按创建时间排序（最早优先）；当 maxConcurrentTasks>1 时直接挑选最早的若干个启动
    [candidates sortUsingComparator:^NSComparisonResult(BszM3u8Downloader *obj1, BszM3u8Downloader *obj2) {
        NSNumber *t1 = [self createdAtForIdentifier:(obj1.identifier ?: obj1.urlString) allowCreate:YES] ?: @(0);
        NSNumber *t2 = [self createdAtForIdentifier:(obj2.identifier ?: obj2.urlString) allowCreate:YES] ?: @(0);
        return [t1 compare:t2];
    }];

    for (BszM3u8Downloader *d in candidates) {
        if (availableSlots > 0) {
            availableSlots -= 1;
            if (d.downloadStatus == BszM3u8DownloadStatusPaused) {
                [d resume];
            } else {
                [d start];
            }
        } else {
            [self enqueueDownloaderToFrontIfNeeded:d];
            [self syncStatusForQueuePending:d];
        }
    }

    // 启动等待队列（内部会遵循并发上限）
    [self startQueuedDownloadersIfPossible];
}

- (BOOL)createAndStartTaskWithTaskId:(NSString *)taskId
                           urlString:(NSString *)urlString
                                 ext:(NSDictionary<NSString *,NSString *> *)ext
                               error:(NSError **)error {
    if (urlString.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"BszM3u8DownloadManager"
                                         code:-110
                                     userInfo:@{ NSLocalizedDescriptionKey: @"urlString 不能为空" }];
        }
        return NO;
    }

    NSString *resolvedId = taskId.length ? taskId : urlString;
    BszM3u8Downloader *d = [self startTaskWithTaskId:taskId urlString:urlString ext:ext];
    if (!d) {
        if (error) {
            *error = [NSError errorWithDomain:@"BszM3u8DownloadManager"
                                         code:-111
                                     userInfo:@{ NSLocalizedDescriptionKey: @"创建任务失败" }];
        }
        return NO;
    }
    return [self resumeTaskForTaskId:resolvedId error:error];
}


// 将 identifier 插入等待队列前端，保证优先启动
- (void)enqueueDownloaderToFrontIfNeeded:(BszM3u8Downloader *)downloader {
    if (!downloader.identifier.length) {
        return;
    }
    [self withSyncQueue:^{
        NSString *identifier = downloader.identifier;
        [self.pendingStartQueue removeObject:identifier];
        [self.pendingStartQueue insertObject:identifier atIndex:0];
    }];
}

// 将等待中的任务同步记录为 Ready，便于上层 UI 展示为“就绪”
- (void)syncStatusForQueuePending:(BszM3u8Downloader *)downloader {
    if (!downloader.identifier.length) {
        return;
    }
    // 标记为 Ready 但不触发 start，保持等待状态
    downloader.downloadStatus = BszM3u8DownloadStatusReady;
    [downloader syncStatusToManager];
}

- (BszM3u8DownloadTaskInfo *)taskInfoForTaskId:(NSString *)taskId {
    if (taskId.length == 0) {
        return nil;
    }

    __block BszM3u8DownloadTaskInfo *result = nil;
    [self withSyncQueue:^{
        NSDictionary *rt = self.runtimeTaskRecords[taskId];
        BszM3u8Downloader *downloader = self.downloaderMap[taskId];
        if (downloader) {
            BszM3u8DownloadTaskInfo *info = [[BszM3u8DownloadTaskInfo alloc] init];
            info.taskId = taskId;
            info.urlString = downloader.urlString;
            info.outputDir = downloader.outputPath;
            info.ext = downloader.ext;
            info.progress = downloader.progress;
            info.status = downloader.downloadStatus;
            if ([rt isKindOfClass:[NSDictionary class]]) {
                NSNumber *speedNum = rt[@"speed"]; if ([speedNum isKindOfClass:[NSNumber class]]) { info.speedBytesPerSecond = speedNum.doubleValue; }
            }
            info.createdAt = [self createdAtForIdentifier:taskId allowCreate:YES];
            result = info;
            return;
        }

        NSDictionary *record = self.storedTaskRecords[taskId];
        if (record) {
            BszM3u8DownloadTaskInfo *info = [[BszM3u8DownloadTaskInfo alloc] init];
            info.taskId = taskId;
            info.urlString = BszRecordString(record[@"url"]);
            info.outputDir = [self absoluteOutputDirFromStoredValue:BszRecordString(record[@"outputDir"])];
            info.ext = BszRecordDictionary(record[@"ext"]);
            NSNumber *progressNum = BszRecordDoubleNumber(record[@"progress"]);
            NSNumber *statusNum = BszRecordIntegerNumber(record[@"status"]);
            info.progress = progressNum.floatValue;
            info.status = (BszM3u8DownloadStatus)statusNum.integerValue;
            info.createdAt = BszRecordDoubleNumber(record[@"createdAt"]);
            if ([rt isKindOfClass:[NSDictionary class]]) {
                NSNumber *speedNum = rt[@"speed"]; if ([speedNum isKindOfClass:[NSNumber class]]) { info.speedBytesPerSecond = speedNum.doubleValue; }
            }
            result = info;
        }
    }];

    return result;
}

- (NSDictionary<NSString *, NSString *> *)taskDicForTaskId:(NSString *)taskId {
    BszM3u8DownloadTaskInfo *info = [self taskInfoForTaskId:taskId];
    if (!info) {
        return nil;
    }
    return [self dictionaryFromTaskInfo:info];
}

- (void)deleteTaskForTaskId:(NSString *)taskId {
    if (taskId.length == 0) {
        return;
    }

    __block NSString *outputDir = nil;
    __block BszM3u8Downloader *downloaderToStop = nil;

    [self withSyncQueue:^{
        [self.runtimeTaskRecords removeObjectForKey:taskId];
        // 1. 停掉 taskId 对应的 downloader，并从 map 中移除
        BszM3u8Downloader *downloader = self.downloaderMap[taskId];
        if (downloader) {
            downloaderToStop = downloader;
            if (downloader.outputPath.length) {
                outputDir = downloader.outputPath;
            }
            [self.downloaderMap removeObjectForKey:taskId];
        }

        // 2. 删除 taskId 对应的持久化记录
        NSDictionary *record = self.storedTaskRecords[taskId];
        if (record) {
            if (!outputDir.length) {
                NSString *dir = BszRecordString(record[@"outputDir"]);
                outputDir = [self absoluteOutputDirFromStoredValue:dir] ?: dir;
            }
            [self.storedTaskRecords removeObjectForKey:taskId];
        }

        // 3. 如果依然缺少目录信息，回退到默认目录（防止未持久化 outputDir 时残留文件）
        if (!outputDir.length) {
            outputDir = [self defaultOutputDirForKey:taskId];
        }
    }];

    // 在退出锁后再调用 stop，避免 syncStatusToManager 嵌套锁死
    if (downloaderToStop) {
        [downloaderToStop stop];
    }

    // 3. 删除对应的本地目录
    if (outputDir.length) {
        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:outputDir isDirectory:&isDir] && isDir) {
            NSError *removeError = nil;
            if (![fm removeItemAtPath:outputDir error:&removeError]) {
#if DEBUG
                NSLog(@"[BszM3u8DownloadManager] deleteTask remove dir failed: %@ | error=%@", outputDir, removeError.localizedDescription ?: @"unknown");
#endif
            }
        } else {
#if DEBUG
            NSLog(@"[BszM3u8DownloadManager] deleteTask dir not found, nothing to delete: %@", outputDir);
#endif
        }
    }

    [self saveStoredTasksImmediately];
}

- (void)stopAll {
    // 停止并删除所有“未完成”的任务及其下载文件（保留已完成任务）
    __block NSMutableArray<NSString *> *dirsToDelete = [NSMutableArray array];
    __block NSMutableArray<BszM3u8Downloader *> *downloadersToStop = [NSMutableArray array];

    [self withSyncQueue:^{
        self.deletingAll = YES;

        // 1. 处理内存中的 downloader
        NSMutableArray<NSString *> *unfinishedKeys = [NSMutableArray array];
        [self.downloaderMap enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, BszM3u8Downloader * _Nonnull d, BOOL * _Nonnull stop) {
            if (d.downloadStatus != BszM3u8DownloadStatusCompleted) {
                [downloadersToStop addObject:d];
                if (d.outputPath.length) {
                    [dirsToDelete addObject:d.outputPath];
                }
                [unfinishedKeys addObject:key];
            }
        }];
        [self.downloaderMap removeObjectsForKeys:unfinishedKeys];

        // 2. 处理持久化记录：仅移除“未完成”的任务
        NSMutableArray<NSString *> *keysToRemove = [NSMutableArray array];
        [self.storedTaskRecords enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, NSDictionary * _Nonnull record, BOOL * _Nonnull stop) {
            NSNumber *statusNum = BszRecordIntegerNumber(record[@"status"]);
            BszM3u8DownloadStatus status = (BszM3u8DownloadStatus)statusNum.integerValue;
            if (status != BszM3u8DownloadStatusCompleted) {
                NSString *outputDir = [self absoluteOutputDirFromStoredValue:BszRecordString(record[@"outputDir"])];
                if (outputDir.length) {
                    [dirsToDelete addObject:outputDir];
                }
                [keysToRemove addObject:key];
            }
        }];
        [self.storedTaskRecords removeObjectsForKeys:keysToRemove];

        // 清空等待队列，避免后续自动启动
        [self.pendingStartQueue removeAllObjects];
    }];

    // 在锁外执行 stop，避免死锁
    for (BszM3u8Downloader *d in downloadersToStop) {
        if ([d respondsToSelector:@selector(cancelSilentlyForDeletion)]) {
            [d cancelSilentlyForDeletion];
        } else {
            [d stop];
        }
    }

    // 3. 删除未完成任务对应的本地目录
    NSFileManager *fm = [NSFileManager defaultManager];
    NSSet<NSString *> *uniqueDirs = [NSSet setWithArray:dirsToDelete];
    for (NSString *outputDir in uniqueDirs) {
        if (outputDir.length) {
            [fm removeItemAtPath:outputDir error:nil];
        }
    }

    [self saveStoredTasksImmediately];

    BszDispatchAsyncSafe(self.syncQueue, ^{
        self.deletingAll = NO;
    });
}

- (void)deleteAll {
    // 删除所有“已完成”的任务及其下载文件（保留未完成任务）
    __block NSMutableArray<NSString *> *dirsToDelete = [NSMutableArray array];
    __block NSMutableArray<BszM3u8Downloader *> *downloadersToCleanup = [NSMutableArray array];

    [self withSyncQueue:^{
        // 防止并发启动新的任务
        self.deletingAll = YES;

        // 1) 处理内存中的 downloader：只移除 Completed
        NSMutableArray<NSString *> *completedKeys = [NSMutableArray array];
        [self.downloaderMap enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, BszM3u8Downloader * _Nonnull d, BOOL * _Nonnull stop) {
            if (d.downloadStatus == BszM3u8DownloadStatusCompleted) {
                [downloadersToCleanup addObject:d];
                if (d.outputPath.length) {
                    [dirsToDelete addObject:d.outputPath];
                }
                [completedKeys addObject:key];
            }
        }];
        [self.downloaderMap removeObjectsForKeys:completedKeys];

        // 2) 处理持久化记录：仅移除 Completed
        NSMutableArray<NSString *> *keysToRemove = [NSMutableArray array];
        [self.storedTaskRecords enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, NSDictionary * _Nonnull record, BOOL * _Nonnull stop) {
            NSNumber *statusNum = BszRecordIntegerNumber(record[@"status"]);
            BszM3u8DownloadStatus status = (BszM3u8DownloadStatus)statusNum.integerValue;
            if (status == BszM3u8DownloadStatusCompleted) {
                NSString *outputDir = [self absoluteOutputDirFromStoredValue:BszRecordString(record[@"outputDir"])];
                if (outputDir.length) {
                    [dirsToDelete addObject:outputDir];
                }
                [keysToRemove addObject:key];
            }
        }];
        [self.storedTaskRecords removeObjectsForKeys:keysToRemove];

        // 等待队列中如果有 Completed 的残留，顺手清理（保留其他未完成任务的排队顺序）
        NSMutableArray<NSString *> *queueToRemove = [NSMutableArray array];
        for (NSString *identifier in self.pendingStartQueue) {
            NSDictionary *record = self.storedTaskRecords[identifier];
            NSNumber *statusNum = BszRecordIntegerNumber(record[@"status"]);
            if (record && statusNum.integerValue == BszM3u8DownloadStatusCompleted) {
                [queueToRemove addObject:identifier];
            }
        }
        [self.pendingStartQueue removeObjectsInArray:queueToRemove];
    }];

    // Completed 的 downloader 理论上不在下载，但为保险起见，静默取消其会话
    for (BszM3u8Downloader *d in downloadersToCleanup) {
        if ([d respondsToSelector:@selector(cancelSilentlyForDeletion)]) {
            [d cancelSilentlyForDeletion];
        }
    }

    // 删除对应的本地目录
    NSFileManager *fm = [NSFileManager defaultManager];
    NSSet<NSString *> *uniqueDirs = [NSSet setWithArray:dirsToDelete];
    for (NSString *outputDir in uniqueDirs) {
        if (outputDir.length) {
            [fm removeItemAtPath:outputDir error:nil];
        }
    }

    [self saveStoredTasksImmediately];

    // 释放全局开关，允许后续新增任务
    BszDispatchAsyncSafe(self.syncQueue, ^{
        self.deletingAll = NO;
    });
}

#pragma mark - Persistence
- (void)loadStoredTasksIfNeeded {
    NSDictionary<NSString *, NSDictionary *> *records = [self.taskStore loadRecords];
    self.storedTaskRecords = [records mutableCopy] ?: [NSMutableDictionary dictionary];

    // 冷启动/被杀进程后，任何处于 Starting/Downloading 的任务都不可能仍在下载。
    // 统一降级为 Paused，避免 UI 显示“开始中/下载中”造成误导。
    __block BOOL changed = NO;
    NSMutableDictionary<NSString *, NSDictionary *> *pendingStatusDowngrade = [NSMutableDictionary dictionary];
    [self.storedTaskRecords enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, NSDictionary * _Nonnull obj, BOOL * _Nonnull stop) {
        NSNumber *statusNum = BszRecordIntegerNumber(obj[@"status"]);
        if (!statusNum) {
            return;
        }
        BszM3u8DownloadStatus status = (BszM3u8DownloadStatus)statusNum.integerValue;
        if (status == BszM3u8DownloadStatusStarting || status == BszM3u8DownloadStatusDownloading) {
            NSMutableDictionary *m = [obj mutableCopy];
            m[@"status"] = @(BszM3u8DownloadStatusPaused);
            pendingStatusDowngrade[key] = m.copy;
            changed = YES;
        }
    }];
    if (pendingStatusDowngrade.count > 0) {
        [pendingStatusDowngrade enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, NSDictionary * _Nonnull obj, BOOL * _Nonnull stop) {
            self.storedTaskRecords[key] = obj;
        }];
    }
    if (changed) {
        [self saveStoredTasksImmediately];
    }
}

- (void)saveStoredTasksSafely {
    __block NSArray<NSDictionary *> *snapshot = nil;
    [self withSyncQueue:^{
        snapshot = self.storedTaskRecords.allValues ?: @[];
    }];
    [self.taskStore scheduleSaveWithRecordsSnapshot:snapshot ?: @[]];
}

// 立即写入：用于 delete/stopAll 等关键操作，避免退出 App 时丢记录
- (void)saveStoredTasksImmediately {
    __block NSArray *snapshot = nil;
    [self withSyncQueue:^{
        snapshot = self.storedTaskRecords.allValues ?: @[];
    }];
    [self.taskStore saveImmediatelyWithRecordsSnapshot:snapshot ?: @[]];
}

- (void)updateStoredRecordForTaskId:(NSString *)taskId
                              urlString:(NSString *)urlString
                              outputDir:(NSString *)outputDir
                                   ext:(NSDictionary<NSString *, NSString *> *)ext
                                status:(BszM3u8DownloadStatus)status
                              progress:(float)progress
                             createdAt:(NSNumber *)createdAt {
    if (self.deletingAll) {
        return;
    }
    if (taskId.length == 0 || urlString.length == 0 || outputDir.length == 0) {
        return;
    }

    [self withSyncQueue:^{
        NSMutableDictionary *record = [self.storedTaskRecords[taskId] mutableCopy] ?: [NSMutableDictionary dictionary];
        record[@"taskId"] = taskId;
        record[@"url"] = urlString;
        NSString *storedDir = [self storedOutputDirValueFromAbsolutePath:outputDir] ?: outputDir;
        record[@"outputDir"] = storedDir;
        if (ext) {
            record[@"ext"] = ext;
        } else if (!record[@"ext"]) {
            record[@"ext"] = @{};
        }
        record[@"status"] = @(status);
        record[@"progress"] = @(progress);
        if (createdAt) {
            record[@"createdAt"] = createdAt;
        } else if (!record[@"createdAt"]) {
            // 若未传入，保持已有的创建时间或补充当前时间
            record[@"createdAt"] = @([[NSDate date] timeIntervalSince1970]);
        }
        self.storedTaskRecords[taskId] = [record copy];
    }];

    // 每次状态或进度更新后，触发一次异步持久化，
    // 避免在“全部暂停”后立刻杀掉 App 时丢失任务记录。
    [self saveStoredTasksSafely];
}

- (void)removeStoredRecordForURL:(NSString *)urlString {
    if (urlString.length == 0) {
        return;
    }

    [self withSyncQueue:^{
        NSMutableArray<NSString *> *keysToRemove = [NSMutableArray array];
        [self.storedTaskRecords enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, NSDictionary * _Nonnull obj, BOOL * _Nonnull stop) {
            NSString *url = obj[@"url"];
            if ([url isEqualToString:urlString]) {
                [keysToRemove addObject:key];
            }
        }];
        [self.storedTaskRecords removeObjectsForKeys:keysToRemove];
    }];

    [self saveStoredTasksImmediately];
}

@end
