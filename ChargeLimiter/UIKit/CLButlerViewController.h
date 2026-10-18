//
//  CLButlerViewController.h
//  Jy's charge
//
//  主界面：温控充电的状态与设置（一屏、无装饰）。
//  数据来自 daemon HTTP API（get_bat_info / get_conf），
//  设置写回同一套配置键（set_conf），daemon 每轮电池事件即时生效。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CLButlerViewController : UIViewController

@end

NS_ASSUME_NONNULL_END
