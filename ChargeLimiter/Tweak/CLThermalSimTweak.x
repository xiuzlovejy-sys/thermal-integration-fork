// CLThermalSim —— 柔性充电执行端（注入 thermalmonitord，Powercuff 式热模拟）。
// 用 Logos %hook（链式挂钩，与 CPUthermal 等其它 thermalmonitord 注入共存）。
// 档位经内核 notify state 传输：0=off/1=nominal/2=light/3=moderate/4=heavy。
// 消费 com.jy.charge.thermalapply，下发 putDeviceInThermalSimulationMode:。

#import <Foundation/Foundation.h>
#import <notify.h>

// thermalmonitord 内部类（CPUthermal class-dump 证实 iOS 15-17 存在）。
@interface CommonProduct : NSObject
- (id)initProduct:(id)arg1;
- (void)putDeviceInThermalSimulationMode:(id)arg1;
@end

static CommonProduct *gProduct = nil;
static int gApplyToken = -1;
static NSString *gLastMode = nil;

static NSString *CLModeString(uint64_t mode) {
    switch (mode) {
        case 1: return @"nominal";
        case 2: return @"light";
        case 3: return @"moderate";
        case 4: return @"heavy";
        default: return @"off";
    }
}

static void CLApplyThermals(void) {
    if (gProduct == nil) return;
    uint64_t mode = 0;
    if (gApplyToken >= 0) notify_get_state(gApplyToken, &mode);
    NSString *s = CLModeString(mode);
    if (gLastMode != nil && [gLastMode isEqualToString:s]) return;
    gLastMode = s;
    NSLog(@"[CLThermalSim] apply mode=%@", s);
    [gProduct putDeviceInThermalSimulationMode:s];
}

%hook CommonProduct
- (id)initProduct:(id)arg1 {
    id res = %orig;
    if (res != nil) {
        gProduct = (CommonProduct *)res;
        NSLog(@"[CLThermalSim] product captured");
        CLApplyThermals();
    }
    return res;
}
%end

%ctor {
    uint32_t token = 0;
    if (notify_register_dispatch("com.jy.charge.thermalapply", &token,
                                 dispatch_get_main_queue(), ^(int t) { CLApplyThermals(); }) == NOTIFY_STATUS_OK) {
        gApplyToken = (int)token;
    }
    NSLog(@"[CLThermalSim] ctor loaded");
}
