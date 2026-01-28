#import "BszM3u8DownloaderCore.h"
#import "BszM3u8DownloadManager.h"
#import "BszM3u8KeyFetcher.h"
#import "BszM3u8Tool.h"

// 内部持久化接口，仅在库内部调用，不对外暴露
@interface BszM3u8DownloadManager (PersistenceInternal)
- (void)updateStoredRecordForTaskId:(NSString *)taskId
                                                urlString:(NSString *)urlString
                                                outputDir:(NSString *)outputDir
                                                     ext:(nullable NSDictionary<NSString *, NSString *> *)ext
                                                 status:(BszM3u8DownloadStatus)status
                                                 progress:(float)progress
                                                createdAt:(nullable NSNumber *)createdAt;
// 任务级并发控制接口（内部使用）
- (BOOL)requestStartForDownloader:(BszM3u8Downloader *)downloader;
- (void)downloader:(BszM3u8Downloader *)downloader didChangeStatus:(BszM3u8DownloadStatus)status;
// 标识管理器是否处于“全局删除”流程中
- (BOOL)isDeletingAll;
@end

#if __has_include(<UIKit/UIKit.h>)
#import <UIKit/UIKit.h>
#endif

static NSString * const BszM3u8DownloaderErrorDomain = @"BszM3u8DownloaderErrorDomain";

// 用 queue-specific 避免在同一串行队列上嵌套 dispatch_sync 导致死锁
static void *BszDownloaderSyncQueueKey = &BszDownloaderSyncQueueKey;

static inline void BszDownloaderDispatchSyncSafe(dispatch_queue_t queue, dispatch_block_t block) {
    if (!queue || !block) {
        return;
    }
    if (dispatch_get_specific(BszDownloaderSyncQueueKey)) {
        block();
    } else {
        dispatch_sync(queue, block);
    }
}

static inline BOOL BszFileExistsAndNonEmpty(NSFileManager *fm, NSString *path) {
    if (!fm || path.length == 0) {
        return NO;
    }
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir] || isDir) {
        return NO;
    }
    NSError *attrError = nil;
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:&attrError];
    if (attrError || !attrs) {
        return NO;
    }
    unsigned long long fileSize = [attrs fileSize];
    return fileSize > 0;
}

typedef NS_ENUM(NSInteger, BszM3u8DownloaderErrorCode) {
    BszM3u8DownloaderErrorCodeInvalidPlaylist = 1001,
};

@interface BszM3u8Downloader ()

@property (nonatomic, copy, readwrite) NSString *urlString;
@property (nonatomic, copy, readwrite) NSString *identifier;
@property (nonatomic, copy, readwrite) NSString *outputPath;
@property (nonatomic, copy, readwrite, nullable) NSDictionary<NSString *, NSString *> *ext;

@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableDictionary<NSURL *, NSURLSessionDownloadTask *> *segmentTasks;
@property (nonatomic, strong) NSMutableDictionary<NSURL *, NSNumber *> *segmentRetryCounts; // TS 下载重试次数
@property (nonatomic, assign, readwrite) double currentSpeedBytesPerSecond; // 近期瞬时速度（字节/秒）
@property (nonatomic, copy, readwrite) NSString *currentSpeedString; // 可读速度字符串
@property (nonatomic, assign) int64_t bytesSinceLastSpeedSample;
@property (nonatomic, assign) CFAbsoluteTime lastSpeedSampleTime;

// 全局删除/静默取消时不再回写状态或进度
@property (nonatomic, assign) BOOL suppressStatusUpdates;
// 标记任务已被删除/中止，阻止后续回调推进状态或生成文件
@property (nonatomic, assign) BOOL aborted;

@property (nonatomic, assign) NSInteger finishedSegmentCount;
@property (nonatomic, assign) NSInteger totalSegmentCount;
@property (nonatomic, assign, readwrite) BszM3u8DownloadStatus downloadStatus;

@property (nonatomic, assign, readwrite) BOOL completedFromCache;

// 用于屏蔽 pause/resume 或多次 start 导致的旧回调串台
@property (nonatomic, assign) NSUInteger downloadGeneration;

// 内部标记：本次下载过程中是否有分片失败（不含被取消的请求）
@property (nonatomic, assign) BOOL hasFailedSegments;

@property (nonatomic, strong) dispatch_queue_t syncQueue;

// 分片调度：避免一次性创建大量 downloadTask 导致 "Too many open files" (error 24)
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *pendingSegmentItems;
@property (nonatomic, assign) NSInteger activeSegmentCount;
@property (nonatomic, assign) NSInteger segmentConcurrencyLimit;

- (void)syncStatusToManager;

- (BOOL)shouldIgnoreCallbackForGeneration:(NSUInteger)generation;

