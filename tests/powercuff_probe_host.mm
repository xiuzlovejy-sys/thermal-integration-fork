#import "../PowercuffProbe/CLPowercuffCore.h"
#include <dlfcn.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern char **environ;

static CLPCState (*ReadState)(void);
static Class ProductClass;
static id Owner;
static NSUInteger Initializers;
static NSUInteger ThermalCalls;
static unsigned int Assertions;
static void *Framework;
static void *Observer;

static void Check(BOOL valid, const char *name) {
    Assertions++;
    if (!valid) {
        fprintf(stderr, "FAIL %s\n", name);
        exit(1);
    }
}

@interface NSObject (CLPCHostMessages)
- (id)initProduct:(id)data;
@end

static id Initializer(__attribute__((ns_consumed)) id object, SEL selector, id data)
    __attribute__((ns_returns_retained));

static id Initializer(__attribute__((ns_consumed)) id object, SEL selector, id data) {
    Initializers++;
    return [object init];
}

static void Apply(id object, SEL selector, id mode) {
    ThermalCalls++;
}

static void CreateClass(void) {
    ProductClass = objc_allocateClassPair([NSObject class], "CommonProduct", 0);
    Check(ProductClass != Nil, "host creates its own fake class");
    Check(class_addMethod(ProductClass, sel_registerName("initProduct:"), (IMP)Initializer, "@@:@"),
        "host adds fake initializer");
    Check(class_addMethod(ProductClass, sel_registerName("putDeviceInThermalSimulationMode:"),
        (IMP)Apply, "v@:@"), "host adds counting-only fake thermal method");
    objc_registerClassPair(ProductClass);
}

static void OnMain(dispatch_block_t block) {
    dispatch_sync(dispatch_get_main_queue(), ^{
        @autoreleasepool { block(); }
    });
}

static BOOL WaitFor(BOOL (^condition)(CLPCState), NSTimeInterval timeout) {
    NSTimeInterval deadline = [NSProcessInfo processInfo].systemUptime + timeout;
    do {
        if (condition(ReadState())) return YES;
        usleep(10000);
    } while ([NSProcessInfo processInfo].systemUptime < deadline);
    return NO;
}

static NSDictionary *Controller(const char *path, const char *command, const char *mode) {
    int output[2];
    Check(pipe(output) == 0, "controller stdout pipe");
    posix_spawn_file_actions_t actions;
    Check(posix_spawn_file_actions_init(&actions) == 0, "controller spawn actions");
    Check(posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO) == 0,
        "controller stdout redirection");
    Check(posix_spawn_file_actions_addclose(&actions, output[0]) == 0,
        "controller closes unused pipe");
    Check(posix_spawn_file_actions_addclose(&actions, output[1]) == 0,
        "controller closes duplicated pipe");
    char *arguments[] = {(char *)path, (char *)command, (char *)mode, NULL};
    pid_t child = -1;
    int result = posix_spawn(&child, path, &actions, NULL, arguments, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(output[1]);
    Check(result == 0 && child > 0 && child != getpid(), "controller is a distinct child process");
    NSMutableData *data = [NSMutableData data];
    char buffer[1024];
    ssize_t received;
    while ((received = read(output[0], buffer, sizeof(buffer))) != 0) {
        if (received < 0 && errno == EINTR) continue;
        Check(received > 0, "controller output read");
        [data appendBytes:buffer length:(NSUInteger)received];
        Check(data.length < 16384, "controller output stays bounded");
    }
    close(output[0]);
    int status = 0;
    pid_t waited;
    do { waited = waitpid(child, &status, 0); } while (waited < 0 && errno == EINTR);
    Check(waited == child && WIFEXITED(status) && WEXITSTATUS(status) == 0,
        "controller exits successfully");
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    Check([object isKindOfClass:[NSDictionary class]], "controller returns JSON");
    return object;
}

static NSNumber *Number(NSDictionary *object, NSString *key) {
    id value = object[key];
    Check([value isKindOfClass:[NSNumber class]], "controller field exists and is numeric");
    return value;
}

