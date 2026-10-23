#import "../PowercuffProbe/CLPowercuffCore.h"
#import <objc/message.h>
#include <notify.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <dlfcn.h>

#ifndef CLPC_REAL_HOOK
#define CLPC_REAL_HOOK 0
#endif

#if CLPC_REAL_HOOK
static void *HookLibrary;
static void (*HookMessage)(Class, SEL, IMP, IMP *);
static unsigned int HookInstallCalls;
#endif

static NSUInteger OriginalCalls;
static NSUInteger BaseDeallocations;
static NSUInteger ReplacementDeallocations;
static NSUInteger ThermalCalls;
static BOOL CallerInInit;
static BOOL ReenteredInit;
static SEL LastCommand;
static id LastData;
static NSString *LastMode;
static id Owner;
static __weak id WeakOwner;
static unsigned int Assertions;
static Class BaseClass;
static Class CommonClass;
static Class ReplacementClass;

static void Check(BOOL condition, const char *name) {
    Assertions++;
    if (!condition) {
        fprintf(stderr, "FAIL %s\n", name);
        exit(1);
    }
}

static void OnMain(dispatch_block_t block) {
    dispatch_sync(dispatch_get_main_queue(), ^{
        @autoreleasepool { block(); }
    });
}

static void RecordMode(NSString *mode) {
    ThermalCalls++;
    LastMode = mode;
    ReenteredInit |= CallerInInit;
}

@interface NSObject (CLPCNativeMessages)
- (id)initProduct:(id)data;
@end

static id TestInitializer(__attribute__((ns_consumed)) id object, SEL command, id data)
    __attribute__((ns_returns_retained));

static id TestInitializer(__attribute__((ns_consumed)) id object, SEL command, id data) {
    object = [object init];
    OriginalCalls++;
    LastCommand = command;
    LastData = data;
    if ([data isEqual:@"nil"]) return nil;
    if ([data isEqual:@"replacement"]) return [[(id)ReplacementClass alloc] init];
    if ([data isEqual:@"unsupported"]) return (id)[[NSObject alloc] init];
    return object;
}

static void TestApply(id object, SEL command, id mode) { RecordMode(mode); }

static void TestBaseDealloc(__unsafe_unretained id object, SEL command) {
    BaseDeallocations++;
    struct objc_super parent = {object, [NSObject class]};
    ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&parent, command);
}

static void TestReplacementDealloc(__unsafe_unretained id object, SEL command) {
    ReplacementDeallocations++;
    struct objc_super parent = {object, [NSObject class]};
    ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&parent, command);
}

static void CreateClasses(void) {
    SEL apply = sel_registerName("putDeviceInThermalSimulationMode:");
    BaseClass = objc_allocateClassPair([NSObject class], "CLPCBase", 0);
    class_addMethod(BaseClass, sel_registerName("initProduct:"), (IMP)TestInitializer, "@@:@");
    class_addMethod(BaseClass, apply, (IMP)TestApply, "v@:@");
    class_addMethod(BaseClass, sel_registerName("dealloc"), (IMP)TestBaseDealloc, "v@:");
    objc_registerClassPair(BaseClass);
    ReplacementClass = objc_allocateClassPair([NSObject class], "CLPCReplacement", 0);
    class_addMethod(ReplacementClass, apply, (IMP)TestApply, "v@:@");
    class_addMethod(ReplacementClass, sel_registerName("dealloc"), (IMP)TestReplacementDealloc, "v@:");
    objc_registerClassPair(ReplacementClass);
    CommonClass = objc_allocateClassPair(BaseClass, "CommonProduct", 0);
    objc_registerClassPair(CommonClass);
}

extern "C" void MSHookMessageEx(Class target, SEL selector, IMP replacement, IMP *original) {
#if CLPC_REAL_HOOK
    Check(HookMessage != NULL, "real hook function resolved before installation");
    HookInstallCalls++;
    HookMessage(target, selector, replacement, original);
#else
    Method method = class_getInstanceMethod(target, selector);
    *original = method_getImplementation(method);
    class_replaceMethod(target, selector, replacement, method_getTypeEncoding(method));
#endif
}

