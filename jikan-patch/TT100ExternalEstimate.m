#import "TT100ExternalEstimate.h"

// Jy's charge daemon: POST http://127.0.0.1:1230 {"api":"status"}
// 返回 {"status":0,"data":{"eta_min":18,"eta_state":"charging","duty":0.43,...}}
static NSString *const kJysEstimateURL = @"http://127.0.0.1:1230";
static const NSTimeInterval kJysRefreshInterval = 2.0;   // 最短请求间隔
static const NSTimeInterval kJysMaxAge = 90.0;           // 缓存有效期

static NSDictionary *gJysData = nil;
static NSTimeInterval gJysDataTs = 0;
static NSTimeInterval gJysLastAttempt = 0;
static BOOL gJysInFlight = NO;
static NSLock *gJysLock = nil;

@implementation TT100ExternalEstimate

+ (void)initialize {
    if (self == [TT100ExternalEstimate class]) {
        gJysLock = [NSLock new];
    }
}

+ (void)refreshIfNeeded {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    [gJysLock lock];
    BOOL skip = gJysInFlight || (now - gJysLastAttempt) < kJysRefreshInterval;
    if (!skip) {
        gJysInFlight = YES;
        gJysLastAttempt = now;
    }
    [gJysLock unlock];
    if (skip) return;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kJysEstimateURL]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 1.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{ @"api": @"status" }
                                                      options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *payload = nil;
        if (error == nil && data.length > 0 &&
            [response isKindOfClass:[NSHTTPURLResponse class]] &&
            ((NSHTTPURLResponse *)response).statusCode == 200) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]] &&
                [json[@"status"] respondsToSelector:@selector(integerValue)] &&
                [json[@"status"] integerValue] == 0 &&
                [json[@"data"] isKindOfClass:[NSDictionary class]]) {
                payload = json[@"data"];
            }
        }
        NSTimeInterval ts = [NSDate date].timeIntervalSince1970;
        [gJysLock lock];
        gJysInFlight = NO;
        if (payload != nil) {
            gJysData = payload;
            gJysDataTs = ts;
        }
        [gJysLock unlock];
    }] resume];
}

+ (NSDictionary *)cachedEstimate {
    [gJysLock lock];
    NSDictionary *data = gJysData;
    NSTimeInterval ts = gJysDataTs;
    [gJysLock unlock];
    if (data == nil) return nil;
    if (([NSDate date].timeIntervalSince1970 - ts) > kJysMaxAge) return nil;
    return data;
}

@end