- (void)handlePlaylistString:(NSString *)playlist fromURL:(NSURL *)url generation:(NSUInteger)generation;
- (void)startDownloadTaskForSegmentURL:(NSURL *)segmentURL
                              fileName:(NSString *)fileName
                             targetURL:(NSURL *)targetURL
                                 group:(dispatch_group_t)group
                            generation:(NSUInteger)generation;
- (void)startNextSegmentsIfNeededWithGroup:(dispatch_group_t)group generation:(NSUInteger)generation;

@end

@implementation BszM3u8Downloader

- (BOOL)shouldIgnoreCallbackForGeneration:(NSUInteger)generation {
    // 屏蔽上一轮 start/resume 产生的回调
    if (generation != self.downloadGeneration) {
        return YES;
    }
    if (self.aborted) {
        return YES;
    }
    return (self.downloadStatus == BszM3u8DownloadStatusPaused ||
            self.downloadStatus == BszM3u8DownloadStatusStopped);
}

- (void)syncStatusToManager {
    NSString *identifier = self.identifier ?: self.urlString;
    BszM3u8DownloadManager *manager = [BszM3u8DownloadManager sharedManager];
    if (self.suppressStatusUpdates) {
        return;
    }
    if ([manager isDeletingAll]) {
        return;
    }
    [manager updateStoredRecordForTaskId:identifier
                                                            urlString:self.urlString
                                                            outputDir:self.outputPath
                                                                    ext:self.ext
                                                             status:self.downloadStatus
                                     progress:self.progress
                                    createdAt:nil];
    [manager downloader:self didChangeStatus:self.downloadStatus];
}

- (instancetype)initWithURLString:(NSString *)urlString
                       outputPath:(NSString *)outputPath
                       	ext:(NSDictionary<NSString *, NSString *> *)ext
                        identifier:(NSString *)identifier {
    self = [super init];
    if (self) {
            _urlString = [urlString copy];
            _outputPath = [outputPath copy];
            _ext = [ext copy];
            _identifier = identifier.length ? [identifier copy] : [_urlString copy];
        _maxConcurrentOperationCount = 5;
        _autoPauseWhenAppDidEnterBackground = YES;
        _downloadStatus = BszM3u8DownloadStatusNotReady;
        _segmentTasks = [NSMutableDictionary dictionary];
        _segmentRetryCounts = [NSMutableDictionary dictionary];
        _syncQueue = dispatch_queue_create("com.bszm3u8.downloader.sync", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_syncQueue, BszDownloaderSyncQueueKey, BszDownloaderSyncQueueKey, NULL);
        _aborted = NO;
        _suppressStatusUpdates = NO;
        _downloadGeneration = 0;
        _pendingSegmentItems = [NSMutableArray array];
        _activeSegmentCount = 0;
        _segmentConcurrencyLimit = 5;
        _currentSpeedBytesPerSecond = 0;
        _currentSpeedString = @"";
        _bytesSinceLastSpeedSample = 0;
        _lastSpeedSampleTime = 0;

#if __has_include(<UIKit/UIKit.h>)
        [self setupAppLifecycleNotifications];
#endif
    }
    return self;
}

- (instancetype)initWithURLString:(NSString *)urlString
                       outputPath:(NSString *)outputPath {
    return [self initWithURLString:urlString outputPath:outputPath ext:nil identifier:nil];
}

#if __has_include(<UIKit/UIKit.h>)
- (void)setupAppLifecycleNotifications {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(handleDidEnterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [center addObserver:self selector:@selector(handleDidBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)handleDidEnterBackground {
    if (self.downloadDidEnterBackgroundExeBlock) {
        self.downloadDidEnterBackgroundExeBlock();
    }
    if (self.autoPauseWhenAppDidEnterBackground && self.downloadStatus == BszM3u8DownloadStatusDownloading) {
        [self pause];
    }
}

- (void)handleDidBecomeActive {
    if (self.downloadDidBecomeActiveExeBlock) {
        self.downloadDidBecomeActiveExeBlock();
    }
}
#endif

#pragma mark - Public control

// 重置速度统计，清零并立即通知 0 速度
- (void)resetSpeedTracking {
    BszDownloaderDispatchSyncSafe(self.syncQueue, ^{
        self.bytesSinceLastSpeedSample = 0;
        self.lastSpeedSampleTime = CFAbsoluteTimeGetCurrent();
        self.currentSpeedBytesPerSecond = 0;
        self.currentSpeedString = @"";
    });
    if (self.downloadSpeedUpdateExeBlock) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.downloadSpeedUpdateExeBlock(0);
        });
    }
}