#if CLPC_REAL_HOOK
static void LoadRealHook(const char *path) {
    HookLibrary = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (HookLibrary == NULL) fprintf(stderr, "Framework load failed: %s\n", dlerror());
    Check(HookLibrary != NULL, "real hook framework loads");
    HookMessage = (void (*)(Class, SEL, IMP, IMP *))dlsym(HookLibrary, "MSHookMessageEx");
    Check(HookMessage != NULL && HookMessage != &MSHookMessageEx,
        "framework hook resolves without falling back to test bridge");
    Dl_info location = {};
    Check(dladdr((const void *)HookMessage, &location) != 0 && location.dli_fname != NULL,
        "resolved hook has library provenance");
    printf("Real hook provider: %s\n", location.dli_fname);
}
#endif

static id DummyMethod(id object, SEL selector, id value) { return value; }

static Method SignatureMethod(const char *className, const char *encoding) {
    Class target = objc_allocateClassPair([NSObject class], className, 0);
    class_addMethod(target, sel_registerName("probe:"), (IMP)DummyMethod, encoding);
    objc_registerClassPair(target);
    return class_getInstanceMethod(target, sel_registerName("probe:"));
}

static void WaitForRequests(uint64_t requests) {
    for (unsigned int index = 0; index < 200; index++) {
        if (CLPCReadState().requests >= requests) return;
        usleep(10000);
    }
    Check(NO, "notification delivery deadline");
}

static void Request(uint64_t mode) {
    uint64_t before = CLPCReadState().requests;
    CLPCRequestMode(mode);
    WaitForRequests(before + 1);
}