static void Tests(const char *scenario, const char *controller) {
    OnMain(^{});
    Check(ReadState().observerOnly, "production constructor starts observer mode");
    Check(ReadState().requests == 0, "constructor does not replay requests");
    BOOL absent = strcmp(scenario, "absent") == 0;
    if (absent) {
        NSTimeInterval deadline = [NSProcessInfo processInfo].systemUptime + 32.0;
        while ([NSProcessInfo processInfo].systemUptime < deadline) usleep(10000);
        Check(!ReadState().hookInstalled, "missing class does not produce a hook");
        OnMain(^{ CreateClass(); });
        Check(!WaitFor(^BOOL(CLPCState state) { return state.hookInstalled; }, 1.0),
            "constructor stops retrying after its production deadline");
        OnMain(^{ Owner = [[(id)ProductClass alloc] initProduct:@"after-timeout"]; });
        OnMain(^{});
        Check(ReadState().captures == 0, "class appearing after timeout stays unhooked");
    } else {
        Check(WaitFor(^BOOL(CLPCState state) { return state.hookInstalled; }, 4.0),
            "production constructor installs hook");
        Check(ReadState().captures == 0, "constructor does not invent a captured object");
        if (strcmp(scenario, "early") == 0) {
            Check(Initializers == 1 && Owner != nil, "preexisting object remains alive");
            Check(!ReadState().productCaptured, "initialization before hook is not retroactively captured");
        }
        OnMain(^{ Owner = [[(id)ProductClass alloc] initProduct:@"after-hook"]; });
        Check(WaitFor(^BOOL(CLPCState state) { return state.productCaptured; }, 2.0),
            "real constructor hook asynchronously captures later initializer");
        Check(ReadState().captures == 1, "one later initializer yields one capture");
    }
    const char *modes[] = {"2", "3", "0"};
    for (const char *mode : modes) {
        uint64_t before = ReadState().requests;
        NSDictionary *sent = Controller(controller, "request", mode);
        Check([Number(sent, @"request_sent") boolValue], "child reports request posted");
        Check(WaitFor(^BOOL(CLPCState state) { return state.requests == before + 1; }, 2.0),
            "host receives a fresh cross-process request");
        CLPCState observed = ReadState();
        Check(observed.lastMode == strtoul(mode, NULL, 10),
            "host receives the requested mode value");
        Check(observed.returnedCalls == 0 && observed.observerOnly,
            "production observer never applies a mode");
        Check(observed.result == (absent ? CLPCResultNoProduct : CLPCResultObserver),
            "request result matches capture state");
        NSDictionary *published = Controller(controller, "status", NULL);
        Check([Number(published, @"requests") unsignedLongLongValue] == observed.requests,
            "child reads freshly published request count");
        Check([Number(published, @"captures") unsignedLongLongValue] == observed.captures,
            "child reads freshly published capture count");
        Check([Number(published, @"last_mode") unsignedLongLongValue] == observed.lastMode,
            "child reads freshly published mode");
        Check([Number(published, @"observer_only") boolValue] &&
            [Number(published, @"returned_calls") unsignedLongLongValue] == 0,
            "cross-process status confirms observer-only state");
    }
    OnMain(^{ Check(ThermalCalls == 0, "fake thermal method never called"); });
    printf("PASS %u production-entry host assertions (scenario=%s, pid=%d)\n",
        Assertions, scenario, getpid());
    exit(0);
}

int main(int argc, const char *argv[]) {
    alarm(45);
    if (argc != 5 || (strcmp(argv[4], "immediate") != 0 &&
        strcmp(argv[4], "delayed") != 0 && strcmp(argv[4], "early") != 0 &&
        strcmp(argv[4], "absent") != 0)) {
        fprintf(stderr, "Usage: host framework observer controller immediate|delayed|early|absent\n");
        return 2;
    }
    @autoreleasepool {
        if (strcmp(argv[4], "immediate") == 0 || strcmp(argv[4], "early") == 0) CreateClass();
        if (strcmp(argv[4], "early") == 0) Owner = [[(id)ProductClass alloc] initProduct:@"before-hook"];
        Framework = dlopen(argv[1], RTLD_NOW | RTLD_GLOBAL);
        if (Framework == NULL) fprintf(stderr, "Framework load: %s\n", dlerror());
        Check(Framework != NULL, "host loads real framework globally");
        void *hook = dlsym(Framework, "MSHookMessageEx");
        Dl_info provider = {};
        Check(hook != NULL && dladdr(hook, &provider) != 0 && provider.dli_fname != NULL,
            "host resolves real hook provider");
        printf("Host hook provider: %s\n", provider.dli_fname);
        Observer = dlopen(argv[2], RTLD_NOW | RTLD_LOCAL);
        if (Observer == NULL) fprintf(stderr, "Observer load: %s\n", dlerror());
        Check(Observer != NULL, "host loads observer and runs production constructor");
        ReadState = (CLPCState (*)(void))dlsym(Observer, "CLPCReadState");
        Check(ReadState != NULL, "host resolves state reader");
        if (strcmp(argv[4], "delayed") == 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                dispatch_get_main_queue(), ^{ CreateClass(); });
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @autoreleasepool { Tests(argv[4], argv[3]); }
        });
    }
    dispatch_main();
}