// 记录已下载字节并按时间窗口计算瞬时速度（字节/秒）
- (void)recordDownloadedBytes:(NSUInteger)bytes {
    if (bytes == 0) {
        return;
    }

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    __block BOOL shouldCallback = NO;
    __block double callbackSpeed = 0;
    BszDownloaderDispatchSyncSafe(self.syncQueue, ^{
        if (self.lastSpeedSampleTime <= 0) {
            self.lastSpeedSampleTime = now;
        }
        self.bytesSinceLastSpeedSample += bytes;
        CFAbsoluteTime delta = now - self.lastSpeedSampleTime;
        if (delta < 0.25) {
            return; // 窗口未到 250ms，不频繁刷新
        }

        double speed = (double)self.bytesSinceLastSpeedSample / MAX(delta, 0.001);
        self.currentSpeedBytesPerSecond = speed;
        self.currentSpeedString = [self.class formatSpeed:speed];
        self.bytesSinceLastSpeedSample = 0;
        self.lastSpeedSampleTime = now;

        if (self.downloadSpeedUpdateExeBlock) {
            shouldCallback = YES;
            callbackSpeed = speed;
        }
    });

    if (shouldCallback) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.downloadSpeedUpdateExeBlock(callbackSpeed);
        });
    }
}

// 将字节/秒格式化为可读字符串
+ (NSString *)formatSpeed:(double)bytesPerSec {
    if (bytesPerSec <= 0) {
        return @"";
    }
    double bps = bytesPerSec;
    if (bps < 1024.0) {
        return [NSString stringWithFormat:@"%.0f B/s", bps];
    }
    double kbps = bps / 1024.0;
    if (kbps < 1024.0) {
        return [NSString stringWithFormat:@"%.1f KB/s", kbps];
    }
    double mbps = kbps / 1024.0;
    if (mbps < 1024.0) {
        return [NSString stringWithFormat:@"%.2f MB/s", mbps];
    }
    double gbps = mbps / 1024.0;
    return [NSString stringWithFormat:@"%.2f GB/s", gbps];
}

- (void)start {
    if (self.downloadStatus == BszM3u8DownloadStatusStarting ||
        self.downloadStatus == BszM3u8DownloadStatusDownloading) {
        return;
    }

    if (self.urlString.length == 0 || self.outputPath.length == 0) {
        return;
    }

    // 任务级并发控制：若当前已有其他任务在下载，则排队到 Ready
    if (![[BszM3u8DownloadManager sharedManager] requestStartForDownloader:self]) {
        self.downloadStatus = BszM3u8DownloadStatusReady;
        [self syncStatusToManager];
        return;
    }

    // 新的下载周期：递增代数，用于屏蔽上一轮异步回调
    self.downloadGeneration += 1;
    NSUInteger generation = self.downloadGeneration;

    self.aborted = NO;
    self.suppressStatusUpdates = NO;

    [self resetSpeedTracking];

    // 每次开始前重置内部状态
    self.completedFromCache = NO;
    self.hasFailedSegments = NO;
    BszDownloaderDispatchSyncSafe(self.syncQueue, ^{
        [self.segmentTasks removeAllObjects];
        [self.segmentRetryCounts removeAllObjects];
    });

    // 如果本地已存在 index.m3u8，且其引用的 key/ts 均在本地真实存在，则认为该任务已完成，直接回调完成。
    // 注意：仅凭 index.m3u8 存在可能是“中断/半成品”，会导致 UI 误判已完成但无法离线播放。
    NSFileManager *fmCheck = [NSFileManager defaultManager];
    NSString *indexPath = [self.outputPath stringByAppendingPathComponent:@"index.m3u8"];
    BOOL isDir = NO;
    if ([fmCheck fileExistsAtPath:indexPath isDirectory:&isDir] && !isDir &&
        [BszM3u8Tool isLocalizedIndexPlaylistCompleteAtPath:indexPath outputDirectory:self.outputPath]) {
        self.completedFromCache = YES;
        self.downloadStatus = BszM3u8DownloadStatusCompleted;
        [self syncStatusToManager];
        if (self.downloadCompleteExeBlock) {
            self.downloadCompleteExeBlock();
        }
        return;
    }

    // 以当前设置的并发数创建 session（同时用于分片调度并发上限）
    NSInteger maxCount = self.maxConcurrentOperationCount > 0 ? self.maxConcurrentOperationCount : 5;
    self.segmentConcurrencyLimit = MAX(1, maxCount);
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.HTTPMaximumConnectionsPerHost = maxCount;
    self.session = [NSURLSession sessionWithConfiguration:config];

    self.downloadStatus = BszM3u8DownloadStatusStarting;
    [self syncStatusToManager];
    if (self.downloadStartExeBlock) {
        self.downloadStartExeBlock();
    }

    NSURL *url = [NSURL URLWithString:self.urlString];
    if (!url) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [self.session dataTaskWithURL:url
                                             completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) { return; }

        // 丢弃旧代数/暂停/停止/已中止的回调
        if ([strongSelf shouldIgnoreCallbackForGeneration:generation]) {
            return;
        }

        if (error || !data) {
            if (strongSelf.aborted) { return; }
            strongSelf.downloadStatus = BszM3u8DownloadStatusStopped;
            if (strongSelf.downloadStopExeBlock) {
                strongSelf.downloadStopExeBlock();
            }
            return;
        }

        NSString *playlistString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (playlistString.length == 0) {
            if (strongSelf.aborted) { return; }
            strongSelf.downloadStatus = BszM3u8DownloadStatusStopped;
            if (strongSelf.downloadStopExeBlock) {
                strongSelf.downloadStopExeBlock();
            }
            return;
        }

        if (!strongSelf.aborted) {
            [strongSelf handlePlaylistString:playlistString fromURL:url generation:generation];
        }
    }];

    [task resume];
}

