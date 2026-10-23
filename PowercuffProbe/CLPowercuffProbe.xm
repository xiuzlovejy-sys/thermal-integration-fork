#import "CLPowercuffCore.h"
#include <notify.h>

static BOOL CLPCInstalled;
static Class CLPCTarget;

%group CLPCapture
%hook CommonProduct
- (id)initProduct:(id)data {
    id result = %orig(data);
    CLPCCaptureProduct(result);
    return result;
}
%end
%end

BOOL CLPCInstallClass(Class productClass) {
    if (CLPCInstalled) return productClass == CLPCTarget;
    BOOL valid = productClass != Nil &&
        CLPCMethodMatches(class_getInstanceMethod(productClass, sel_registerName("initProduct:")), '@') &&
        CLPCMethodMatches(class_getInstanceMethod(productClass,
            sel_registerName("putDeviceInThermalSimulationMode:")), 'v');
    if (!valid) {
        CLPCSetHookState(NO, NO);
        return NO;
    }
    Method method = class_getInstanceMethod(productClass, sel_registerName("initProduct:"));
    IMP before = method_getImplementation(method);
    %init(CLPCapture, CommonProduct = productClass);
    CLPCInstalled = method_getImplementation(class_getInstanceMethod(productClass,
        sel_registerName("initProduct:"))) != before;
    if (CLPCInstalled) CLPCTarget = productClass;
    CLPCSetHookState(CLPCInstalled, YES);
    return CLPCInstalled;
}

#if !CLPC_TESTING
static dispatch_source_t CLPCBindTimer;

%ctor {
    CLPCStartObserver();
    if (!CLPCInstallClass(objc_getClass("CommonProduct"))) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __block unsigned int attempts = 0;
            CLPCBindTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                dispatch_get_main_queue());
            dispatch_source_set_timer(CLPCBindTimer, DISPATCH_TIME_NOW,
                250 * NSEC_PER_MSEC, 25 * NSEC_PER_MSEC);
            dispatch_source_set_event_handler(CLPCBindTimer, ^{
                attempts++;
                Class target = objc_getClass("CommonProduct");
                if ((target != Nil && CLPCInstallClass(target)) || attempts >= 120) {
                    dispatch_source_cancel(CLPCBindTimer);
                    CLPCBindTimer = nil;
                }
            });
            dispatch_resume(CLPCBindTimer);
        });
    }
}
#endif
