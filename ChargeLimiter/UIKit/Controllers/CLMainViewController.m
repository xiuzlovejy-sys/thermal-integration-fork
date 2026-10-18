//
//  CLMainViewController.m
//  ChargeLimiter
//
//  主入口控制器 - 包装新的设置界面到导航控制器
//

#import "CLMainViewController.h"
#import "../CLButlerViewController.h"

@interface CLMainViewController ()
@property (nonatomic, strong) UINavigationController *navController;
@end

@implementation CLMainViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    // 主界面 = Jy's charge 温控一屏（简约）；「更多设置」推入原设置界面，
    // 上游能力（限流/停充/热模拟/诊断）全部保留，不牺牲功能。
    CLButlerViewController *butlerVC = [[CLButlerViewController alloc] init];
    self.navController = [[UINavigationController alloc] initWithRootViewController:butlerVC];
    self.navController.navigationBarHidden = YES;
    
    // 添加为子控制器
    [self addChildViewController:self.navController];
    self.navController.view.frame = self.view.bounds;
    self.navController.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.navController.view];
    [self.navController didMoveToParentViewController:self];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    if (@available(iOS 13.0, *)) {
        return UIStatusBarStyleDefault;
    }
    return UIStatusBarStyleDefault;
}

- (BOOL)prefersStatusBarHidden {
    return NO;
}

@end
