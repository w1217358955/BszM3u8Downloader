//
//  MultiTaskViewController.m
//  m3u8Example
//

#import "MultiTaskViewController.h"
#import <BszM3u8Downloader/BszM3u8Downloader.h>
#import <BszM3u8Downloader/BszM3u8LocalServer.h>
#import <AVKit/AVKit.h>

@interface BszDemoDownloadItem : NSObject
@property (nonatomic, copy) NSString *identifier; // taskId，默认等于 urlString
@property (nonatomic, copy) NSString *urlString;
@property (nonatomic, copy) NSString *outputDir;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *ext;
@property (nonatomic, assign) float progress;   // 0.0~1.0
@property (nonatomic, assign) BszM3u8DownloadStatus status;
@property (nonatomic, assign) double speedBytesPerSec;
@end

@implementation BszDemoDownloadItem
@end

@interface MultiTaskViewController () <BszM3u8DownloadManagerDelegate>

@property (nonatomic, strong) UISegmentedControl *segmentControl; // 0: 正在下载  1: 已完成
@property (nonatomic, strong) UITableView *tableView;

// 分页标签之上的 4 条 URL 输入 + 每行创建/暂停按钮
@property (nonatomic, strong) UIView *urlHeaderView;
@property (nonatomic, strong) NSArray<UITextField *> *urlFields;
@property (nonatomic, strong) NSArray<UIButton *> *createButtons;
@property (nonatomic, strong) NSArray<UIButton *> *toggleButtons;

@property (nonatomic, strong) UIView *bottomBar;
@property (nonatomic, strong) UIButton *pauseAllButton;
@property (nonatomic, strong) UIButton *resumeAllButton;
@property (nonatomic, strong) UIButton *deleteAllButton;

@property (nonatomic, strong) NSMutableArray<BszDemoDownloadItem *> *items;

@end

@implementation MultiTaskViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    self.title = @"多任务";
    self.items = [NSMutableArray array];
    [self setupUI];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    [BszM3u8DownloadManager sharedManager].delegate = self;

    [self reloadItemsFromManager];
    [self.tableView reloadData];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    BszM3u8DownloadManager *manager = [BszM3u8DownloadManager sharedManager];
    if (manager.delegate == self) {
        manager.delegate = nil;
    }
}

