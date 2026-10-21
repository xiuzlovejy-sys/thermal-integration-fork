#import <Foundation/Foundation.h>

// 读取 Jy's charge daemon 的外部 ETA（daemon 显式乘了软 PWM 占空比）。
// Jikan 本地估算用瞬时电流，在软 PWM 下会看到 0↔3A 方波，严重失真。
@interface TT100ExternalEstimate : NSObject

// 非阻塞：最短 2 秒一次请求；结果缓存在内存。
+ (void)refreshIfNeeded;

// 最近一次有效结果；超过 90 秒返回 nil（回退到 Jikan 自己的估算）。
// 键：eta_min(NSNumber) / eta_state(NSString) / duty(NSNumber)
+ (NSDictionary *)cachedEstimate;

@end
