#include "native_capacity.h"
#include <math.h>
#include <string.h>

static const char evidence[] = "unverified (mock only)";
static const char none[] = "none";

nc_config nc_default_config(void) {
    nc_config c = {0, 80, 75, 15.0};
    return c;
}

int nc_config_valid(const nc_config *c) {
    return c && (c->enabled == 0 || c->enabled == 1) &&
        c->resume_percent >= 5 && c->resume_percent < c->max_percent &&
        c->max_percent <= 100 && isfinite(c->max_age_s) && c->max_age_s >= 0;
}

void nc_policy_init(nc_policy *p) {
    if (p) {
        p->held = 0;
        p->has_last_now = 0;
        p->last_now = 0;
        p->has_last_sample_at = 0;
        p->last_sample_at = 0;
    }
}

int nc_step(nc_policy *p, const nc_config *c, const nc_sample *s, nc_decision *out) {
    nc_decision d;
    int valid;
    if (!p || !s || !out || !nc_config_valid(c)) return 0;
    d.suggestion = none;
    d.reason = "capacity hysteresis/steady";
    d.held = p->held;
    d.has_age_s = 0;
    d.age_s = 0;
    d.evidence = evidence;
    if (!c->enabled) {
        p->held = d.held = 0;
        d.reason = "capacity control disabled";
        *out = d;
        return 1;
    }
    if (!isfinite(s->now) || (p->has_last_now && s->now <= p->last_now)) {
        d.reason = "non-monotonic clock";
        *out = d;
        return 1;
    }
    p->last_now = s->now;
    p->has_last_now = 1;
    if (s->has_sampled_at) {
        d.has_age_s = 1;
        d.age_s = s->now - s->sampled_at;
    }
    if (!s->ownership || strcmp(s->ownership, "ours") != 0) {
        p->held = d.held = 0;
        d.reason = "ownership not exclusive";
    } else if (!s->plugged) {
        p->held = d.held = 0;
        d.reason = "unplugged; no charging command";
    } else {
        valid = s->has_percent && isfinite(s->percent) &&
            s->percent >= 0 && s->percent <= 100 && d.has_age_s &&
            isfinite(d.age_s) && d.age_s >= 0 && d.age_s <= c->max_age_s &&
            (!p->has_last_sample_at || s->sampled_at > p->last_sample_at);
        if (!valid) {
            d.reason = "SOC missing/stale/invalid/repeated; no resume";
        } else {
            p->last_sample_at = s->sampled_at;
            p->has_last_sample_at = 1;
            if (s->percent >= c->max_percent) {
                p->held = d.held = 1;
                d.suggestion = "stop-review";
                d.reason = "configured capacity ceiling reached; advisory only";
            } else if (p->held && s->percent <= c->resume_percent) {
                if (!s->thermal_safe) {
                    d.reason = "below resume threshold but thermal safety not verified";
                } else {
                    p->held = d.held = 0;
                    d.suggestion = "resume-review";
                    d.reason = "below resume threshold; review other blockers";
                }
            }
        }
    }
    *out = d;
    return 1;
}