- (void)pause {
    // 允许在 Starting 或 Downloading 状态下暂停
    if (self.downloadStatus != BszM3u8DownloadStatusDownloading &&
        self.downloadStatus != BszM3u8DownloadStatusStarting) {
        return;
    }

    self.downloadStatus = BszM3u8DownloadStatusPaused;
    [self resetSpeedTracking];
    [self syncStatusToManager];
    if (self.downloadPausedExeBlock) {
        self.downloadPausedExeBlock();
    }

    // 暂停或取消分片任务，防止继续推进状态
    BszDownloaderDispatchSyncSafe(self.syncQueue, ^{
        [self.segmentTasks enumerateKeysAndObjectsUsingBlock:^(NSURL * _Nonnull key, NSURLSessionDownloadTask * _Nonnull obj, BOOL * _Nonnull stop) {
            if (obj.state == NSURLSessionTaskStateRunning || obj.state == NSURLSessionTaskStateSuspended) {
                [obj suspend];
            }
        }];
    });

    // 失效会话，避免队列中新的回调推进状态
    [self.session invalidateAndCancel];
    self.session = nil;
}

- (void)resume {
    if (self.downloadStatus != BszM3u8DownloadStatusPaused) {
        return;
    }

    [self resetSpeedTracking];

    // 如果会话已失效（如 pause 时调用了 invalidateAndCancel），或尚未创建任何分片任务，
    // 直接走 start 流程重新拉取 playlist/分片，避免 resume 对失效的 session/任务无效。
    if (!self.session || self.segmentTasks.count == 0) {
        self.downloadStatus = BszM3u8DownloadStatusNotReady;
        [self start];
        return;
    }

    self.downloadStatus = BszM3u8DownloadStatusDownloading;
    [self syncStatusToManager];
    if (self.downloadResumeExeBlock) {
        self.downloadResumeExeBlock();
    }

    BszDownloaderDispatchSyncSafe(self.syncQueue, ^{
        [self.segmentTasks enumerateKeysAndObjectsUsingBlock:^(NSURL * _Nonnull key, NSURLSessionDownloadTask * _Nonnull obj, BOOL * _Nonnull stop) {
            if (obj.state == NSURLSessionTaskStateSuspended) {
                [obj resume];
            }
        }];
    });
}

- (void)stop {
    if (self.downloadStatus == BszM3u8DownloadStatusStopped ||
        self.downloadStatus == BszM3u8DownloadStatusCompleted) {
        return;
    }

    self.downloadStatus = BszM3u8DownloadStatusStopped;
    [self resetSpeedTracking];
    [self syncStatusToManager];
    if (self.downloadStopExeBlock) {
        self.downloadStopExeBlock();
    }

    BszDownloaderDispatchSyncSafe(self.syncQueue, ^{
        [self.segmentTasks enumerateKeysAndObjectsUsingBlock:^(NSURL * _Nonnull key, NSURLSessionDownloadTask * _Nonnull obj, BOOL * _Nonnull stop) {
            [obj cancel];
        }];
        [self.segmentTasks removeAllObjects];
        [self.segmentRetryCounts removeAllObjects];
    });
}

// 用于“全部删除”场景：静默取消所有网络请求，不修改状态、不回写持久化
- (void)cancelSilentlyForDeletion {
    self.suppressStatusUpdates = YES;
    self.aborted = YES;

    // 取消分片任务
    BszDownloaderDispatchSyncSafe(self.syncQueue, ^{
        [self.segmentTasks enumerateKeysAndObjectsUsingBlock:^(NSURL * _Nonnull key, NSURLSessionDownloadTask * _Nonnull obj, BOOL * _Nonnull stop) {
            [obj cancel];
        }];
        [self.segmentTasks removeAllObjects];
        [self.segmentRetryCounts removeAllObjects];
    });

    // 失效会话，阻止后续回调
    [self.session invalidateAndCancel];
    self.session = nil;
}

