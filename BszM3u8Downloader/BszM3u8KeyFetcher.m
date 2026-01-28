#import "BszM3u8KeyFetcher.h"
#import "BszM3u8Tool.h"

@interface BszM3u8KeyFetcher ()
@property (nonatomic, copy) NSString *outputDirectory;
@end

@implementation BszM3u8KeyFetcher

- (instancetype)initWithOutputDirectory:(NSString *)outputDirectory {
    self = [super init];
    if (self) {
        _outputDirectory = [outputDirectory copy] ?: @"";
    }
    return self;
}

- (NSDictionary<NSString *, NSString *> *)fetchKeysForPlaylistLines:(NSArray<NSString *> *)lines
                                                           baseURL:(NSURL *)baseURL
                                                     timeoutSeconds:(NSTimeInterval)timeoutSeconds
                                                          hadError:(BOOL *)hadError {
    if (hadError) {
        *hadError = NO;
    }
    if (lines.count == 0 || !baseURL || self.outputDirectory.length == 0) {
        return @{};
    }

    __block BOOL anyError = NO;
    NSMutableDictionary<NSString *, NSString *> *map = [NSMutableDictionary dictionary];
    dispatch_queue_t keyMapQueue = dispatch_queue_create("com.bszm3u8.keyfetcher.map", DISPATCH_QUEUE_SERIAL);

    // 确保输出目录存在
    NSFileManager *fmDir = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fmDir fileExistsAtPath:self.outputDirectory isDirectory:&isDir] || !isDir) {
        NSError *dirError = nil;
        [fmDir createDirectoryAtPath:self.outputDirectory withIntermediateDirectories:YES attributes:nil error:&dirError];
        if (dirError) {
            anyError = YES;
            if (hadError) {
                *hadError = YES;
            }
            return @{};
        }
    }

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    dispatch_group_t group = dispatch_group_create();

    for (NSString *line in lines) {
        NSString *trim = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trim.length == 0 || ![trim hasPrefix:@"#EXT-X-KEY"]) {
            continue;
        }

        NSRange uriRange = [line rangeOfString:@"URI=\""]; // URI="..."
        if (uriRange.location == NSNotFound) {
            continue;
        }

        NSUInteger valueStart = NSMaxRange(uriRange);
        if (valueStart >= line.length) {
            continue;
        }

        NSRange searchRange = NSMakeRange(valueStart, line.length - valueStart);
        NSRange quoteRange = [line rangeOfString:@"\"" options:0 range:searchRange];
        if (quoteRange.location == NSNotFound || quoteRange.location <= valueStart) {
            continue;
        }

        NSString *uriValue = [line substringWithRange:NSMakeRange(valueStart, quoteRange.location - valueStart)];
        if (uriValue.length == 0) {
            continue;
        }

        NSURL *remoteURL = [NSURL URLWithString:uriValue relativeToURL:baseURL];
        if (!remoteURL) {
            continue;
        }

        __block BOOL alreadyHandled = NO;
        dispatch_sync(keyMapQueue, ^{
            alreadyHandled = (map[uriValue] != nil);
        });
        if (alreadyHandled) {
            continue;
        }

        NSString *fileName = [BszM3u8Tool localFileNameForURL:remoteURL];
        if (fileName.length == 0) {
            fileName = @"enc.key";
        }
        NSString *targetPath = [self.outputDirectory stringByAppendingPathComponent:fileName];

        // 已存在则复用
        if ([[NSFileManager defaultManager] fileExistsAtPath:targetPath]) {
            dispatch_sync(keyMapQueue, ^{
                map[uriValue] = fileName;
            });
            continue;
        }

        // 先占位，避免重复创建任务
        dispatch_sync(keyMapQueue, ^{
            if (!map[uriValue]) {
                map[uriValue] = fileName;
            }
        });

        dispatch_group_enter(group);
        NSURLSessionDataTask *task = [session dataTaskWithURL:remoteURL
                                           completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
            NSError *finalError = error;
            if (!finalError && [response isKindOfClass:[NSHTTPURLResponse class]]) {
                NSInteger statusCode = ((NSHTTPURLResponse *)response).statusCode;
                if (statusCode < 200 || statusCode >= 300) {
                    finalError = [NSError errorWithDomain:@"BszM3u8KeyFetcher"
                                                     code:statusCode
                                                 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP status %ld", (long)statusCode]}];
                }
            }

            if (!finalError && data.length > 0) {
                NSFileManager *fm = [NSFileManager defaultManager];
                [fm removeItemAtPath:targetPath error:nil];
                NSError *writeError = nil;
                BOOL ok = [data writeToFile:targetPath options:NSDataWritingAtomic error:&writeError];
                if (!ok || writeError) {
                    dispatch_sync(keyMapQueue, ^{
                        anyError = YES;
                    });
                } else {
                    dispatch_sync(keyMapQueue, ^{
                        map[uriValue] = fileName;
                    });
                }
            } else {
                dispatch_sync(keyMapQueue, ^{
                    anyError = YES;
                });
            }
            dispatch_group_leave(group);
        }];
        [task resume];
    }

    NSTimeInterval t = timeoutSeconds > 0 ? timeoutSeconds : 30.0;
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(t * NSEC_PER_SEC));
    dispatch_group_wait(group, timeout);

    [session invalidateAndCancel];

    if (hadError) {
        __block BOOL errSnapshot = NO;
        dispatch_sync(keyMapQueue, ^{
            errSnapshot = anyError;
        });
        *hadError = errSnapshot;
    }

    __block NSDictionary<NSString *, NSString *> *result = nil;
    dispatch_sync(keyMapQueue, ^{
        result = map.copy;
    });
    return result ?: @{};
}

@end
