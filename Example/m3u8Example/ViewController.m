#import "ViewController.h"
#import <BszM3u8Downloader/BszM3u8Downloader.h>
#import <BszM3u8Downloader/BszM3u8LocalServer.h>

#import <AVKit/AVKit.h>

@interface ViewController () <BszM3u8DownloadManagerDelegate>
@property (nonatomic, strong) UITextField *urlField;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIScrollView *statusScrollView;
@property (nonatomic, strong) UIButton *startButton;
@property (nonatomic, strong) UIButton *pauseButton;
@property (nonatomic, strong) UIButton *resumeButton;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UIButton *deleteButton;

@property (nonatomic, copy) NSString *taskId;
@property (nonatomic, copy) NSString *taskURL;
@property (nonatomic, copy) NSString *outputDir;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    [self setupUI];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [BszM3u8DownloadManager sharedManager].delegate = self;
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    BszM3u8DownloadManager *manager = [BszM3u8DownloadManager sharedManager];
    if (manager.delegate == self) {
        manager.delegate = nil;
    }
}

- (void)setupUI {
    CGFloat margin = 20.0;
    CGFloat width = self.view.bounds.size.width - margin * 2.0;
    CGFloat y = 100.0;

    self.urlField = [[UITextField alloc] initWithFrame:CGRectMake(margin, y, width, 40.0)];
    self.urlField.borderStyle = UITextBorderStyleRoundedRect;
    self.urlField.placeholder = @"输入单个 m3u8 URL";
    self.urlField.text = @"";
    [self.view addSubview:self.urlField];
    y += 50.0;

    self.startButton = [self buttonWithTitle:@"开始" action:@selector(startDownload) frame:CGRectMake(margin, y, 70.0, 36.0)];
    [self.view addSubview:self.startButton];

    self.pauseButton = [self buttonWithTitle:@"暂停" action:@selector(pauseDownload) frame:CGRectMake(margin + 80.0, y, 70.0, 36.0)];
    [self.view addSubview:self.pauseButton];

    self.resumeButton = [self buttonWithTitle:@"继续" action:@selector(resumeDownload) frame:CGRectMake(margin + 160.0, y, 70.0, 36.0)];
    [self.view addSubview:self.resumeButton];

    self.playButton = [self buttonWithTitle:@"本地播放" action:@selector(playLocal) frame:CGRectMake(margin + 240.0, y, 80.0, 36.0)];
    self.playButton.titleLabel.font = [UIFont systemFontOfSize:14.0];
    [self.view addSubview:self.playButton];

    self.deleteButton = [self buttonWithTitle:@"删除" action:@selector(deleteLocal) frame:CGRectMake(margin + 330.0, y, 60.0, 36.0)];
    self.deleteButton.titleLabel.font = [UIFont systemFontOfSize:14.0];
    [self.view addSubview:self.deleteButton];

    y += 50.0;

    // 单任务状态使用一个可滚动区域，避免与多任务区域重叠
    CGFloat statusHeight = 120.0;
    self.statusScrollView = [[UIScrollView alloc] initWithFrame:CGRectMake(margin, y, width, statusHeight)];
    self.statusScrollView.showsVerticalScrollIndicator = YES;
    self.statusScrollView.alwaysBounceVertical = YES;

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, width, statusHeight)];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.lineBreakMode = NSLineBreakByCharWrapping;
    self.statusLabel.font = [UIFont systemFontOfSize:14.0];
    self.statusLabel.textColor = [UIColor darkGrayColor];
    self.statusLabel.text = @"单任务：等待开始下载";

    [self.statusScrollView addSubview:self.statusLabel];
    self.statusScrollView.contentSize = CGSizeMake(width, statusHeight);
    [self.view addSubview:self.statusScrollView];

}