- (void)setupUI {
    CGFloat width = self.view.bounds.size.width;
    CGFloat topMargin = 100.0;

    // 顶部 4 行 URL 输入区（位于分页标签之上）
    CGFloat headerRowHeight = 34.0;
    NSInteger maxRows = 4;
    CGFloat headerHeight = 8.0 + maxRows * (headerRowHeight + 6.0);
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, topMargin, width, headerHeight)];

    NSMutableArray<UITextField *> *fields = [NSMutableArray array];
    NSMutableArray<UIButton *> *createBtns = [NSMutableArray array];
    NSMutableArray<UIButton *> *toggleBtns = [NSMutableArray array];
    NSArray<NSString *> *defaults = [self demoMultiURLs];

    for (NSInteger i = 0; i < maxRows; i++) {
        CGFloat y = 8.0 + (headerRowHeight + 6.0) * i;
        CGFloat margin = 20.0;
        CGFloat buttonWidth = 60.0;
        CGFloat toggleWidth = 70.0;
        CGFloat fieldWidth = width - margin * 2 - buttonWidth - toggleWidth - 10.0 - 10.0;

        UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(margin, y, fieldWidth, headerRowHeight)];
        field.borderStyle = UITextBorderStyleRoundedRect;
        field.font = [UIFont systemFontOfSize:12.0];
        if (i < (NSInteger)defaults.count) {
            field.text = defaults[i];
        }
        [header addSubview:field];
        [fields addObject:field];

        UIButton *createBtn = [self buttonWithTitle:@"创建" action:@selector(singleCreateButtonTapped:) frame:CGRectMake(CGRectGetMaxX(field.frame) + 5.0, y, buttonWidth, headerRowHeight)];
        createBtn.tag = i;
        [header addSubview:createBtn];
        [createBtns addObject:createBtn];

        UIButton *toggleBtn = [self buttonWithTitle:@"暂停" action:@selector(singleToggleButtonTapped:) frame:CGRectMake(CGRectGetMaxX(createBtn.frame) + 5.0, y, toggleWidth, headerRowHeight)];
        toggleBtn.tag = i;
        [header addSubview:toggleBtn];
        [toggleBtns addObject:toggleBtn];
    }

    self.urlHeaderView = header;
    self.urlFields = fields;
    self.createButtons = createBtns;
    self.toggleButtons = toggleBtns;
    [self.view addSubview:self.urlHeaderView];

    // 分页标签（正在下载/已完成）放在 4 行 URL 下面
    self.segmentControl = [[UISegmentedControl alloc] initWithItems:@[@"正在下载", @"已完成下载"]];
    self.segmentControl.frame = CGRectMake(20.0, CGRectGetMaxY(self.urlHeaderView.frame) + 8.0, width - 40.0, 30.0);
    self.segmentControl.selectedSegmentIndex = 0;
    [self.segmentControl addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.segmentControl];

    CGFloat bottomBarHeight = 60.0;
    CGFloat tableY = CGRectGetMaxY(self.segmentControl.frame) + 8.0;
    CGFloat tableHeight = self.view.bounds.size.height - tableY - bottomBarHeight;

    self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, tableY, width, tableHeight) style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = 50.0;
    [self.view addSubview:self.tableView];

    self.bottomBar = [[UIView alloc] initWithFrame:CGRectMake(0, CGRectGetMaxY(self.tableView.frame), width, bottomBarHeight)];
    [self.view addSubview:self.bottomBar];

    CGFloat buttonWidth = (width - 40.0 - 20.0) / 3.0;
    CGFloat x = 20.0;
    self.pauseAllButton = [self buttonWithTitle:@"全部暂停" action:@selector(pauseAll) frame:CGRectMake(x, 10.0, buttonWidth, 40.0)];
    [self.bottomBar addSubview:self.pauseAllButton];

    x += buttonWidth + 10.0;
    self.resumeAllButton = [self buttonWithTitle:@"全部继续" action:@selector(resumeAll) frame:CGRectMake(x, 10.0, buttonWidth, 40.0)];
    [self.bottomBar addSubview:self.resumeAllButton];

    x += buttonWidth + 10.0;
    self.deleteAllButton = [self buttonWithTitle:@"全部删除" action:@selector(deleteAllTasks) frame:CGRectMake(x, 10.0, buttonWidth, 40.0)];
    [self.bottomBar addSubview:self.deleteAllButton];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGFloat width = self.view.bounds.size.width;
    CGFloat topMargin = 100.0;

    CGFloat bottomInset = 0.0;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 110000
    if (@available(iOS 11.0, *)) {
        bottomInset = self.view.safeAreaInsets.bottom;
    }
#endif

    // 顶部 4 行 URL 区域
    if (self.urlHeaderView) {
        CGFloat headerRowHeight = 34.0;
        NSInteger maxRows = self.urlFields.count;
        CGFloat headerHeight = 8.0 + maxRows * (headerRowHeight + 6.0);
        self.urlHeaderView.frame = CGRectMake(0, topMargin, width, headerHeight);

        for (NSInteger i = 0; i < maxRows; i++) {
            CGFloat y = 8.0 + (headerRowHeight + 6.0) * i;
            CGFloat margin = 20.0;
            CGFloat buttonWidth = 60.0;
            CGFloat toggleWidth = 70.0;
            CGFloat fieldWidth = width - margin * 2 - buttonWidth - toggleWidth - 10.0 - 10.0;

            UITextField *field = self.urlFields[i];
            field.frame = CGRectMake(margin, y, fieldWidth, headerRowHeight);

            UIButton *createBtn = self.createButtons[i];
            createBtn.frame = CGRectMake(CGRectGetMaxX(field.frame) + 5.0, y, buttonWidth, headerRowHeight);

            UIButton *toggleBtn = self.toggleButtons[i];
            toggleBtn.frame = CGRectMake(CGRectGetMaxX(createBtn.frame) + 5.0, y, toggleWidth, headerRowHeight);
        }
    }

    // 分页标签在 URL 区域下方
    CGFloat segmentY = CGRectGetMaxY(self.urlHeaderView.frame) + 8.0;
    self.segmentControl.frame = CGRectMake(20.0, segmentY, width - 40.0, 30.0);

    CGFloat bottomBarHeight = 60.0;
    CGFloat tableY = CGRectGetMaxY(self.segmentControl.frame) + 8.0;
    CGFloat tableHeight = self.view.bounds.size.height - tableY - bottomBarHeight - bottomInset;
    if (tableHeight < 0) {
        tableHeight = 0;
    }

    self.tableView.frame = CGRectMake(0, tableY, width, tableHeight);
    self.bottomBar.frame = CGRectMake(0, CGRectGetMaxY(self.tableView.frame), width, bottomBarHeight);
}

