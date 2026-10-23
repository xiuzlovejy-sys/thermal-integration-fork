#import "CLPowercuffCore.h"
#import <objc/message.h>
#include <notify.h>
#include <string.h>
#include <stdlib.h>

static id CLPCProduct;
static CLPCState CLPCMetrics;
static int CLPCStatusToken = -1;
static int CLPCRequestToken = -1;
static BOOL CLPCStarted = NO;

static BOOL CLPCTypeMatches(const char *type, char expected) {
    if (type == NULL) return NO;
    while (*type && strchr("rnNoORV", *type)) type++;
    if (*type != expected) return NO;
    if (expected == '@' && type[1] == '"') {
        const char *end = strchr(type + 2, '"');
        return end != NULL && end > type + 2 && end[1] == '\0';
    }
    return type[1] == '\0';
}

BOOL CLPCMethodMatches(Method method, char returnType) {
    if (method == NULL || method_getNumberOfArguments(method) != 3) return NO;
    char *type = method_copyReturnType(method);
    BOOL valid = CLPCTypeMatches(type, returnType);
    free(type);
    const char expected[] = {'@', ':', '@'};
    for (unsigned int index = 0; valid && index < 3; index++) {
        type = method_copyArgumentType(method, index);
        valid = CLPCTypeMatches(type, expected[index]);
        free(type);
    }
    return valid;
}

static void CLPCPublish(void) {
    if (CLPCStatusToken < 0) return;
    uint64_t flags = (CLPCMetrics.hookInstalled ? 1 : 0)
        | (CLPCMetrics.productCaptured ? 2 : 0)
        | (CLPCMetrics.observerOnly ? 4 : 0)
        | (CLPCMetrics.signatureRejected ? 8 : 0);
    uint64_t state = flags | ((uint64_t)CLPCMetrics.result << 4)
        | ((uint64_t)CLPCMetrics.lastMode << 8)
        | ((CLPCMetrics.requests & 0xffff) << 16)
        | ((CLPCMetrics.returnedCalls & 0xffff) << 32)
        | ((CLPCMetrics.captures & 0xffff) << 48);
    if (notify_set_state(CLPCStatusToken, state) == NOTIFY_STATUS_OK) {
        notify_post(CLPC_STATUS_NOTIFICATION);
    }
}

void CLPCSetHookState(BOOL installed, BOOL valid) {
    dispatch_async(dispatch_get_main_queue(), ^{
        CLPCMetrics.hookInstalled = installed;
        CLPCMetrics.signatureRejected = !valid;
        CLPCPublish();
    });
}

void CLPCCaptureProduct(id product) {
    if (product == nil) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL valid = CLPCMethodMatches(class_getInstanceMethod(object_getClass(product),
            sel_registerName("putDeviceInThermalSimulationMode:")), 'v');
        CLPCProduct = valid ? product : nil;
        CLPCMetrics.captures++;
        CLPCMetrics.productCaptured = valid;
        CLPCMetrics.signatureRejected = !valid;
        CLPCMetrics.ownsSimulation = NO;
        CLPCPublish();
    });
}

void CLPCRequestMode(uint64_t mode) {
    dispatch_async(dispatch_get_main_queue(), ^{
        CLPCMetrics.requests++;
        CLPCMetrics.lastMode = mode <= 4 ? (uint8_t)mode : UINT8_MAX;
        if (mode > 4) {
            CLPCMetrics.result = CLPCResultInvalidMode;
            CLPCMetrics.rejectedRequests++;
        } else if (CLPCProduct == nil) {
            CLPCMetrics.result = CLPCResultNoProduct;
            CLPCMetrics.rejectedRequests++;
        } else {
#if CLPC_ENABLE_APPLY && CLPC_TESTING
            if (mode == 0 && !CLPCMetrics.ownsSimulation) {
                CLPCMetrics.result = CLPCResultNoChange;
            } else {
                NSArray *names = @[@"off", @"nominal", @"light", @"moderate", @"heavy"];
                @try {
                    ((void (*)(id, SEL, id))objc_msgSend)(CLPCProduct,
                        sel_registerName("putDeviceInThermalSimulationMode:"), names[(NSUInteger)mode]);
                    CLPCMetrics.returnedCalls++;
                    CLPCMetrics.ownsSimulation = mode != 0;
                    CLPCMetrics.result = CLPCResultCallReturned;
                } @catch (NSException *exception) {
                    CLPCMetrics.result = CLPCResultException;
                }
            }
#else
            CLPCMetrics.result = CLPCResultObserver;
#endif
        }
        CLPCPublish();
    });
}

void CLPCStartObserver(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (CLPCStarted) return;
        CLPCStarted = YES;
        CLPCMetrics.observerOnly = !CLPC_ENABLE_APPLY;
        notify_register_check(CLPC_STATUS_NOTIFICATION, &CLPCStatusToken);
        notify_register_dispatch(CLPC_REQUEST_NOTIFICATION, &CLPCRequestToken,
            dispatch_get_main_queue(), ^(int token) {
                uint64_t mode = UINT64_MAX;
                if (notify_get_state(token, &mode) == NOTIFY_STATUS_OK) CLPCRequestMode(mode);
            });
        CLPCPublish();
    });
}

CLPCState CLPCReadState(void) {
    if ([NSThread isMainThread]) return CLPCMetrics;
    __block CLPCState state;
    dispatch_sync(dispatch_get_main_queue(), ^{ state = CLPCMetrics; });
    return state;
}

#if CLPC_TESTING
void CLPCReleaseProductForTests(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        CLPCProduct = nil;
        CLPCMetrics.productCaptured = NO;
        CLPCMetrics.ownsSimulation = NO;
        CLPCPublish();
    });
}
#endif
