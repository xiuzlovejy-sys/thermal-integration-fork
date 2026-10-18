#include "thermal_policy.h"
#include <math.h>
#include <string.h>

static int config_valid(const tp_config *c) {
    if (!c) return 0;
    return isfinite(c->fall_light) && isfinite(c->rise_light) &&
        isfinite(c->fall_moderate) && isfinite(c->rise_moderate) &&
        isfinite(c->emergency) && isfinite(c->min_hold_s) &&
        isfinite(c->max_age_s) &&
        c->fall_light < c->rise_light &&
        c->rise_light < c->fall_moderate &&
        c->fall_moderate < c->rise_moderate &&
        c->rise_moderate < c->emergency &&
        c->min_hold_s >= 0 && c->max_age_s >= 0;
}

tp_config tp_default_config(void) {
    tp_config c = {35, 39, 33, 36, 44, 60, 15};
    return c;
}

int tp_init(tp_policy *p, const tp_config *config) {
    tp_policy fresh;
    if (!p || !config_valid(config)) return 0;
    memset(&fresh, 0, sizeof fresh);
    fresh.config = *config;
    fresh.level = TP_OFF;
    *p = fresh;
    return 1;
}

static void release_level(tp_policy *p, tp_decision *d, double now,
                          const char *reason) {
    int changed = p->level != TP_OFF;
    p->level = TP_OFF;
    if (changed) {
        p->last_change = now;
        p->has_last_change = 1;
    }
    d->has_requested = 1;
    d->requested = TP_OFF;
    d->action = changed ? TP_PROPOSE_RELEASE_ONLY : TP_NONE;
    d->reason = reason;
    d->state = p->level;
}

int tp_step(tp_policy *p, const tp_sample *s, tp_decision *out) {
    tp_decision d;
    tp_level target;
    double t;
    if (!p || !s || !out) return 0;
    memset(&d, 0, sizeof d);
    d.state = p->level;
    d.reason = "hysteresis/steady";
    if (!isfinite(s->now) || (p->has_last_now && s->now <= p->last_now)) {
        d.reason = "non-monotonic clock; state unchanged";
        *out = d;
        return 1;
    }
    p->last_now = s->now;
    p->has_last_now = 1;
    if (s->has_sampled_at) {
        d.has_age = 1;
        d.age_s = s->now - s->sampled_at;
    }
    if (s->ownership != TP_OURS) {
        p->level = TP_OFF;
        p->has_last_change = 0;
        d.reason = "ownership not exclusive; manual review";
        d.state = TP_OFF;
        *out = d;
        return 1;
    }
    if (s->system_critical || s->paused || !s->plugged) {
        const char *why = s->system_critical ? "system protection; no reset/charging write" :
                          s->paused ? "paused; no reset/charging write" :
                          "unplugged; no reset/charging write";
        release_level(p, &d, s->now, why);
        *out = d;
        return 1;
    }
    if (!(s->has_temp && isfinite(s->temp_c) &&
          s->temp_c >= -20 && s->temp_c <= 90 &&
          d.has_age && isfinite(d.age_s) &&
          d.age_s >= 0 && d.age_s <= p->config.max_age_s &&
          (!p->has_last_sample_at || s->sampled_at > p->last_sample_at))) {
        release_level(p, &d, s->now,
                      "temperature missing/stale/invalid/repeated; no reset/charging write");
        *out = d;
        return 1;
    }
    p->last_sample_at = s->sampled_at;
    p->has_last_sample_at = 1;
    t = s->temp_c;
    if (t >= p->config.emergency) {
        d.action = TP_MANUAL_STOP_REVIEW;
        d.reason = "emergency temperature; SOC cannot override";
        *out = d;
        return 1;
    }
    target = p->level;
    if (t >= p->config.rise_moderate) target = TP_MODERATE;
    else if (t >= p->config.rise_light && p->level == TP_OFF) target = TP_LIGHT;
    else if (p->level == TP_MODERATE && t <= p->config.fall_moderate) target = TP_LIGHT;
    else if (p->level == TP_LIGHT && t <= p->config.fall_light) target = TP_OFF;
    if (target < p->level && p->has_last_change &&
        s->now - p->last_change < p->config.min_hold_s) {
        target = p->level;
        d.reason = "cooling; minimum hold";
    } else {
        d.reason = target > p->level ? "warming" :
                   target < p->level ? "cooling" : "hysteresis/steady";
    }
    if (target != p->level) {
        p->level = target;
        p->last_change = s->now;
        p->has_last_change = 1;
        d.action = TP_PROPOSE_ONLY;
    }
    d.has_requested = 1;
    d.requested = p->level;
    d.state = p->level;
    *out = d;
    return 1;
}
