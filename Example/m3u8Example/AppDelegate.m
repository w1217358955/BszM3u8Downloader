//
//  AppDelegate.m
//  m3u8Example
//
//  Created by bing on 2026/1/26.
//

#import "AppDelegate.h"
#import "ViewController.h"
#import "MultiTaskViewController.h"
#import "BszFileBrowserViewController.h"

@interface AppDelegate ()

@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    ViewController *singleVC = [[ViewController alloc] init];
    singleVC.title = @"单任务";

    UITabBarItem *singleItem;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (@available(iOS 13.0, *)) {
        UIImage *singleImage = [UIImage systemImageNamed:@"square.and.arrow.down"];
        singleItem = [[UITabBarItem alloc] initWithTitle:@"单任务" image:singleImage selectedImage:singleImage];
    } else {
        singleItem = [[UITabBarItem alloc] initWithTabBarSystemItem:UITabBarSystemItemDownloads tag:0];
        singleItem.title = @"单任务";
    }
#else
    singleItem = [[UITabBarItem alloc] initWithTabBarSystemItem:UITabBarSystemItemDownloads tag:0];
    singleItem.title = @"单任务";
#endif
    singleVC.tabBarItem = singleItem;

    MultiTaskViewController *multiVC = [[MultiTaskViewController alloc] init];
    multiVC.title = @"多任务";

    UITabBarItem *multiItem;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (@available(iOS 13.0, *)) {
        UIImage *multiImage = [UIImage systemImageNamed:@"tray.full"];
        multiItem = [[UITabBarItem alloc] initWithTitle:@"多任务" image:multiImage selectedImage:multiImage];
    } else {
        multiItem = [[UITabBarItem alloc] initWithTabBarSystemItem:UITabBarSystemItemMostRecent tag:1];
        multiItem.title = @"多任务";
    }
#else
    multiItem = [[UITabBarItem alloc] initWithTabBarSystemItem:UITabBarSystemItemMostRecent tag:1];
    multiItem.title = @"多任务";
#endif
    multiVC.tabBarItem = multiItem;

    BszFileBrowserViewController *filesVC = [[BszFileBrowserViewController alloc] initWithPath:nil];
    filesVC.title = @"文件";

    UITabBarItem *filesItem;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (@available(iOS 13.0, *)) {
        UIImage *filesImage = [UIImage systemImageNamed:@"folder"];
        filesItem = [[UITabBarItem alloc] initWithTitle:@"文件" image:filesImage selectedImage:filesImage];
    } else {
        filesItem = [[UITabBarItem alloc] initWithTabBarSystemItem:UITabBarSystemItemMore tag:2];
        filesItem.title = @"文件";
    }
#else
    filesItem = [[UITabBarItem alloc] initWithTabBarSystemItem:UITabBarSystemItemMore tag:2];
    filesItem.title = @"文件";
#endif
    filesVC.tabBarItem = filesItem;
    UINavigationController *filesNav = [[UINavigationController alloc] initWithRootViewController:filesVC];

    UITabBarController *tabBar = [[UITabBarController alloc] init];
    tabBar.viewControllers = @[singleVC, multiVC, filesNav];

    self.window.rootViewController = tabBar;
    [self.window makeKeyAndVisible];
    return YES;
}

@end
