#include "../../ChargeLimiter/OfflineAdvisory/thermal_policy.h"
#include "../../ChargeLimiter/OfflineAdvisory/native_capacity.h"
#include <assert.h>
#include <string.h>
#include <stdio.h>

int main(void) {
    tp_policy t; tp_decision td;
    nc_policy c; nc_decision cd;
    tp_config tc = tp_default_config();
    nc_config cc = nc_default_config();
    assert(tp_init(&t, &tc)); nc_policy_init(&c);
    cc.enabled = 1; assert(nc_config_valid(&cc));
    tp_sample ts = {0}; nc_sample cs = {0};
    ts.now = cs.now = 100; ts.sampled_at = cs.sampled_at = 100;
    ts.has_sampled_at = cs.has_sampled_at = 1;
    ts.temp_c = 40; ts.has_temp = 1; ts.plugged = cs.plugged = 1;
    cs.has_percent = 1; cs.percent = 81; cs.thermal_safe = 0;
    /* Never infer ownership: unknown issues no requests. */
    assert(tp_step(&t, &ts, &td) && !td.has_requested);
    assert(nc_step(&c, &cc, &cs, &cd) && !strcmp(cd.suggestion, "none"));
    ts.ownership = TP_OURS; cs.ownership = "ours";
    ts.now = cs.now = 101; ts.sampled_at = cs.sampled_at = 101;
    assert(tp_step(&t, &ts, &td) && td.state == TP_MODERATE && td.action == TP_PROPOSE_ONLY);
    assert(nc_step(&c, &cc, &cs, &cd) && !strcmp(cd.suggestion, "stop-review") && cd.held);
    /* Duplicate/old samples cannot authorize capacity resume. */
    ts.now = cs.now = 102; cs.percent = 70;
    assert(nc_step(&c, &cc, &cs, &cd) && cd.held && !strcmp(cd.suggestion, "none"));
    ts.sampled_at = cs.sampled_at = 101; ts.now = cs.now = 103;
    assert(nc_step(&c, &cc, &cs, &cd) && cd.held && !strcmp(cd.suggestion, "none"));
    assert(!strcmp(cd.reason, "SOC missing/stale/invalid/repeated; no resume"));
    ts.sampled_at = cs.sampled_at = 104; ts.now = cs.now = 104;
    assert(nc_step(&c, &cc, &cs, &cd) && cd.held && !strcmp(cd.suggestion, "none"));
    assert(!strcmp(cd.reason, "below resume threshold but thermal safety not verified"));
    ts.ownership = TP_UNKNOWN; cs.ownership = NULL;
    ts.now = cs.now = 105; ts.sampled_at = cs.sampled_at = 105;
    assert(tp_step(&t, &ts, &td) && !td.has_requested);
    assert(nc_step(&c, &cc, &cs, &cd) && !cd.held && !strcmp(cd.suggestion, "none"));
    tc.rise_light = 99; assert(!tp_init(&t, &tc));
    cc.resume_percent = 100; assert(!nc_config_valid(&cc));
    puts("offline two-core integration harness: PASS");
    return 0;
}