#pragma mark - Internal playlist handling

- (void)handlePlaylistString:(NSString *)playlist fromURL:(NSURL *)url generation:(NSUInteger)generation {
    // 若用户在拉取 playlist 期间已暂停/停止/中止，或这是旧代数回调，直接忽略
    if ([self shouldIgnoreCallbackForGeneration:generation]) {
        return;
    }

    NSArray<NSString *> *lines = [playlist componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];

    NSURL *baseURL = url.URLByDeletingLastPathComponent;

    // 先处理加密 KEY：解析 EXT-X-KEY 中的 URI，将 key 文件下载到本地 outputPath，
    // 并返回一个映射表（原始 URI 字符串 -> 本地文件名），用于后续生成本地 m3u8 时改写为本地文件名，实现离线播放。
    BOOL keyError = NO;
    BszM3u8KeyFetcher *keyFetcher = [[BszM3u8KeyFetcher alloc] initWithOutputDirectory:self.outputPath];
    NSDictionary<NSString *, NSString *> *keyMap = [keyFetcher fetchKeysForPlaylistLines:lines
                                                                                baseURL:baseURL
                                                                          timeoutSeconds:30.0
                                                                               hadError:&keyError];
    if (keyError) {
#if DEBUG
        NSLog(@"[BszM3u8Downloader] key download failed; aborting task to avoid false Completed.");
#endif
        self.hasFailedSegments = YES;
        [self failAndAbortForError:nil];
        self.downloadStatus = BszM3u8DownloadStatusStopped;
        [self syncStatusToManager];
        if (self.downloadStopExeBlock) {
            self.downloadStopExeBlock();
        }
        return;
    }

    // 如果这是一个主清单（包含多码率的 EXT-X-STREAM-INF），需要先下钻到具体的媒体清单
    NSString *variantLine = [BszM3u8Tool firstVariantURIFromLines:lines];
    if (variantLine.length > 0) {
        NSURL *variantURL = [NSURL URLWithString:variantLine relativeToURL:baseURL];
        if (!variantURL) {
            // 回退为原逻辑
        } else {
            __weak typeof(self) weakSelf = self;
            NSURLSessionDataTask *subTask = [self.session dataTaskWithURL:variantURL
                                                         completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) { return; }

                if ([strongSelf shouldIgnoreCallbackForGeneration:generation]) { return; }

                if (error || !data) {
                    strongSelf.downloadStatus = BszM3u8DownloadStatusStopped;
                    if (strongSelf.downloadStopExeBlock) {
                        strongSelf.downloadStopExeBlock();
                    }
                    return;
                }

                NSString *subPlaylist = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                if (subPlaylist.length == 0) {
                    if (strongSelf.aborted) { return; }
                    strongSelf.downloadStatus = BszM3u8DownloadStatusStopped;
                    if (strongSelf.downloadStopExeBlock) {
                        strongSelf.downloadStopExeBlock();
                    }
                    return;
                }

                if (!strongSelf.aborted) {
                    // 子 playlist 回调也必须校验代数，避免 pause/resume 后旧回调串台
                    if (generation == strongSelf.downloadGeneration) {
                        [strongSelf handlePlaylistString:subPlaylist fromURL:variantURL generation:generation];
                    }
                }
            }];
            [subTask resume];
            return;
        }
    }

    NSArray<NSURL *> *segmentURLs = [BszM3u8Tool segmentURLsFromLines:lines baseURL:baseURL];

    if (segmentURLs.count == 0) {
        self.downloadStatus = BszM3u8DownloadStatusStopped;
        if (self.downloadStopExeBlock) {
            self.downloadStopExeBlock();
        }
        return;
    }

    self.totalSegmentCount = segmentURLs.count;
    // 预先扫描已存在的 TS，避免重复请求，提升暂停/重启后的恢复速度
    __block NSInteger existingCount = 0;
    NSFileManager *scanFM = [NSFileManager defaultManager];
    for (NSURL *segmentURL in segmentURLs) {
        NSString *fileName = [BszM3u8Tool localFileNameForURL:segmentURL];
        if (fileName.length == 0) { continue; }
        NSString *targetPath = [self.outputPath stringByAppendingPathComponent:fileName];
        if (BszFileExistsAndNonEmpty(scanFM, targetPath)) {
            existingCount += 1;
            continue;
        }
        // 空文件/坏文件不算已存在，删除后重下
        BOOL isDir = NO;
        if ([scanFM fileExistsAtPath:targetPath isDirectory:&isDir] && !isDir) {
            [scanFM removeItemAtPath:targetPath error:nil];
        }
    }
    self.finishedSegmentCount = existingCount;
    self.downloadStatus = BszM3u8DownloadStatusDownloading;

    if (self.downloadM3U8StatusExeBlock) {
        self.downloadM3U8StatusExeBlock(self.finishedSegmentCount, self.totalSegmentCount);
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:self.outputPath isDirectory:&isDirectory] || !isDirectory) {
        NSError *dirError = nil;
        [fm createDirectoryAtPath:self.outputPath withIntermediateDirectories:YES attributes:nil error:&dirError];
        if (dirError) {
            self.downloadStatus = BszM3u8DownloadStatusStopped;
            if (self.downloadStopExeBlock) {
                self.downloadStopExeBlock();
            }
            return;
        }
    }

    // 分片调度：避免一次性创建大量 downloadTask（会触发 __NSCFLocalDownloadFile: error 24）
    dispatch_group_t group = dispatch_group_create();
    BszDownloaderDispatchSyncSafe(self.syncQueue, ^{
        [self.pendingSegmentItems removeAllObjects];
        self.activeSegmentCount = 0;
    });

    for (NSURL *segmentURL in segmentURLs) {
        NSString *fileName = [BszM3u8Tool localFileNameForURL:segmentURL];
        if (fileName.length == 0) {
            fileName = [[NSUUID UUID] UUIDString];
        }
        NSString *targetPath = [self.outputPath stringByAppendingPathComponent:fileName];
        NSURL *targetURL = [NSURL fileURLWithPath:targetPath];

        // 已存在的 TS 直接跳过网络请求
        if (BszFileExistsAndNonEmpty(fm, targetPath)) {
            continue;
        }

        dispatch_group_enter(group);

        // 空文件/坏文件先删掉，避免被当成已完成
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:targetPath isDirectory:&isDir] && !isDir) {
            [fm removeItemAtPath:targetPath error:nil];
        }

        BszDownloaderDispatchSyncSafe(self.syncQueue, ^{
            [self.pendingSegmentItems addObject:@{ @"url": segmentURL,
                                                  @"fileName": fileName,
                                                  @"targetURL": targetURL }];
        });
    }

    // 启动首批任务
    [self startNextSegmentsIfNeededWithGroup:group generation:generation];

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{

        // 若中途触发了新的 start/resume，或任务已暂停/停止/中止，本轮 notify 直接丢弃
        if ([self shouldIgnoreCallbackForGeneration:generation]) {
            return;
        }
        // 如果有失败的分片，则认为整体下载失败，不生成本地 m3u8
        if (self.hasFailedSegments) {
            self.downloadStatus = BszM3u8DownloadStatusStopped;
            if (self.downloadStopExeBlock) {
                self.downloadStopExeBlock();
            }
            return;
        }

        NSError *writeError = nil;
                NSString *localPath = [BszM3u8Tool writeLocalizedPlaylistWithLines:lines
                                                                                                                                    baseURL:baseURL
                                                                                                                                     keyMap:keyMap
                                                                                                                    outputDirectory:self.outputPath
                                                                                                                                 fileName:@"index.m3u8"
                                                                                                                                        error:&writeError];
        if (writeError || localPath.length == 0) {
            self.completedFromCache = NO;
            self.downloadStatus = BszM3u8DownloadStatusStopped;
            if (self.downloadStopExeBlock) {
                self.downloadStopExeBlock();
            }
            return;
        }

        // 正常完整下载完成的情况
        self.completedFromCache = NO;

        self.downloadStatus = BszM3u8DownloadStatusCompleted;
        [self syncStatusToManager];
        if (self.downloadCompleteExeBlock) {
            self.downloadCompleteExeBlock();
        }
    });
}

