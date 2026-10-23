#import <Foundation/Foundation.h>
#include <stdio.h>

@interface CLPCMinimalObject : NSObject
@end
@implementation CLPCMinimalObject
@end

int main(void) {
    @autoreleasepool {
        id object = [[CLPCMinimalObject alloc] init];
        if (object == nil) return 1;
        puts("PASS minimal Objective-C class load");
        return 0;
    }
}
