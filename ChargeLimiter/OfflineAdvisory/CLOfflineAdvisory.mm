#import "CLOfflineAdvisory.h"
#import "thermal_policy.h"
#import "native_capacity.h"
#include <math.h>
#include <string.h>
#if !CL_OFFLINE_ADVISORY_DRY_RUN
#error "Dry run must be enabled"
#endif
#if defined(CL_OFFLINE_ADVISORY_ENABLE_WRITES) || defined(CL_OFFLINE_ADVISORY_APPLY_CHARGE_POLICY)
#error "No actuator feature is permitted in this translation unit"
#endif

static BOOL CLNumber(id value) { return [value isKindOfClass:[NSNumber class]] && isfinite([value doubleValue]); }
static BOOL CLBool(id value) { return CLNumber(value) && ([value doubleValue] == 0 || [value doubleValue] == 1); }
static BOOL CLInteger(id value, int low, int high) {
    return CLNumber(value) && [value doubleValue] >= low && [value doubleValue] <= high &&
           floor([value doubleValue]) == [value doubleValue];
}
static BOOL CLReal(id value, double low, double high) {
    return CLNumber(value) && [value doubleValue] >= low && [value doubleValue] <= high;
}
static NSDictionary *CLConfig(id input, NSString *name) {
    id obj = [input isKindOfClass:[NSDictionary class]] ? input[name] : nil;
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}
static BOOL CLKnownKeys(NSDictionary *dict, NSSet *allowed) {
    if (!dict) return NO;
    for (id key in dict) if (![key isKindOfClass:[NSString class]] || ![allowed containsObject:key]) return NO;
    return YES;
}
static BOOL CLParse(NSDictionary *settings, tp_config *tc, nc_config *cc, BOOL *thermalEnabled, NSString **error) {
    NSDictionary *t = CLConfig(settings, @"thermal"), *c = CLConfig(settings, @"capacity");
    if (![settings isKindOfClass:[NSDictionary class]] ||
        !CLKnownKeys(settings, [NSSet setWithArray:@[@"thermal", @"capacity"]]) ||
        !CLKnownKeys(t, [NSSet setWithArray:@[@"enabled", @"rise_light", @"rise_moderate", @"fall_light", @"fall_moderate", @"emergency", @"min_hold_s", @"max_age_s"]]) ||
        !CLKnownKeys(c, [NSSet setWithArray:@[@"enabled", @"max_percent", @"resume_percent", @"max_age_s"]])) {
        *error = @"missing/unknown policy object or key"; return NO;
    }
    if (!CLBool(t[@"enabled"]) || !CLBool(c[@"enabled"])) {
        *error = @"enabled must be numeric 0 or 1"; return NO;
    }
    *thermalEnabled = [t[@"enabled"] boolValue];
    *tc = tp_default_config(); *cc = nc_default_config();
    for (NSString *key in @[@"rise_light", @"rise_moderate", @"fall_light", @"fall_moderate", @"emergency", @"min_hold_s", @"max_age_s"]) {
        id n = t[key];
        if (n && !CLReal(n, [key isEqualToString:@"min_hold_s"] || [key isEqualToString:@"max_age_s"] ? 0 : -20,
                             [key isEqualToString:@"min_hold_s"] ? 86400 : [key isEqualToString:@"max_age_s"] ? 3600 : 90)) {
            *error = @"invalid thermal numeric range"; return NO;
        }
    }
#define TC(KEY, FIELD) if (t[@KEY]) tc->FIELD = [t[@KEY] doubleValue]
    TC("rise_light", rise_light); TC("rise_moderate", rise_moderate);
    TC("fall_light", fall_light); TC("fall_moderate", fall_moderate);
    TC("emergency", emergency); TC("min_hold_s", min_hold_s); TC("max_age_s", max_age_s);
#undef TC
    tp_policy scratch;
    if (!tp_init(&scratch, tc)) { *error = @"thermal thresholds out of order"; return NO; }
    if (c[@"max_percent"] && !CLInteger(c[@"max_percent"], 6, 100)) { *error = @"invalid capacity ceiling"; return NO; }
    if (c[@"resume_percent"] && !CLInteger(c[@"resume_percent"], 5, 99)) { *error = @"invalid capacity resume"; return NO; }
    if (c[@"max_age_s"] && !CLReal(c[@"max_age_s"], 0, 3600)) { *error = @"invalid capacity age"; return NO; }
    cc->enabled = [c[@"enabled"] intValue];
    if (c[@"max_percent"]) cc->max_percent = [c[@"max_percent"] intValue];
    if (c[@"resume_percent"]) cc->resume_percent = [c[@"resume_percent"] intValue];
    if (c[@"max_age_s"]) cc->max_age_s = [c[@"max_age_s"] doubleValue];
    if (!nc_config_valid(cc)) { *error = @"resume must be below ceiling"; return NO; }
    return YES;
}