- (void)handleSegmentFinishedForURL:(NSURL *)segmentURL
                           fileName:(NSString *)fileName
                               error:(NSError *)error {
    BszDownloaderDispatchSyncSafe(self.syncQueue, ^{
        [self.segmentTasks removeObjectForKey:segmentURL];
        [self.segmentRetryCounts removeObjectForKey:segmentURL];
    });

    if (self.aborted) {
        return;
    }

    // 若已暂停或已停止，不再推进进度，避免“取消”被计入完成导致加速完成
    if (self.downloadStatus == BszM3u8DownloadStatusPaused ||
        self.downloadStatus == BszM3u8DownloadStatusStopped) {
        return;
    }

    if (error) {
        // 超时、网络错误等都视为失败；被取消的请求不算失败
        BOOL isCancelled = (error.code == NSURLErrorCancelled);
        if (!isCancelled) {
            self.hasFailedSegments = YES;
        }
        if (self.downloadTSFailureExeBlock) {
            self.downloadTSFailureExeBlock(fileName, error);
        }
        if (isCancelled) {
            return; // 暂停/取消触发的取消错误不计入完成数
        }
    } else {
        if (self.downloadTSSuccessExeBlock) {
            self.downloadTSSuccessExeBlock(fileName);
        }
    }

    self.finishedSegmentCount += 1;

    if (self.downloadM3U8StatusExeBlock) {
        self.downloadM3U8StatusExeBlock(self.finishedSegmentCount, self.totalSegmentCount);
    }

    float progress = self.progress;
    if (self.downloadFileProgressExeBlock) {
        self.downloadFileProgressExeBlock(progress);
    }

    // 每个分片完成后，同步一次进度/状态到 Manager，
    // 这样本地持久化记录会随着下载过程实时更新。
    [self syncStatusToManager];
}

