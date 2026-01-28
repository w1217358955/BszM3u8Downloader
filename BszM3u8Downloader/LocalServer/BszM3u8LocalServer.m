#import "BszM3u8LocalServer.h"
#import "../Manager/BszM3u8DownloadManager.h"

#if __has_include(<GCDWebServer/GCDWebServer.h>)
#import <GCDWebServer/GCDWebServer.h>
#import <GCDWebServer/GCDWebServerDataResponse.h>
#import <GCDWebServer/GCDWebServerFileResponse.h>
#endif

@interface BszM3u8LocalServer ()

#if __has_include(<GCDWebServer/GCDWebServer.h>)
@property (nonatomic, strong) GCDWebServer *webServer;
#endif
@property (nonatomic, copy, readwrite, nullable) NSString *baseURLString;
@property (nonatomic, copy, nullable) NSString *rootDirectory;

#if __has_include(<GCDWebServer/GCDWebServer.h>)
@property (nonatomic, copy, nullable) NSString *preferredIndexFilePath;
#endif

@end

@implementation BszM3u8LocalServer

- (BOOL)ensureIndexExistsWithError:(NSError **)error {
#if __has_include(<GCDWebServer/GCDWebServer.h>)
    NSString *indexPath = self.preferredIndexFilePath.length ? self.preferredIndexFilePath : [self.rootDirectory stringByAppendingPathComponent:@"index.m3u8"];
    BOOL isDir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:indexPath isDirectory:&isDir] || isDir) {
        if (error) {
            *error = [NSError errorWithDomain:@"BszM3u8LocalServer"
                                         code:-7
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"index.m3u8 not found yet: %@", indexPath ?: @"(null)"]}];
        }
        return NO;
    }
    return YES;
#else
    if (error) {
        *error = [NSError errorWithDomain:@"BszM3u8LocalServer"
                                     code:-2
                                 userInfo:@{NSLocalizedDescriptionKey: @"GCDWebServer is not available, please add it as a dependency."}];
    }
    return NO;
#endif
}

#if __has_include(<GCDWebServer/GCDWebServer.h>)
static NSDictionary<NSString*, NSString*> *BszM3u8MimeTypeOverrides(void) {
    static NSDictionary<NSString*, NSString*> *overrides;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        overrides = @{
            // HLS playlist
            @"m3u8": @"application/vnd.apple.mpegurl",
            // HLS segments
            @"ts": @"video/mp2t",
        };
    });
    return overrides;
}

static void BszApplyCommonStreamingHeaders(GCDWebServerResponse *response) {
    // 兼容 WKWebView / H5 XHR：放开跨域（尤其是 file:// 或自定义 scheme 的页面）
    [response setValue:@"*" forAdditionalHeader:@"Access-Control-Allow-Origin"];
    [response setValue:@"GET, HEAD, OPTIONS" forAdditionalHeader:@"Access-Control-Allow-Methods"];
    [response setValue:@"Range, Content-Type, Origin, Accept, Referer, User-Agent" forAdditionalHeader:@"Access-Control-Allow-Headers"];
    [response setValue:@"Accept-Ranges, Content-Range, Content-Length" forAdditionalHeader:@"Access-Control-Expose-Headers"];
}
#endif

+ (instancetype)sharedServer {
    static BszM3u8LocalServer *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[BszM3u8LocalServer alloc] init];
    });
    return instance;
}

- (BOOL)startWithRootDirectory:(NSString *)rootDirectory error:(NSError **)error {
    if (rootDirectory.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"BszM3u8LocalServer"
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"rootDirectory is empty"}];
        }
        return NO;
    }

    // 先暂存输入，后续会归一化为真正的“目录 root”
    self.rootDirectory = rootDirectory;

