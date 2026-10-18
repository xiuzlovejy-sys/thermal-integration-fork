#ifndef CL_OFFLINE_ADVISORY_H
#define CL_OFFLINE_ADVISORY_H
/* Read-only daemon-side observation bridge. NEVER an actuator. Not in an Xcode target. */
#if defined(CL_OFFLINE_ADVISORY_ENABLE_WRITES) || defined(CL_OFFLINE_ADVISORY_APPLY_CHARGE_POLICY)
#error "Offline advisory cannot be compiled with actuator features"
#endif
#define CL_OFFLINE_ADVISORY_DRY_RUN 1
#ifdef __OBJC__
#import <Foundation/Foundation.h>
/* One owner, serialized event stream. Caller supplies monotonic time and a matching
 * sample timestamp (same clock domain); UpdateTime is NOT monotonic seconds.
 * Source dictionaries are never modified. All output is JSON/plist-safe.
 * No implicit device ownership is asserted by this adapter. */
@interface CLOfflineAdvisory : NSObject
- (NSDictionary *)observeBattery:(NSDictionary *)battery
                         settings:(NSDictionary *)settings
                     monotonicNow:(double)now
                monotonicSampleAt:(NSNumber *)sampleAt
                        ownership:(NSString *)ownership;
/* A schema-only configuration check; returns diagnostic strings, not writes. */
+ (NSDictionary *)validateSettings:(NSDictionary *)settings;
@end
#endif
#endif