@implementation CLOfflineAdvisory {
    tp_policy _thermal;
    nc_policy _capacity;
    BOOL _initialized;
    NSDictionary *_lastSettings;
}
+ (NSDictionary *)validateSettings:(NSDictionary *)settings {
    tp_config t; nc_config c; BOOL enabled = NO; NSString *error = nil;
    BOOL valid = CLParse(settings, &t, &c, &enabled, &error);
    return @{ @"valid": @(valid), @"error": error ?: @"", @"schema": @1,
              @"dry_run": @YES, @"actuator_available": @NO };
}
- (NSDictionary *)observeBattery:(NSDictionary *)battery settings:(NSDictionary *)settings
                    monotonicNow:(double)now monotonicSampleAt:(NSNumber *)sampleAt
                       ownership:(NSString *)ownership {
    tp_config t; nc_config c; BOOL enabled = NO; NSString *error = nil;
    BOOL valid = CLParse(settings, &t, &c, &enabled, &error);
    /* All invalid configuration is fail-closed; no previous configuration survives. */
    if (!valid) {
        _initialized = NO; _lastSettings = nil;
        NSDictionary *out = @{ @"status": @(-422), @"error": error ?: @"invalid_config",
                               @"dry_run": @YES, @"actuator_available": @NO };
        NSLog(@"[CLOfflineAdvisory] simulated rejected %@", out);
        return out;
    }
    if (!_initialized || ![_lastSettings isEqualToDictionary:settings]) {
        if (!tp_init(&_thermal, &t)) return @{ @"status": @(-422), @"error": @"invalid_thermal" };
        nc_policy_init(&_capacity);
        _lastSettings = [settings copy]; _initialized = YES;
    }
    NSDictionary *b = [battery isKindOfClass:[NSDictionary class]] ? battery : @{};
    /* Never infer ownership from the legacy charge command; this is a separately
     * supplied mock observation. Effective resumes additionally require a verified
     * safety arbitrator, unavailable here; always force thermal_safe=0. */
    BOOL ours = [ownership isEqualToString:@"ours"];
    BOOL hasClock = isfinite(now) && now >= 0;
    double clock = hasClock ? now : NAN;
    BOOL hasStamp = CLNumber(sampleAt) && [sampleAt doubleValue] >= 0;
    BOOL hasTemp = CLReal(b[@"Temperature"], -2000, 9000);
    BOOL hasSOC = CLInteger(b[@"CurrentCapacity"], 0, 100);
    /* ExternalConnected is a derived, potentially flickering value on iOS 17.
     * Require both external indicators true; absence means no exclusive evidence. */
    BOOL plugged = [b[@"ExternalConnected"] isEqual:@YES] &&
                   [b[@"ExternalChargeCapable"] isEqual:@YES];
    tp_sample ts = {0};
    ts.now = clock; ts.has_sampled_at = hasStamp; ts.sampled_at = hasStamp ? [sampleAt doubleValue] : 0;
    ts.has_temp = hasTemp; ts.temp_c = hasTemp ? [b[@"Temperature"] doubleValue] / 100.0 : 0;
    ts.plugged = plugged; ts.ownership = ours ? TP_OURS : TP_UNKNOWN;
    /* Disabled thermal policy uses paused release, not a live override. */
    ts.paused = !enabled;
    tp_decision td = {0};
    nc_sample cs = {0};
    cs.now = clock; cs.has_sampled_at = hasStamp; cs.sampled_at = ts.sampled_at;
    cs.has_percent = hasSOC; cs.percent = hasSOC ? [b[@"CurrentCapacity"] doubleValue] : 0;
    cs.plugged = plugged; cs.ownership = ours ? "ours" : NULL;
    cs.thermal_safe = 0; /* ABSOLUTELY NO inferred safe-to-resume. */
    nc_decision cd = {0};
    int tr = tp_step(&_thermal, &ts, &td), cr = nc_step(&_capacity, &c, &cs, &cd);
    if (!tr || !cr) return @{ @"status": @(-500), @"error": @"core_failure",
                              @"dry_run": @YES, @"actuator_available": @NO };
    NSDictionary *result = @{
        @"status": @0, @"schema": @1, @"dry_run": @YES, @"actuator_available": @NO,
        @"source": @"offline_advisory", @"sample_clock": @"caller_monotonic",
        @"ownership_verified": @NO, @"physical_state_verified": @NO,
        @"thermal": @{ @"enabled": @(enabled), @"level": @(td.state),
                       @"has_request": @(td.has_requested && enabled),
                       @"proposed_level": @(td.has_requested && enabled ? td.requested : TP_OFF),
                       @"action": @(enabled ? td.action : TP_NONE),
                       @"reason": [NSString stringWithUTF8String:td.reason],
                       @"age_s": td.has_age && isfinite(td.age_s) ? @(td.age_s) : [NSNull null] },
        @"capacity": @{ @"enabled": @(c.enabled), @"held_latch": @(cd.held),
                        @"suggestion": [NSString stringWithUTF8String:cd.suggestion],
                        @"reason": [NSString stringWithUTF8String:cd.reason],
                        @"evidence": [NSString stringWithUTF8String:cd.evidence],
                        @"age_s": cd.has_age_s && isfinite(cd.age_s) ? @(cd.age_s) : [NSNull null] }
    };
    NSLog(@"[CLOfflineAdvisory] simulated %@", result);
    return result;
}
@end