#if __has_include(<GCDWebServer/GCDWebServer.h>)
    if (!self.webServer) {
        self.webServer = [[GCDWebServer alloc] init];
    } else if (self.webServer.isRunning) {
        [self.webServer stop];
    }

    __weak typeof(self) weakSelf = self;

    NSString *standardInput = [rootDirectory stringByStandardizingPath];
    NSString *standardRoot = standardInput;
    self.preferredIndexFilePath = nil;

    BOOL isDir = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:standardInput isDirectory:&isDir] && !isDir) {
        // 兼容：传入的是具体文件路径（例如 .../index.m3u8）。
        // 根目录应为其所在目录，同时把该文件作为默认 index。
        standardRoot = [standardInput stringByDeletingLastPathComponent];
        self.preferredIndexFilePath = standardInput;
    }
    standardRoot = [standardRoot stringByStandardizingPath];

    // root 必须存在且是目录，否则启动了 server 也只会一直 404
    BOOL rootIsDir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:standardRoot isDirectory:&rootIsDir] || !rootIsDir) {
        if (error) {
            *error = [NSError errorWithDomain:@"BszM3u8LocalServer"
                                         code:-6
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"rootDirectory not found or not a directory: %@", standardRoot ?: @"(null)"]}];
        }
        return NO;
    }

    // 归一化保存，便于复用/比较
    self.rootDirectory = standardRoot;

    // 自定义文件映射：确保 HLS 相关 Content-Type 正确，同时附带 CORS 头
    [self.webServer addHandlerForMethod:@"GET"
                              pathRegex:@".*"
                           requestClass:[GCDWebServerRequest class]
                           processBlock:^GCDWebServerResponse * _Nullable(__kindof GCDWebServerRequest * _Nonnull request) {
        NSString *reqPath = request.path ?: @"/";

        // 如果调用方传入了具体 index 文件，则优先用它响应 / 和 /index.m3u8
        NSString *preferredIndex = weakSelf.preferredIndexFilePath;
        if (preferredIndex.length > 0 && ([reqPath isEqualToString:@"/"] || [reqPath isEqualToString:@"/index.m3u8"])) {
            GCDWebServerFileResponse *response = [[GCDWebServerFileResponse alloc] initWithFile:preferredIndex
                                                                                      byteRange:request.byteRange
                                                                                   isAttachment:NO
                                                                               mimeTypeOverrides:BszM3u8MimeTypeOverrides()];
            if (!response) {
                return [GCDWebServerResponse responseWithStatusCode:500];
            }
            response.cacheControlMaxAge = 0;
            BszApplyCommonStreamingHeaders(response);
            return response;
        }

        if ([reqPath isEqualToString:@"/"]) {
            reqPath = @"/index.m3u8";
        }

        // 去掉前导 "/"，并进行安全拼接，防止目录穿越
        NSString *relativePath = [reqPath hasPrefix:@"/"] ? [reqPath substringFromIndex:1] : reqPath;
        NSString *candidate = [[standardRoot stringByAppendingPathComponent:relativePath] stringByStandardizingPath];
        if (candidate.length == 0 || ![candidate hasPrefix:standardRoot]) {
#if DEBUG
            NSLog(@"[BszM3u8LocalServer] reject path traversal: root=%@ req=%@ cand=%@", standardRoot, reqPath, candidate);
#endif
            return [GCDWebServerResponse responseWithStatusCode:404];
        }

        BOOL isDirectory = NO;
        BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:candidate isDirectory:&isDirectory];
        if (!exists) {
#if DEBUG
            NSLog(@"[BszM3u8LocalServer] file not found: root=%@ req=%@ cand=%@", standardRoot, reqPath, candidate);
#endif
            return [GCDWebServerResponse responseWithStatusCode:404];
        }
        if (isDirectory) {
            NSString *indexPath = [[candidate stringByAppendingPathComponent:@"index.m3u8"] stringByStandardizingPath];
            if ([[NSFileManager defaultManager] fileExistsAtPath:indexPath isDirectory:NULL]) {
                candidate = indexPath;
            } else {
#if DEBUG
                NSLog(@"[BszM3u8LocalServer] index.m3u8 missing in dir: dir=%@", candidate);
#endif
                return [GCDWebServerResponse responseWithStatusCode:404];
            }
        }

        GCDWebServerFileResponse *response = [[GCDWebServerFileResponse alloc] initWithFile:candidate
                                                                                  byteRange:request.byteRange
                                                                               isAttachment:NO
                                                                           mimeTypeOverrides:BszM3u8MimeTypeOverrides()];
        if (!response) {
            return [GCDWebServerResponse responseWithStatusCode:500];
        }
        response.cacheControlMaxAge = 0;
        BszApplyCommonStreamingHeaders(response);
        return response;
    }];

    // 预检请求：有些 H5 播放器/请求栈会发 OPTIONS
    [self.webServer addHandlerForMethod:@"OPTIONS"
                              pathRegex:@".*"
                           requestClass:[GCDWebServerRequest class]
                           processBlock:^GCDWebServerResponse * _Nullable(__kindof GCDWebServerRequest * _Nonnull request) {
        GCDWebServerResponse *response = [GCDWebServerResponse responseWithStatusCode:204];
        BszApplyCommonStreamingHeaders(response);
        return response;
    }];

    BOOL success = [self.webServer startWithOptions:@{GCDWebServerOption_AutomaticallySuspendInBackground: @YES,
                                                      GCDWebServerOption_Port: @0,
                                                      GCDWebServerOption_BindToLocalhost: @YES}
                                              error:error];
    if (!success) {
        return NO;
    }

    NSString *serverURL = self.webServer.serverURL.absoluteString;
    if (serverURL.length > 0 && [serverURL hasSuffix:@"/"]) {
        serverURL = [serverURL substringToIndex:serverURL.length - 1];
    }
    // WKWebView 对 localhost 的解析在部分环境会有坑，127.0.0.1 更稳
    serverURL = [serverURL stringByReplacingOccurrencesOfString:@"://localhost:"
                                                     withString:@"://127.0.0.1:"];
    weakSelf.baseURLString = serverURL;

    return YES;
