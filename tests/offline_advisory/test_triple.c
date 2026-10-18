#include "../../ChargeLimiter/OfflineAdvisory/triple_advisory.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
static ta_input input(double now, double temp, double soc) {
    ta_input x = {0};
    x.now = x.temp_sampled_at = x.percent_sampled_at = now;
    x.has_temp = x.has_temp_sampled_at = 1;
    x.has_percent = x.has_percent_sampled_at = 1;
    x.temp_c = temp; x.percent = soc;
    x.plugged = 1; x.ownership = TP_OURS;
    return x;
}
#define STEP() assert(ta_step(&s, &x, &d))
int main(void) {
    ta_state s; ta_output d, saved;
    ta_config c = ta_default_config();
    ta_input x = input(100, 30, 60);
    assert(!c.gradual_enabled && !c.exact.enabled && !c.capacity.enabled);
    assert(ta_init(&s, NULL)); STEP(); assert(d.hint == TA_NONE);
    c.gradual_enabled = c.exact.enabled = c.capacity.enabled = 1;
    assert(ta_init(&s, &c));
    x.ownership = TP_UNKNOWN; STEP(); assert(d.hint == TA_NONE && d.reason == TA_NO_OWNER);
    x = input(101, 45, 90); x.system_critical = 1; STEP();
    assert(d.hint == TA_SYSTEM_STOP_REVIEW);
    x = input(102, 45, 90); STEP(); assert(d.hint == TA_EMERGENCY_STOP_REVIEW);
    x = input(103, 43, 90); STEP(); assert(d.hint == TA_EXACT_STOP_REVIEW);
    x = input(104, 38, 90); STEP(); assert(d.hint == TA_EXACT_STOP_REVIEW);
    x = input(105, 36, 90); STEP(); assert(d.hint == TA_CAPACITY_STOP_REVIEW);
    x = input(106, 35, 70); STEP(); assert(d.hint == TA_CAPACITY_STOP_REVIEW);
    c.capacity.enabled = 0; c.exact.enabled = 0;
    assert(ta_init(&s, &c));
    x = input(107, 40, 70); STEP(); assert(d.hint == TA_GRADUAL_REVIEW);
    x = input(108, 30, 70); STEP(); assert(d.hint == TA_GRADUAL_REVIEW); /* hold */
    x = input(170, 30, 70); STEP(); assert(d.hint == TA_GRADUAL_REVIEW);
    x = input(231, 30, 70); STEP(); assert(d.hint == TA_NONE && d.gradual_level == TP_OFF);
    assert(ta_init(&s, &c));
    x = input(231, 40, 70); STEP(); assert(d.hint == TA_GRADUAL_REVIEW);
    x = input(292, 30, 70); STEP(); assert(d.hint == TA_GRADUAL_REVIEW);
    x = input(353, 30, 70); x.external_safety_verified = 1; STEP();
    assert(d.hint == TA_GRADUAL_RELEASE_REVIEW);
    c.capacity.enabled = c.exact.enabled = 1;
    assert(ta_init(&s, &c));
    x = input(232, 43, 81); STEP(); assert(d.hint == TA_EXACT_STOP_REVIEW);
    x = input(233, 30, 70); x.has_temp = 0; STEP();
    assert(!d.temperature_valid && d.hint == TA_EXACT_STOP_REVIEW);
    x = input(234, 30, 70); x.temp_sampled_at = 232; STEP();
    assert(!d.temperature_valid && d.hint == TA_EXACT_STOP_REVIEW);
    x = input(235, NAN, 70); STEP(); assert(!d.temperature_valid && d.hint == TA_EXACT_STOP_REVIEW);
    x = input(236, 30, 70); STEP(); assert(d.hint == TA_CAPACITY_STOP_REVIEW);
    x = input(237, 30, 70); STEP(); assert(d.hint == TA_CAPACITY_STOP_REVIEW);
    c.capacity.enabled = c.gradual_enabled = 0; assert(ta_init(&s, &c));
    x = input(238, 43, 70); STEP(); assert(d.hint == TA_EXACT_STOP_REVIEW);
    x = input(239, 30, 70); STEP(); assert(d.hint == TA_NONE && d.exact.advisory == TN_RESUME_REVIEW);
    assert(ta_init(&s, &c));
    x = input(239, 43, 70); STEP(); assert(d.hint == TA_EXACT_STOP_REVIEW);
    x = input(240, 30, 70); x.external_safety_verified = 1; STEP();
    assert(d.hint == TA_EXACT_RESUME_REVIEW);
    c.capacity.enabled = 1; assert(ta_init(&s, &c));
    x = input(241, 30, 81); STEP(); assert(d.hint == TA_CAPACITY_STOP_REVIEW);
    x = input(242, 30, 70); STEP(); assert(d.hint == TA_CAPACITY_STOP_REVIEW);
    x = input(243, 30, 70); x.external_safety_verified = 1; STEP();
    assert(d.hint == TA_CAPACITY_RESUME_REVIEW);
    x = input(244, 30, 70); x.ownership = TP_OTHER; STEP(); assert(d.hint == TA_NONE);
    x = input(245, 30, 70); x.plugged = 0; STEP(); assert(d.hint == TA_NONE);
    x = input(246, 30, 70); STEP(); assert(d.hint == TA_NONE);
    x.now = 245; STEP(); assert(d.hint == TA_NONE && d.reason == TA_BAD_CLOCK);
    saved = d; s.config.capacity.max_percent = 90;
    assert(!ta_step(&s, &x, &d)); assert(!memcmp(&saved, &d, sizeof d));
    assert(ta_init(&s, &s.config)); x = input(260, 30, 81); STEP();
    assert(d.hint == TA_NONE && !d.capacity_held);
    c.exact.resume_c = 50; assert(!ta_init(&s, &c));
    x = input(261, 30, 70); STEP(); assert(d.hint == TA_NONE);
    puts("triple advisory C99: PASS");
    return 0;
}