- (UIButton *)buttonWithTitle:(NSString *)title action:(SEL)action frame:(CGRect)frame {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = frame;
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

#pragma mark - Restore items from manager

- (void)reloadItemsFromManager {
    BszM3u8DownloadManager *manager = [BszM3u8DownloadManager sharedManager];

    // 先清理已有 items，再根据 Manager 的任务信息重新构建
    [self.items removeAllObjects];

    NSMutableArray<BszM3u8DownloadTaskInfo *> *allInfos = [NSMutableArray array];
    NSArray<BszM3u8DownloadTaskInfo *> *downloading = [manager currentDownloadingTasksAscending:YES] ?: @[];
    NSArray<BszM3u8DownloadTaskInfo *> *completed = [manager completedTasksAscending:YES] ?: @[];
    [allInfos addObjectsFromArray:downloading];
    [allInfos addObjectsFromArray:completed];

    // 根据 Manager 返回的任务信息构建 items（不再额外按 URL 扫描本地目录）
    for (BszM3u8DownloadTaskInfo *info in allInfos) {
        if (info.urlString.length == 0) {
            continue;
        }

        BszDemoDownloadItem *item = [[BszDemoDownloadItem alloc] init];
        item.identifier = info.taskId.length ? info.taskId : info.urlString;
        item.urlString = info.urlString;
        item.outputDir = info.outputDir;
        item.ext = info.ext;
        item.progress = info.progress;
        item.status = info.status;
        item.speedBytesPerSec = info.speedBytesPerSecond;
        [self.items addObject:item];
    }

    // 不要在用户交互（点击 cell/按钮）后“自动跳分页”。
    // 仅当当前分页变为空列表时，才做一次友好的自动切换。
    BOOL hasCompleted = NO;
    BOOL hasUnfinished = NO;
    for (BszDemoDownloadItem *it in self.items) {
        if (it.status == BszM3u8DownloadStatusCompleted) {
            hasCompleted = YES;
        } else {
            hasUnfinished = YES;
        }
        if (hasCompleted && hasUnfinished) {
            break;
        }
    }
    if (self.segmentControl.selectedSegmentIndex == 0) {
        // 正在下载分页：若没有未完成任务但有已完成任务，才切到已完成
        if (!hasUnfinished && hasCompleted) {
            self.segmentControl.selectedSegmentIndex = 1;
        }
    } else {
        // 已完成分页：若没有已完成任务但有未完成任务，才切到正在下载
        if (!hasCompleted && hasUnfinished) {
            self.segmentControl.selectedSegmentIndex = 0;
        }
    }
    [self.tableView reloadData];
}

#pragma mark - Demo URLs

- (NSArray<NSString *> *)demoMultiURLs {
    return @[
        @"https://v.lzcdn25.com/20260110/13539_35168bd7/index.m3u8",
        @"https://s1.fengbao9.com/video/dachengxiaoshi/a0fb2f753cec/index.m3u8",
        @"https://play.hhuus.com/play/mbkE3EJe/index.m3u8",
        @"https://vodcndaa13.rsfcxq.com/20260114/n1zY4zzB/index.m3u8"
    ];
}

- (NSString *)stringForStatus:(BszM3u8DownloadStatus)status {
    switch (status) {
        case BszM3u8DownloadStatusNotReady: return @"未就绪";
        case BszM3u8DownloadStatusReady: return @"等待";
        case BszM3u8DownloadStatusStarting: return @"开始中";
        case BszM3u8DownloadStatusPaused: return @"已暂停";
        case BszM3u8DownloadStatusStopped: return @"失败/已停止";
        case BszM3u8DownloadStatusDownloading: return @"下载中";
        case BszM3u8DownloadStatusCompleted: return @"已完成";
    }
    return @"未知";
}

- (NSString *)prettySpeed:(double)bytesPerSec {
    if (bytesPerSec <= 0) {
        return @"";
    }
    double v = bytesPerSec;
    NSString *unit = @"B/s";
    if (v >= 1024.0) { v /= 1024.0; unit = @"KB/s"; }
    if (v >= 1024.0) { v /= 1024.0; unit = @"MB/s"; }
    if (v >= 1024.0) { v /= 1024.0; unit = @"GB/s"; }
    NSString *formatted = (v >= 100.0) ? [NSString stringWithFormat:@"%.0f %@", v, unit]
                                      : [NSString stringWithFormat:@"%.1f %@", v, unit];
    return [NSString stringWithFormat:@" | 速度：%@", formatted];
}

#pragma mark - Actions

- (void)segmentChanged:(UISegmentedControl *)seg {
    [self.tableView reloadData];
}

- (void)singleCreateButtonTapped:(UIButton *)sender {
    NSInteger index = sender.tag;
    if (index < 0 || index >= (NSInteger)self.urlFields.count) {
        return;
    }
    NSString *url = self.urlFields[index].text;
    url = [url stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (url.length == 0) {
        return;
    }

    // 如果该 URL 已经有任务，就直接恢复/开始
    BszDemoDownloadItem *existing = nil;
    for (BszDemoDownloadItem *it in self.items) {
        if ([it.urlString isEqualToString:url]) {
            existing = it;
            break;
        }
    }

    NSString *movieId = [NSString stringWithFormat:@"video_%ld", (long)index];
    NSString *movieName = [NSString stringWithFormat:@"自定义影片%ld", (long)index];
    NSDictionary *ext = @{ @"movieId": movieId,
                           @"movieName": movieName };

    BszDemoDownloadItem *item = existing;
    if (!item) {
        item = [[BszDemoDownloadItem alloc] init];
        item.urlString = url;
        item.identifier = url;
        item.ext = ext;
        item.progress = 0.0f;
        item.status = BszM3u8DownloadStatusReady;
        [self.items addObject:item];
    }

    NSString *taskId = item.identifier.length ? item.identifier : url;
    NSError *error = nil;
    BOOL ok = [[BszM3u8DownloadManager sharedManager] createAndStartTaskWithTaskId:taskId
                                                                         urlString:url
                                                                               ext:ext
                                                                             error:&error];
    if (!ok) {
        NSLog(@"[m3u8Example] create/start failed: taskId=%@ error=%@", taskId, error.localizedDescription ?: @"unknown");
    }
    [self reloadItemsFromManager];
    [self.tableView reloadData];
}

- (void)singleToggleButtonTapped:(UIButton *)sender {
    NSInteger index = sender.tag;
    if (index < 0 || index >= (NSInteger)self.urlFields.count) {
        return;
    }
    NSString *url = self.urlFields[index].text;
    url = [url stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (url.length == 0) {
        return;
    }

    BszDemoDownloadItem *item = nil;
    for (BszDemoDownloadItem *it in self.items) {
        if ([it.urlString isEqualToString:url]) {
            item = it;
            break;
        }
    }
    if (!item) {
        return; // 还没有创建任务
    }

    BszM3u8DownloadManager *manager = [BszM3u8DownloadManager sharedManager];
    NSString *taskId = item.identifier.length ? item.identifier : item.urlString;
    if (taskId.length == 0) {
        return;
    }

    if (item.status == BszM3u8DownloadStatusDownloading || item.status == BszM3u8DownloadStatusStarting) {
        [manager pauseTaskForTaskId:taskId];
    } else {
        NSError *error = nil;
        BOOL ok = [manager resumeTaskForTaskId:taskId error:&error];
        if (!ok) {
            NSLog(@"[m3u8Example] resume failed: taskId=%@ error=%@", taskId, error.localizedDescription ?: @"unknown");
        }
    }

    [self reloadItemsFromManager];
    [self.tableView reloadData];
}

#pragma mark - BszM3u8DownloadManagerDelegate

- (void)downloadManager:(BszM3u8DownloadManager *)manager
      didUpdateTaskInfo:(BszM3u8DownloadTaskInfo *)taskInfo
                  error:(NSError *)error {
    // Demo 简化：统一从 manager 重新拉一遍列表，保证 UI 与内部状态一致
    // （manager 内部会自行汇聚 progress/status/speed/error）
    if (error) {
        NSLog(@"[m3u8Example] task update error: taskId=%@ error=%@", taskInfo.taskId, error.localizedDescription ?: @"unknown");
    }
    [self reloadItemsFromManager];
    [self.tableView reloadData];
}

- (void)pauseAll {
    [[BszM3u8DownloadManager sharedManager] pauseAll];
    // 统一从 Manager 刷新状态，确保并发/队列状态一致
    [self reloadItemsFromManager];
    [self.tableView reloadData];
}

- (void)resumeAll {
    [[BszM3u8DownloadManager sharedManager] resumeAll];
    // 统一从 Manager 刷新状态，遵循单任务并发限制，其他任务保持就绪
    [self reloadItemsFromManager];
    [self.tableView reloadData];
}

- (void)deleteAllTasks {
    // 分页 0：正在下载 -> 停止并删除所有“未完成”的任务
    // 分页 1：已完成 -> 删除所有“已完成”的任务
    if (self.segmentControl.selectedSegmentIndex == 0) {
        [[BszM3u8DownloadManager sharedManager] stopAll];
    } else {
        [[BszM3u8DownloadManager sharedManager] deleteAll];
    }

    // 重新从 Manager 恢复任务列表，保证 UI 与内部状态一致
    [self reloadItemsFromManager];
    [self.tableView reloadData];
}

#pragma mark - Helpers

- (NSArray<BszDemoDownloadItem *> *)currentDataSource {
    if (self.segmentControl.selectedSegmentIndex == 0) {
        // 正在下载：非 Completed
        NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(BszDemoDownloadItem * _Nullable evaluatedObject, NSDictionary<NSString *,id> * _Nullable bindings) {
            return evaluatedObject.status != BszM3u8DownloadStatusCompleted;
        }];
        return [self.items filteredArrayUsingPredicate:predicate];
    } else {
        // 已完成：Completed
        NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(BszDemoDownloadItem * _Nullable evaluatedObject, NSDictionary<NSString *,id> * _Nullable bindings) {
            return evaluatedObject.status == BszM3u8DownloadStatusCompleted;
        }];
        return [self.items filteredArrayUsingPredicate:predicate];
    }
}

- (void)deleteLocalFilesForItem:(BszDemoDownloadItem *)item {
    if (item.outputDir.length == 0) {
        return;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:item.outputDir isDirectory:&isDir] && isDir) {
        NSError *error = nil;
        [fm removeItemAtPath:item.outputDir error:&error];
        if (error) {
            NSLog(@"[m3u8Example] delete local dir failed: %@", error.localizedDescription ?: @"unknown error");
        }
    }
}