#else
    if (error) {
        *error = [NSError errorWithDomain:@"BszM3u8LocalServer"
                                     code:-2
                                 userInfo:@{NSLocalizedDescriptionKey: @"GCDWebServer is not available, please add it as a dependency."}];
    }
    return NO;
#endif
}

- (NSString *)playURLForRootDirectory:(NSString *)rootDirectory error:(NSError **)error {
    if (rootDirectory.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"BszM3u8LocalServer"
                                         code:-3
                                     userInfo:@{NSLocalizedDescriptionKey: @"rootDirectory is empty"}];
        }
        return nil;
    }

    NSString *standardInput = [rootDirectory stringByStandardizingPath];
    // 若当前 server 已是同一 root 且 baseURL 存在，直接复用
    if (self.baseURLString.length > 0 && self.rootDirectory.length > 0 && [self.rootDirectory isEqualToString:standardInput]) {
        if (![self ensureIndexExistsWithError:error]) {
            return nil;
        }
        return [NSString stringWithFormat:@"%@/index.m3u8", self.baseURLString];
    }

    // 切换 root：重启 server
    [self stop];
    BOOL ok = [self startWithRootDirectory:standardInput error:error];
    if (!ok) {
        return nil;
    }
    if (![self ensureIndexExistsWithError:error]) {
        return nil;
    }
    return [NSString stringWithFormat:@"%@/index.m3u8", self.baseURLString];
}

- (NSString *)playURLForTaskId:(NSString *)taskId error:(NSError **)error {
    if (taskId.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"BszM3u8LocalServer"
                                         code:-4
                                     userInfo:@{NSLocalizedDescriptionKey: @"taskId is empty"}];
        }
        return nil;
    }

    BszM3u8DownloadTaskInfo *info = [[BszM3u8DownloadManager sharedManager] taskInfoForTaskId:taskId];
    if (!info || info.outputDir.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"BszM3u8LocalServer"
                                         code:-5
                                     userInfo:@{NSLocalizedDescriptionKey: @"task not found or outputDir missing"}];
        }
        return nil;
    }

    return [self playURLForRootDirectory:info.outputDir error:error];
}

- (void)stop {
#if __has_include(<GCDWebServer/GCDWebServer.h>)
    [self.webServer stop];
    self.baseURLString = nil;
#endif
}

@end