#pragma mark - Segment scheduler

- (void)startNextSegmentsIfNeededWithGroup:(dispatch_group_t)group generation:(NSUInteger)generation {
    if (!group) {
        return;
    }

    // 统一在 syncQueue 内部调度，避免 active/pending 并发问题
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.syncQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }

        if ([strongSelf shouldIgnoreCallbackForGeneration:generation]) {
            return;
        }

        if (!strongSelf.session) {
            return;
        }

        NSInteger limit = strongSelf.segmentConcurrencyLimit > 0 ? strongSelf.segmentConcurrencyLimit : 1;
        while (strongSelf.activeSegmentCount < limit && strongSelf.pendingSegmentItems.count > 0) {
            NSDictionary *item = strongSelf.pendingSegmentItems.firstObject;
            [strongSelf.pendingSegmentItems removeObjectAtIndex:0];

            NSURL *segmentURL = item[@"url"];
            NSString *fileName = item[@"fileName"];
            NSURL *targetURL = item[@"targetURL"];
            if (![segmentURL isKindOfClass:[NSURL class]] || ![targetURL isKindOfClass:[NSURL class]] || ![fileName isKindOfClass:[NSString class]] || fileName.length == 0) {
                dispatch_group_leave(group);
                continue;
            }

            strongSelf.activeSegmentCount += 1;
            // 启动任务（slot 占用直到该分片最终完成/失败/取消）
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf startDownloadTaskForSegmentURL:segmentURL
                                                fileName:fileName
                                               targetURL:targetURL
                                                   group:group
                                              generation:generation];
            });
        }
    });
}

