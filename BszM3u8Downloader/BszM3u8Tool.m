#import "BszM3u8Tool.h"

static inline NSString *BszTrimmedLine(NSString *line) {
    return [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static inline NSString *BszStripQueryAndFragment(NSString *s, BOOL stripQuery, BOOL stripFragment) {
    if (s.length == 0) {
        return s;
    }
    NSRange q = stripQuery ? [s rangeOfString:@"?"] : (NSRange){NSNotFound, 0};
    NSRange h = stripFragment ? [s rangeOfString:@"#"] : (NSRange){NSNotFound, 0};
    NSUInteger cut = NSNotFound;
    if (q.location != NSNotFound) {
        cut = q.location;
    }
    if (h.location != NSNotFound) {
        cut = (cut == NSNotFound) ? h.location : MIN(cut, h.location);
    }
    if (cut == NSNotFound) {
        return s;
    }
    return [s substringToIndex:cut];
}

static inline uint64_t BszFNV1a64(const void *bytes, size_t length) {
    const uint8_t *p = (const uint8_t *)bytes;
    uint64_t hash = 1469598103934665603ULL;
    for (size_t i = 0; i < length; i++) {
        hash ^= (uint64_t)p[i];
        hash *= 1099511628211ULL;
    }
    return hash;
}

static inline BOOL BszLocalFileExistsAndNonEmpty(NSFileManager *fm, NSString *path) {
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
    return [attrs fileSize] > 0;
}

static inline NSString * _Nullable BszExtractQuotedURIValue(NSString *line) {
    if (line.length == 0) {
        return nil;
    }
    NSRange uriRange = [line rangeOfString:@"URI=\""];
    if (uriRange.location == NSNotFound) {
        return nil;
    }
    NSUInteger valueStart = NSMaxRange(uriRange);
    if (valueStart >= line.length) {
        return nil;
    }
    NSRange searchRange = NSMakeRange(valueStart, line.length - valueStart);
    NSRange quoteRange = [line rangeOfString:@"\"" options:0 range:searchRange];
    if (quoteRange.location == NSNotFound || quoteRange.location <= valueStart) {
        return nil;
    }
    NSString *val = [line substringWithRange:NSMakeRange(valueStart, quoteRange.location - valueStart)];
    val = BszTrimmedLine(val);
    return val.length ? val : nil;
}

static inline NSString * _Nullable BszReplaceQuotedURIValue(NSString *line, NSString *newValue) {
    if (line.length == 0 || newValue.length == 0) {
        return nil;
    }
    NSRange uriRange = [line rangeOfString:@"URI=\""];
    if (uriRange.location == NSNotFound) {
        return nil;
    }
    NSUInteger valueStart = NSMaxRange(uriRange);
    if (valueStart >= line.length) {
        return nil;
    }
    NSRange searchRange = NSMakeRange(valueStart, line.length - valueStart);
    NSRange quoteRange = [line rangeOfString:@"\"" options:0 range:searchRange];
    if (quoteRange.location == NSNotFound || quoteRange.location <= valueStart) {
        return nil;
    }
    NSRange valueRange = NSMakeRange(valueStart, quoteRange.location - valueStart);
    NSMutableString *mutableLine = [line mutableCopy];
    [mutableLine replaceCharactersInRange:valueRange withString:newValue];
    return mutableLine;
}

@implementation BszM3u8Tool

+ (NSString *)localFileNameForURL:(NSURL *)url {
    if (!url) {
        return @"resource";
    }

    NSString *base = url.lastPathComponent;
    if (base.length == 0) {
        base = @"resource";
    }

    // 只有在 query 存在时才加 hash，尽量兼容旧缓存。
    NSString *query = url.query;
    if (query.length == 0) {
        return base;
    }

    NSString *abs = BszStripQueryAndFragment(url.absoluteString ?: @"", NO, YES);
    NSData *data = [abs dataUsingEncoding:NSUTF8StringEncoding];
    uint64_t h = BszFNV1a64(data.bytes, data.length);
    uint32_t shortH = (uint32_t)(h ^ (h >> 32));
    NSString *hashStr = [NSString stringWithFormat:@"%08x", shortH];

    NSString *name = base.stringByDeletingPathExtension;
    NSString *ext = base.pathExtension;
    if (name.length == 0) {
        name = base;
    }

    NSString *newName = [NSString stringWithFormat:@"%@_%@", name, hashStr];
    if (ext.length > 0) {
        return [newName stringByAppendingPathExtension:ext];
    }
    return newName;
}

+ (nullable NSString *)firstVariantURIFromLines:(NSArray<NSString *> *)lines {
    if (lines.count == 0) {
        return nil;
    }

    BOOL expectVariantURL = NO;
    for (NSString *line in lines) {
        NSString *trim = BszTrimmedLine(line);
        if (trim.length == 0) {
            continue;
        }

        if ([trim hasPrefix:@"#EXT-X-STREAM-INF"]) {
            expectVariantURL = YES;
            continue;
        }

        if (expectVariantURL) {
            if ([trim hasPrefix:@"#"]) {
                continue;
            }
            return trim;
        }
    }

    return nil;
}

+ (NSArray<NSURL *> *)segmentURLsFromLines:(NSArray<NSString *> *)lines baseURL:(NSURL *)baseURL {
    if (lines.count == 0 || !baseURL) {
        return @[];
    }

    NSMutableOrderedSet<NSURL *> *segmentURLs = [NSMutableOrderedSet orderedSet];
    for (NSString *line in lines) {
        NSString *trim = BszTrimmedLine(line);
        if (trim.length == 0) {
            continue;
        }

        if ([trim hasPrefix:@"#EXT-X-MAP"]) {
            NSString *uriValue = BszExtractQuotedURIValue(line);
            if (uriValue.length > 0) {
                NSURL *mapURL = [NSURL URLWithString:uriValue relativeToURL:baseURL];
                if (mapURL) {
                    [segmentURLs addObject:mapURL];
                }
            }
            continue;
        }

        if ([trim hasPrefix:@"#"]) {
            continue;
        }

        NSURL *segmentURL = [NSURL URLWithString:trim relativeToURL:baseURL];
        if (segmentURL) {
            [segmentURLs addObject:segmentURL];
        }
    }

    return segmentURLs.array;
}

+ (nullable NSString *)writeLocalizedPlaylistWithLines:(NSArray<NSString *> *)lines
                                              baseURL:(NSURL *)baseURL
                                               keyMap:(NSDictionary<NSString *, NSString *> *)keyMap
                                      outputDirectory:(NSString *)outputDirectory
                                             fileName:(NSString *)fileName
                                                error:(NSError * _Nullable * _Nullable)error {
    if (error) {
        *error = nil;
    }

    if (lines.count == 0 || outputDirectory.length == 0 || !baseURL) {
        return nil;
    }

    NSString *safeFileName = fileName.length > 0 ? fileName : @"index.m3u8";
    NSMutableArray<NSString *> *mutableLines = [NSMutableArray arrayWithCapacity:lines.count];
    NSFileManager *fm = [NSFileManager defaultManager];

    BOOL hasMissingLocalResources = NO;
    NSInteger missingCount = 0;
    NSString * _Nullable firstMissingPath = nil;

    for (NSString *line in lines) {
        NSString *trim = BszTrimmedLine(line);
        if (trim.length == 0) {
            [mutableLines addObject:line];
            continue;
        }

        if ([trim hasPrefix:@"#EXT-X-MAP"]) {
            NSString *uriValue = BszExtractQuotedURIValue(line);
            if (uriValue.length == 0) {
                [mutableLines addObject:line];
                continue;
            }
            NSURL *resolvedURL = [NSURL URLWithString:uriValue relativeToURL:baseURL];
            NSString *localFileName = resolvedURL ? [self localFileNameForURL:resolvedURL] : nil;
            if (localFileName.length == 0) {
                [mutableLines addObject:line];
                continue;
            }

            NSString *localPath = [outputDirectory stringByAppendingPathComponent:localFileName];
            if (!BszLocalFileExistsAndNonEmpty(fm, localPath)) {
                hasMissingLocalResources = YES;
                missingCount += 1;
                firstMissingPath = firstMissingPath ?: localPath;
                [mutableLines addObject:line];
                continue;
            }

            NSString *replaced = BszReplaceQuotedURIValue(line, localFileName);
            [mutableLines addObject:(replaced ?: line)];
            continue;
        }

        if ([trim hasPrefix:@"#EXT-X-KEY"]) {
            NSString *uriValue = BszExtractQuotedURIValue(line);
            if (uriValue.length == 0) {
                [mutableLines addObject:line];
                continue;
            }

            NSString *localFileName = nil;
            if (uriValue.length > 0) {
                localFileName = keyMap[uriValue];
            }

            if (localFileName.length == 0) {
                hasMissingLocalResources = YES;
                missingCount += 1;
                [mutableLines addObject:line];
                continue;
            }

            NSString *keyPath = [outputDirectory stringByAppendingPathComponent:localFileName];
            if (!BszLocalFileExistsAndNonEmpty(fm, keyPath)) {
                hasMissingLocalResources = YES;
                missingCount += 1;
                firstMissingPath = firstMissingPath ?: keyPath;
                [mutableLines addObject:line];
                continue;
            }

            NSString *replaced = BszReplaceQuotedURIValue(line, localFileName);
            [mutableLines addObject:(replaced ?: line)];
            continue;
        }

        if ([trim hasPrefix:@"#"]) {
            [mutableLines addObject:line];
            continue;
        }

        NSURL *resolvedURL = [NSURL URLWithString:trim relativeToURL:baseURL];
        NSString *segmentFileName = resolvedURL ? [self localFileNameForURL:resolvedURL] : (trim ?: @"");
        NSString *targetPath = [outputDirectory stringByAppendingPathComponent:segmentFileName];
        if (!BszLocalFileExistsAndNonEmpty(fm, targetPath)) {
            hasMissingLocalResources = YES;
            missingCount += 1;
            firstMissingPath = firstMissingPath ?: targetPath;
            [mutableLines addObject:line];
            continue;
        }

        [mutableLines addObject:segmentFileName];
    }

    NSString *localPlaylist = [mutableLines componentsJoinedByString:@"\n"]; 
    NSString *localPath = [outputDirectory stringByAppendingPathComponent:safeFileName];

    if (hasMissingLocalResources) {
        [fm removeItemAtPath:localPath error:nil];
        if (error) {
            NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
            userInfo[NSLocalizedDescriptionKey] = [NSString stringWithFormat:@"Playlist not fully localized; missing %ld resources", (long)missingCount];
            if (firstMissingPath.length > 0) {
                userInfo[@"firstMissingPath"] = firstMissingPath;
            }
            *error = [NSError errorWithDomain:@"BszM3u8Tool" code:-100 userInfo:userInfo];
        }
        return nil;
    }

    NSError *writeError = nil;
    [localPlaylist writeToFile:localPath atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
    if (writeError) {
        if (error) {
            *error = writeError;
        }
        return nil;
    }

    return localPath;
}

+ (BOOL)isLocalizedIndexPlaylistCompleteAtPath:(NSString *)indexPath outputDirectory:(NSString *)outputDirectory {
    if (indexPath.length == 0 || outputDirectory.length == 0) {
        return NO;
    }

    NSError *readError = nil;
    NSString *content = [NSString stringWithContentsOfFile:indexPath encoding:NSUTF8StringEncoding error:&readError];
    if (readError || content.length == 0) {
        return NO;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *lines = [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    BOOL foundAnySegment = NO;

    for (NSString *line in lines) {
        NSString *trim = BszTrimmedLine(line);
        if (trim.length == 0) {
            continue;
        }

        if ([trim hasPrefix:@"#EXT-X-MAP"]) {
            NSString *uriValue = BszExtractQuotedURIValue(line);
            uriValue = BszStripQueryAndFragment(uriValue ?: @"", YES, YES);
            if (uriValue.length == 0) {
                return NO;
            }
            if ([uriValue rangeOfString:@"://"].location != NSNotFound) {
                return NO;
            }
            NSString *mapPath = [outputDirectory stringByAppendingPathComponent:uriValue];
            if (!BszLocalFileExistsAndNonEmpty(fm, mapPath)) {
                return NO;
            }
            continue;
        }

        if ([trim hasPrefix:@"#EXT-X-KEY"]) {
            NSString *uriValue = BszExtractQuotedURIValue(line);
            uriValue = BszStripQueryAndFragment(uriValue ?: @"", YES, YES);
            if (uriValue.length == 0) {
                return NO;
            }
            if ([uriValue rangeOfString:@"://"].location != NSNotFound) {
                return NO;
            }
            NSString *keyPath = [outputDirectory stringByAppendingPathComponent:uriValue];
            if (!BszLocalFileExistsAndNonEmpty(fm, keyPath)) {
                return NO;
            }
            continue;
        }

        if ([trim hasPrefix:@"#"]) {
            continue;
        }

        NSString *segmentRef = BszStripQueryAndFragment(trim, YES, YES);
        if (segmentRef.length == 0) {
            continue;
        }
        if ([segmentRef rangeOfString:@"://"].location != NSNotFound) {
            return NO;
        }

        foundAnySegment = YES;
        NSString *segmentPath = [outputDirectory stringByAppendingPathComponent:segmentRef];
        if (!BszLocalFileExistsAndNonEmpty(fm, segmentPath)) {
            return NO;
        }
    }

    return foundAnySegment;
}

@end