// 不再使用统一的多行 TextView，这里保留备用（如需可改为从 4 个 textField 组装数组）

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self currentDataSource].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"multiCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
    }

    NSArray<BszDemoDownloadItem *> *dataSource = [self currentDataSource];
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)dataSource.count) {
        // 由于异步状态变化，可能出现 table 的 indexPath 与当前数据源不一致，防御性返回空 cell，下一次 reload 会修正
        cell.textLabel.text = @"";
        cell.detailTextLabel.text = @"";
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }

    BszDemoDownloadItem *item = dataSource[indexPath.row];
    NSString *shortURL = item.urlString;
    if (shortURL.length > 40) {
        shortURL = [NSString stringWithFormat:@"...%@", [shortURL substringFromIndex:shortURL.length - 40]];
    }

    cell.textLabel.text = [NSString stringWithFormat:@"%@", shortURL];
    cell.textLabel.font = [UIFont systemFontOfSize:13.0];

    NSString *statusText = [self stringForStatus:item.status];
    NSString *speedText = [self prettySpeed:item.speedBytesPerSec];
    NSString *detail = [NSString stringWithFormat:@"进度：%.1f%%  状态：%@%@", item.progress * 100.0f, statusText, speedText];
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12.0];

    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    return cell;
}

#pragma mark - UITableViewDelegate

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleDelete;
}

- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath {
    return @"删除";
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) {
        return;
    }

    NSArray<BszDemoDownloadItem *> *dataSource = [self currentDataSource];
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)dataSource.count) {
        return;
    }
    BszDemoDownloadItem *item = dataSource[indexPath.row];

    // 交给管理器按 taskId 停止并删除对应任务及文件
	[[BszM3u8DownloadManager sharedManager] deleteTaskForTaskId:item.identifier.length ? item.identifier : item.urlString];

    // 从内存数据源中移除
    [self.items removeObjectIdenticalTo:item];

    [self.tableView reloadData];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSArray<BszDemoDownloadItem *> *dataSource = [self currentDataSource];
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)dataSource.count) {
        return;
    }
    BszDemoDownloadItem *item = dataSource[indexPath.row];

    if (self.segmentControl.selectedSegmentIndex == 0) {
        // 正在下载页：点击切换 暂停/继续
        BszM3u8DownloadManager *manager = [BszM3u8DownloadManager sharedManager];
        NSString *taskId = item.identifier.length ? item.identifier : item.urlString;
        if (taskId.length == 0) {
            return;
        }
        if (item.status == BszM3u8DownloadStatusDownloading || item.status == BszM3u8DownloadStatusStarting) {
            [manager pauseTaskForTaskId:taskId];
        } else {
            NSError *error = nil;
            BOOL ok = [manager resumeTaskForTaskId:taskId error:&error];
            if (!ok) {
                NSLog(@"[m3u8Example] resume failed: taskId=%@ error=%@", taskId, error.localizedDescription ?: @"unknown");
            }
        }
        [self reloadItemsFromManager];
        [self.tableView reloadData];
    } else {
        // 已完成页：点击播放
        if (item.outputDir.length == 0) {
            NSLog(@"[m3u8Example] multi play: outputDir is empty");
            return;
        }

        NSError *error = nil;
        BOOL ok = [[BszM3u8LocalServer sharedServer] startWithRootDirectory:item.outputDir error:&error];
        if (!ok) {
            NSLog(@"[m3u8Example] multi play: local server start failed: %@", error.localizedDescription ?: @"unknown error");
            return;
        }

        NSString *baseURL = [BszM3u8LocalServer sharedServer].baseURLString;
        NSString *playURLString = [NSString stringWithFormat:@"%@/index.m3u8", baseURL];
        NSURL *playURL = [NSURL URLWithString:playURLString];
        if (!playURL) {
            NSLog(@"[m3u8Example] multi play: invalid play URL: %@", playURLString);
            return;
        }

        NSLog(@"[m3u8Example] multi local play URL: %@", playURLString);

        AVPlayer *player = [AVPlayer playerWithURL:playURL];
        AVPlayerViewController *playerVC = [[AVPlayerViewController alloc] init];
        playerVC.player = player;
        [self presentViewController:playerVC animated:YES completion:^{
            [player play];
        }];
    }
}

@end