// 单个分片的下载逻辑，支持最多 3 次重试。重试期间不 leave group，避免过早完成。
- (void)startDownloadTaskForSegmentURL:(NSURL *)segmentURL
                              fileName:(NSString *)fileName
                             targetURL:(NSURL *)targetURL
                                 group:(dispatch_group_t)group
                            generation:(NSUInteger)generation {
    if (!self.session) {
        self.hasFailedSegments = YES;
        [self failAndAbortForError:nil];
        BszDownloaderDispatchSyncSafe(self.syncQueue, ^{
            self.activeSegmentCount = MAX(0, self.activeSegmentCount - 1);
        });
        dispatch_group_leave(group);
        [self startNextSegmentsIfNeededWithGroup:group generation:generation];
        return;
    }

    __weak typeof(self) weakSelf = self;
    NSURLSessionDownloadTask *task = [self.session downloadTaskWithURL:segmentURL
                                                     completionHandler:^(NSURL * _Nullable location, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            dispatch_group_leave(group);
            return;
        }

        // 屏蔽上一轮 start/resume 的分片回调（但必须 leave group，避免旧轮 group_notify 卡死）
        if (generation != strongSelf.downloadGeneration) {
            BszDownloaderDispatchSyncSafe(strongSelf.syncQueue, ^{
                strongSelf.activeSegmentCount = MAX(0, strongSelf.activeSegmentCount - 1);
            });
            dispatch_group_leave(group);
            [strongSelf startNextSegmentsIfNeededWithGroup:group generation:strongSelf.downloadGeneration];
            return;
        }

        if (strongSelf.aborted) {
            BszDownloaderDispatchSyncSafe(strongSelf.syncQueue, ^{
                strongSelf.activeSegmentCount = MAX(0, strongSelf.activeSegmentCount - 1);
            });
            dispatch_group_leave(group);
            [strongSelf startNextSegmentsIfNeededWithGroup:group generation:generation];
            return;
        }

        NSError *finalError = error;
        if (!finalError && [response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSInteger statusCode = ((NSHTTPURLResponse *)response).statusCode;
            if (statusCode < 200 || statusCode >= 300) {
                finalError = [NSError errorWithDomain:BszM3u8DownloaderErrorDomain
                                                 code:statusCode
                                             userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP status %ld", (long)statusCode]}];
            }
        }

        if (finalError) {
            BOOL isCancelled = (finalError.code == NSURLErrorCancelled);
            if (isCancelled || strongSelf.downloadStatus == BszM3u8DownloadStatusPaused || strongSelf.downloadStatus == BszM3u8DownloadStatusStopped) {
                BszDownloaderDispatchSyncSafe(strongSelf.syncQueue, ^{
                    strongSelf.activeSegmentCount = MAX(0, strongSelf.activeSegmentCount - 1);
                });
                dispatch_group_leave(group);
                [strongSelf startNextSegmentsIfNeededWithGroup:group generation:generation];
                return;
            }

            __block NSInteger attempt = 0;
            BszDownloaderDispatchSyncSafe(strongSelf.syncQueue, ^{
                attempt = [strongSelf.segmentRetryCounts[segmentURL] integerValue];
                attempt += 1; // 当前尝试次数
                strongSelf.segmentRetryCounts[segmentURL] = @(attempt);
            });

            if (attempt < 3 && !strongSelf.aborted) {
                // 重试单个分片；不 leave group，继续等待最终结果
                dispatch_async(dispatch_get_main_queue(), ^{
                    [strongSelf startDownloadTaskForSegmentURL:segmentURL
                                                    fileName:fileName
                                                   targetURL:targetURL
                                                       group:group
                                                  generation:generation];
                });
                return;
            }

            strongSelf.hasFailedSegments = YES;
            [strongSelf handleSegmentFinishedForURL:segmentURL
                                           fileName:fileName
                                             error:finalError];
            [strongSelf failAndAbortForError:finalError];
            BszDownloaderDispatchSyncSafe(strongSelf.syncQueue, ^{
                strongSelf.activeSegmentCount = MAX(0, strongSelf.activeSegmentCount - 1);
            });
            dispatch_group_leave(group);
            [strongSelf startNextSegmentsIfNeededWithGroup:group generation:generation];
            return;
        }

        NSFileManager *fileManager = [NSFileManager defaultManager];
        [fileManager removeItemAtURL:targetURL error:nil];
        NSError *moveError = nil;
        [fileManager moveItemAtURL:location toURL:targetURL error:&moveError];

        // 0 字节文件视为失败（常见于鉴权失败返回空响应/被中间层截断）
        if (!moveError) {
            if (!BszFileExistsAndNonEmpty(fileManager, targetURL.path)) {
                [fileManager removeItemAtURL:targetURL error:nil];
                moveError = [NSError errorWithDomain:BszM3u8DownloaderErrorDomain
                                                code:-2
                                            userInfo:@{NSLocalizedDescriptionKey: @"Downloaded file is empty"}];
            }
        }

        if (!moveError) {
            NSError *sizeError = nil;
            NSDictionary *attrs = [fileManager attributesOfItemAtPath:targetURL.path error:&sizeError];
            unsigned long long fileSize = [attrs fileSize];
            if (!sizeError && fileSize > 0) {
                [strongSelf recordDownloadedBytes:(NSUInteger)fileSize];
            }
        }

        if (!strongSelf.aborted) {
            [strongSelf handleSegmentFinishedForURL:segmentURL
                                           fileName:fileName
                                             error:moveError];
        }

        BszDownloaderDispatchSyncSafe(strongSelf.syncQueue, ^{
            strongSelf.activeSegmentCount = MAX(0, strongSelf.activeSegmentCount - 1);
        });
        dispatch_group_leave(group);
        [strongSelf startNextSegmentsIfNeededWithGroup:group generation:generation];
    }];

    BszDownloaderDispatchSyncSafe(self.syncQueue, ^{
        self.segmentTasks[segmentURL] = task;
    });

    [task resume];
}

// 分片重试耗尽或出现致命错误时，标记失败并中止所有任务
- (void)failAndAbortForError:(NSError *)error {
    if (self.aborted) {
        return;
    }
    self.aborted = YES;

    // 取消所有分片任务
    BszDownloaderDispatchSyncSafe(self.syncQueue, ^{
        [self.segmentTasks enumerateKeysAndObjectsUsingBlock:^(NSURL * _Nonnull key, NSURLSessionDownloadTask * _Nonnull obj, BOOL * _Nonnull stop) {
            [obj cancel];
        }];
        [self.segmentTasks removeAllObjects];
        [self.segmentRetryCounts removeAllObjects];
    });

    [self.session invalidateAndCancel];
    self.session = nil;

    [self resetSpeedTracking];

    self.downloadStatus = BszM3u8DownloadStatusStopped;
    [self syncStatusToManager];
    if (self.downloadStopExeBlock) {
        self.downloadStopExeBlock();
    }
}

- (float)progress {
    if (self.totalSegmentCount == 0) return 0.0f;
    return (float)self.finishedSegmentCount / (float)self.totalSegmentCount;
}

@end