static void Tests(void) {
    Check(!CLPCMethodMatches(NULL, '@'), "missing method rejected");
    Method qualified = SignatureMethod("CLPCQualified", "r@24@0:8r@16");
    Check(CLPCMethodMatches(qualified, '@'), "qualified object signature accepted");
    Check(!CLPCMethodMatches(SignatureMethod("CLPCBlockArg", "@@:@?"), '@'), "block argument rejected");
    Check(!CLPCMethodMatches(SignatureMethod("CLPCBlockReturn", "@?@:@"), '@'), "block return rejected");
    Check(!CLPCMethodMatches(SignatureMethod("CLPCScalar", "@@:q"), '@'), "scalar argument rejected");
    Check(!CLPCMethodMatches(SignatureMethod("CLPCWrongReturn", "v@:@"), '@'), "wrong return rejected");
    Check(!CLPCMethodMatches(SignatureMethod("CLPCExtraArg", "@@:@@"), '@'), "extra argument rejected");

    OnMain(^{
        Check(!CLPCInstallClass([NSObject class]), "missing initializer cannot be hooked");
        IMP parent = class_getMethodImplementation(BaseClass, @selector(initProduct:));
        Check(CLPCInstallClass(CommonClass), "inherited initializer hooked");
        Check(class_getMethodImplementation(BaseClass, @selector(initProduct:)) == parent,
            "parent method unchanged");
        IMP installed = class_getMethodImplementation(CommonClass, @selector(initProduct:));
        Check(CLPCInstallClass(CommonClass), "repeat install accepted");
        Check(class_getMethodImplementation(CommonClass, @selector(initProduct:)) == installed,
            "repeat install does not replace hook again");
#if CLPC_REAL_HOOK
        Check(HookInstallCalls == 1, "real framework installs exactly once");
#endif
    });
    OnMain(^{});
    Check(CLPCReadState().requests == 0, "startup does not replay mode");
    Request(2);
    Check(CLPCReadState().result == CLPCResultNoProduct, "request before capture rejected");

    OnMain(^{
        CallerInInit = YES;
        Owner = [[(id)CommonClass alloc] initProduct:@"self"];
        CallerInInit = NO;
        WeakOwner = Owner;
        Check(OriginalCalls == 1 && LastCommand == @selector(initProduct:) && [LastData isEqual:@"self"],
            "original initializer receives command and data once");
    });
    OnMain(^{});
    Check(CLPCReadState().productCaptured, "product capture completes asynchronously");
    Check(ThermalCalls == 0 && !ReenteredInit, "capture never calls thermal method");

    int token = -1;
    Check(notify_register_check(CLPC_REQUEST_NOTIFICATION, &token) == 0, "writer channel registration");
    uint64_t requests = CLPCReadState().requests;
    Check(notify_set_state(token, 3) == 0, "mode state write");
    Check(notify_post(CLPC_REQUEST_NOTIFICATION) == 0, "mode notification post");
    WaitForRequests(requests + 1);
    notify_cancel(token);
#if CLPC_ENABLE_APPLY
    Check([LastMode isEqual:@"moderate"] && CLPCReadState().returnedCalls == 1,
        "fake receiver observes moderate method call");
    Request(0);
    Check([LastMode isEqual:@"off"], "off is distinct and releases owned simulation");
    uint64_t calls = CLPCReadState().returnedCalls;
    Request(0);
    Check(CLPCReadState().returnedCalls == calls, "unowned off does not call receiver");
    Request(1);
    Check([LastMode isEqual:@"nominal"], "nominal remains distinct");
    Request(2);
    Check([LastMode isEqual:@"light"], "light mapping");
    Request(4);
    Check([LastMode isEqual:@"heavy"], "heavy mapping");
#else
    Check(CLPCReadState().result == CLPCResultObserver && ThermalCalls == 0,
        "observer receives notification without actuation");
    for (uint64_t mode = 0; mode <= 4; mode++) Request(mode);
    Check(CLPCReadState().returnedCalls == 0 && ThermalCalls == 0, "all observer modes remain non-actuating");
#endif
    uint64_t callsBeforeInvalid = CLPCReadState().returnedCalls;
    Request(9);
    Check(CLPCReadState().result == CLPCResultInvalidMode &&
        CLPCReadState().returnedCalls == callsBeforeInvalid, "invalid mode never calls receiver");
    OnMain(^{ Owner = nil; });
    OnMain(^{ Check(WeakOwner != nil, "captured object survives caller release"); });
    CLPCReleaseProductForTests();
    OnMain(^{});
    OnMain(^{ Check(WeakOwner == nil && BaseDeallocations == 1, "capture release destroys object exactly once"); });

    uint64_t capturesBeforeNil = CLPCReadState().captures;
    OnMain(^{ Owner = [[(id)CommonClass alloc] initProduct:@"nil"]; });
    OnMain(^{});
    Check(Owner == nil && CLPCReadState().captures == capturesBeforeNil, "nil initializer is not captured");
    Check(BaseDeallocations == 2, "nil initializer consumed self exactly once");
    OnMain(^{
        Owner = [[(id)CommonClass alloc] initProduct:@"replacement"];
        WeakOwner = Owner;
        Check([Owner isKindOfClass:ReplacementClass], "initializer replacement identity preserved");
    });
    OnMain(^{});
    Check(BaseDeallocations == 3 && CLPCReadState().productCaptured,
        "replacement disposes old self and captures returned object");
    OnMain(^{ Owner = nil; });
    CLPCReleaseProductForTests();
    OnMain(^{});
    OnMain(^{ Check(WeakOwner == nil && ReplacementDeallocations == 1, "replacement ownership balanced"); });
    OnMain(^{
        Owner = [[(id)CommonClass alloc] initProduct:@"unsupported"];
        WeakOwner = Owner;
    });
    OnMain(^{});
    Check(!CLPCReadState().productCaptured && CLPCReadState().signatureRejected,
        "returned object without private method is rejected");
    Request(3);
    Check(CLPCReadState().result == CLPCResultNoProduct, "unsupported returned object cannot be called");
    OnMain(^{
        Owner = nil;
        Check(WeakOwner == nil && BaseDeallocations == 4, "unsupported result is not retained after rejection");
    });
    Check(!ReenteredInit, "no thermal call reenters initializer caller");
    printf("PASS %u native Powercuff probe assertions (test_apply=%d, hook=%s)\n",
        Assertions, CLPC_ENABLE_APPLY, CLPC_REAL_HOOK ? "real" : "stub");
    exit(0);
}

int main(int argc, const char *argv[]) {
    alarm(30);
#if CLPC_REAL_HOOK
    if (argc != 2) {
        fprintf(stderr, "Usage: %s /absolute/path/to/hook-framework\n", argv[0]);
        return 2;
    }
    LoadRealHook(argv[1]);
#endif
    CreateClasses();
    CLPCStartObserver();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool { Tests(); }
    });
    dispatch_main();
}
