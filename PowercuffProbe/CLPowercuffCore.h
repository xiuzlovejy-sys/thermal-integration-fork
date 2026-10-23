#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdint.h>

#ifndef CLPC_TESTING
#define CLPC_TESTING 0
#endif
#ifndef CLPC_ENABLE_APPLY
#define CLPC_ENABLE_APPLY 0
#endif
#ifndef CLPC_HOST_TESTING
#define CLPC_HOST_TESTING 0
#endif

#if CLPC_TESTING
#define CLPC_REQUEST_NOTIFICATION "com.jy.charge.powercuffprobe.test.request"
#define CLPC_STATUS_NOTIFICATION "com.jy.charge.powercuffprobe.test.status"
#elif CLPC_HOST_TESTING
#define CLPC_REQUEST_NOTIFICATION "com.jy.charge.powercuffprobe.hosttest.request"
#define CLPC_STATUS_NOTIFICATION "com.jy.charge.powercuffprobe.hosttest.status"
#else
#define CLPC_REQUEST_NOTIFICATION "com.jy.charge.powercuffprobe.request"
#define CLPC_STATUS_NOTIFICATION "com.jy.charge.powercuffprobe.status"
#endif
#if !CLPC_TESTING && CLPC_ENABLE_APPLY
#error Production probe must remain observer-only
#endif

typedef NS_ENUM(uint8_t, CLPCResult) {
    CLPCResultIdle = 0,
    CLPCResultObserver = 1,
    CLPCResultNoProduct = 2,
    CLPCResultInvalidMode = 3,
    CLPCResultCallReturned = 4,
    CLPCResultException = 5,
    CLPCResultNoChange = 6
};

typedef struct {
    BOOL hookInstalled;
    BOOL productCaptured;
    BOOL observerOnly;
    BOOL signatureRejected;
    BOOL ownsSimulation;
    uint64_t captures;
    uint64_t requests;
    uint64_t returnedCalls;
    uint64_t rejectedRequests;
    uint8_t lastMode;
    CLPCResult result;
} CLPCState;

#ifdef __cplusplus
extern "C" {
#endif
BOOL CLPCMethodMatches(Method method, char returnType);
BOOL CLPCInstallClass(Class productClass);
void CLPCStartObserver(void);
void CLPCSetHookState(BOOL installed, BOOL valid);
void CLPCCaptureProduct(id product);
void CLPCRequestMode(uint64_t mode);
CLPCState CLPCReadState(void);
#if CLPC_TESTING
void CLPCReleaseProductForTests(void);
#endif
#ifdef __cplusplus
}
#endif
