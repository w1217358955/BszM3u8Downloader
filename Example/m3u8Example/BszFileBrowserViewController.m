//
//  BszFileBrowserViewController.m
//  m3u8Example
//

#import "BszFileBrowserViewController.h"

@interface BszFileBrowserViewController ()

@property (nonatomic, copy) NSString *rootPath;
@property (nonatomic, strong) NSArray<NSDictionary<NSString *, id> *> *items;
@property (nonatomic, strong) UILabel *pathLabel;

@end

@implementation BszFileBrowserViewController

- (instancetype)initWithPath:(NSString *)path {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (!self) { return nil; }

    if (path.length > 0) {
        _rootPath = [path copy];
    } else {
        _rootPath = [[self.class defaultStoreRootPath] copy];
    }

    return self;
}

+ (NSString *)defaultStoreRootPath {
    NSArray<NSURL *> *urls = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask];
    NSURL *documentsURL = urls.firstObject;
    if (!documentsURL) {
        return NSTemporaryDirectory();
    }

    NSURL *storeURL = [documentsURL URLByAppendingPathComponent:@"BszM3u8Downloader" isDirectory:YES];
    return storeURL.path;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = 56;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"刷新" style:UIBarButtonItemStylePlain target:self action:@selector(reloadDataFromDisk)];

    UILabel *pathLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    pathLabel.numberOfLines = 0;
    pathLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    pathLabel.textColor = [UIColor secondaryLabelColor];
    pathLabel.text = self.rootPath;
    self.pathLabel = pathLabel;

    if (self.title.length == 0) {
        self.title = [self.rootPath lastPathComponent] ?: @"文件";
    }

    [self reloadDataFromDisk];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGFloat width = CGRectGetWidth(self.tableView.bounds);
    if (width <= 0) {
        return;
    }

    UIEdgeInsets insets = UIEdgeInsetsMake(10, 16, 10, 16);
    CGSize fit = [self.pathLabel sizeThatFits:CGSizeMake(width - insets.left - insets.right, CGFLOAT_MAX)];

    UIView *header = self.tableView.tableHeaderView;
    if (!header) {
        header = [[UIView alloc] initWithFrame:CGRectZero];
        [header addSubview:self.pathLabel];
        self.tableView.tableHeaderView = header;
    }

    CGFloat headerHeight = insets.top + fit.height + insets.bottom;
    CGRect headerFrame = CGRectMake(0, 0, width, headerHeight);
    if (!CGRectEqualToRect(header.frame, headerFrame)) {
        header.frame = headerFrame;
        self.tableView.tableHeaderView = header;
    }

    self.pathLabel.frame = CGRectMake(insets.left, insets.top, width - insets.left - insets.right, fit.height);
}

- (void)reloadDataFromDisk {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:self.rootPath isDirectory:&isDir] || !isDir) {
        self.items = @[];
        [self.tableView reloadData];
        return;
    }

    NSError *error = nil;
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:self.rootPath error:&error];
    if (!names) {
        self.items = @[];
        [self.tableView reloadData];
        return;
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *items = [NSMutableArray arrayWithCapacity:names.count];
    for (NSString *name in names) {
        if (name.length == 0) { continue; }
        NSString *fullPath = [self.rootPath stringByAppendingPathComponent:name];

        BOOL childIsDir = NO;
        [fm fileExistsAtPath:fullPath isDirectory:&childIsDir];

        NSDictionary<NSString *, id> *attrs = [fm attributesOfItemAtPath:fullPath error:nil] ?: @{};
        unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
        NSDate *mod = attrs[NSFileModificationDate];

        [items addObject:@{
            @"name": name,
            @"path": fullPath,
            @"isDir": @(childIsDir),
            @"size": @(size),
            @"mod": mod ?: [NSNull null],
        }];
    }

    [items sortUsingComparator:^NSComparisonResult(NSDictionary<NSString *,id> * _Nonnull a, NSDictionary<NSString *,id> * _Nonnull b) {
        BOOL aDir = [a[@"isDir"] boolValue];
        BOOL bDir = [b[@"isDir"] boolValue];
        if (aDir != bDir) {
            return aDir ? NSOrderedAscending : NSOrderedDescending;
        }
        return [a[@"name"] compare:b[@"name"] options:NSCaseInsensitiveSearch];
    }];

    self.items = [items copy];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"BszFileCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
        cell.detailTextLabel.numberOfLines = 1;
    }

    NSDictionary<NSString *, id> *item = self.items[indexPath.row];
    NSString *name = item[@"name"];
    NSString *path = item[@"path"];
    BOOL isDir = [item[@"isDir"] boolValue];

    cell.textLabel.text = name;
    cell.accessoryType = isDir ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;

    if (isDir) {
        cell.detailTextLabel.text = path;
        cell.imageView.image = [UIImage systemImageNamed:@"folder"];
    } else {
        unsigned long long size = [item[@"size"] unsignedLongLongValue];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@  ·  %@", [self.class formattedBytes:size], path];
        cell.imageView.image = [UIImage systemImageNamed:@"doc"];
    }

    return cell;
}

+ (NSString *)formattedBytes:(unsigned long long)bytes {
    double value = (double)bytes;
    NSArray<NSString *> *units = @[ @"B", @"KB", @"MB", @"GB" ];
    NSInteger unitIndex = 0;
    while (value >= 1024.0 && unitIndex < (NSInteger)units.count - 1) {
        value /= 1024.0;
        unitIndex += 1;
    }
    if (unitIndex == 0) {
        return [NSString stringWithFormat:@"%llu%@", bytes, units[unitIndex]];
    }
    return [NSString stringWithFormat:@"%.2f%@", value, units[unitIndex]];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSDictionary<NSString *, id> *item = self.items[indexPath.row];
    NSString *path = item[@"path"];
    BOOL isDir = [item[@"isDir"] boolValue];

    if (isDir) {
        BszFileBrowserViewController *vc = [[BszFileBrowserViewController alloc] initWithPath:path];
        vc.title = [path lastPathComponent];
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[path lastPathComponent] message:path preferredStyle:UIAlertControllerStyleActionSheet];

    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"复制绝对路径" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction * _Nonnull action) {
        [UIPasteboard generalPasteboard].string = path;
        [weakSelf showToast:@"已复制"];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"分享…" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction * _Nonnull action) {
        NSURL *url = [NSURL fileURLWithPath:path];
        UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
        if (avc.popoverPresentationController) {
            avc.popoverPresentationController.sourceView = weakSelf.view;
            avc.popoverPresentationController.sourceRect = [weakSelf.tableView rectForRowAtIndexPath:indexPath];
        }
        [weakSelf presentViewController:avc animated:YES completion:nil];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.view;
        sheet.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:indexPath];
    }

    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showToast:(NSString *)text {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:text preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:nil];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [alert dismissViewControllerAnimated:YES completion:nil];
    });
}

@end