- (UIButton *)buttonWithTitle:(NSString *)title action:(SEL)action frame:(CGRect)frame {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = frame;
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

#pragma mark - Actions

- (void)startDownload {
    NSString *urlString = self.urlField.text;
    if (urlString.length == 0) {
        self.statusLabel.text = @"单任务：请输入 m3u8 URL";
        return;
    }

    urlString = [urlString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    self.taskURL = urlString;
    self.taskId = urlString; // demo 默认 taskId=URL

    NSError *error = nil;
    BOOL ok = [[BszM3u8DownloadManager sharedManager] createAndStartTaskWithTaskId:self.taskId
                                                                         urlString:urlString
                                                                               ext:nil
                                                                             error:&error];
    if (!ok) {
        self.statusLabel.text = [NSString stringWithFormat:@"单任务：开始下载失败：%@", error.localizedDescription ?: @"未知错误"];
        [self updateStatusScrollContentSize];
        return;
    }
    self.statusLabel.text = @"单任务：开始下载...";
    [self updateStatusScrollContentSize];
}

- (void)pauseDownload {
    if (self.taskId.length == 0) {
        self.statusLabel.text = @"单任务：请先开始一次下载";
        [self updateStatusScrollContentSize];
        return;
    }
    [[BszM3u8DownloadManager sharedManager] pauseTaskForTaskId:self.taskId];
    self.statusLabel.text = @"单任务：已暂停";
    [self updateStatusScrollContentSize];
}

- (void)resumeDownload {
    if (self.taskId.length == 0 || self.taskURL.length == 0) {
        self.statusLabel.text = @"单任务：请先开始一次下载";
        [self updateStatusScrollContentSize];
        return;
    }
    NSError *error = nil;
    BOOL ok = [[BszM3u8DownloadManager sharedManager] resumeTaskForTaskId:self.taskId error:&error];
    if (!ok) {
        self.statusLabel.text = [NSString stringWithFormat:@"单任务：继续下载失败：%@", error.localizedDescription ?: @"未知错误"];
        [self updateStatusScrollContentSize];
        return;
    }
    self.statusLabel.text = @"单任务：继续下载...";
    [self updateStatusScrollContentSize];
}

- (void)playLocal {
    NSError *error = nil;
    NSString *playURLString = [[BszM3u8LocalServer sharedServer] playURLForTaskId:self.taskId error:&error];
    NSURL *playURL = playURLString.length ? [NSURL URLWithString:playURLString] : nil;
    if (!playURL) {
        self.statusLabel.text = [NSString stringWithFormat:@"单任务：获取本地播放 URL 失败：%@", error.localizedDescription ?: @"未知错误"];
        return;
    }

    self.statusLabel.text = [NSString stringWithFormat:@"单任务：使用 AVPlayer 播放：%@", playURLString];
    NSLog(@"[m3u8Example] single local play URL: %@", playURLString);

    AVPlayer *player = [AVPlayer playerWithURL:playURL];
    AVPlayerViewController *playerVC = [[AVPlayerViewController alloc] init];
    playerVC.player = player;
    [self presentViewController:playerVC animated:YES completion:^{
        [player play];
    }];
}

- (void)deleteLocal {
    if (self.taskId.length > 0) {
        [[BszM3u8DownloadManager sharedManager] deleteTaskForTaskId:self.taskId];
    }
    self.outputDir = nil;
    self.statusLabel.text = @"单任务：任务已删除";
    [self updateStatusScrollContentSize];
}

#pragma mark - BszM3u8DownloadManagerDelegate

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

- (NSString *)prettySpeed:(double)bytesPerSecond {
    if (bytesPerSecond <= 0) {
        return @"";
    }
    double v = bytesPerSecond;
    NSString *unit = @"B/s";
    if (v >= 1024.0) { v /= 1024.0; unit = @"KB/s"; }
    if (v >= 1024.0) { v /= 1024.0; unit = @"MB/s"; }
    if (v >= 1024.0) { v /= 1024.0; unit = @"GB/s"; }
    return (v >= 100.0) ? [NSString stringWithFormat:@"%.0f %@", v, unit]
                       : [NSString stringWithFormat:@"%.1f %@", v, unit];
}

- (void)downloadManager:(BszM3u8DownloadManager *)manager
      didUpdateTaskInfo:(BszM3u8DownloadTaskInfo *)taskInfo
                  error:(NSError *)error {
    if (taskInfo.taskId.length == 0 || ![taskInfo.taskId isEqualToString:self.taskId]) {
        return;
    }
    self.outputDir = taskInfo.outputDir;

    NSString *speed = [self prettySpeed:taskInfo.speedBytesPerSecond];
    NSString *base = [NSString stringWithFormat:@"单任务：%@  %.2f%%  %@",
                      [self stringForStatus:taskInfo.status],
                      taskInfo.progress * 100.0,
                      speed];
    if (error) {
        self.statusLabel.text = [NSString stringWithFormat:@"%@\n错误：%@", base, error.localizedDescription ?: @"unknown"];
    } else {
        self.statusLabel.text = base;
    }
    [self updateStatusScrollContentSize];
}

- (void)updateStatusScrollContentSize {
    if (!self.statusLabel || !self.statusScrollView) {
        return;
    }
    CGFloat width = self.statusScrollView.bounds.size.width;
    CGSize maxSize = CGSizeMake(width, CGFLOAT_MAX);
    CGSize size = [self.statusLabel sizeThatFits:maxSize];
    self.statusLabel.frame = CGRectMake(0, 0, width, size.height);
    self.statusScrollView.contentSize = CGSizeMake(width, size.height);
}

@end
