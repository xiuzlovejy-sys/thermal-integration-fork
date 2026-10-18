#include "triple_advisory.h"
#include <math.h>
#include <string.h>

static int same_config(const ta_config *a, const ta_config *b) {
    return a->gradual_enabled == b->gradual_enabled &&
        a->gradual.rise_light == b->gradual.rise_light &&
        a->gradual.rise_moderate == b->gradual.rise_moderate &&
        a->gradual.fall_light == b->gradual.fall_light &&
        a->gradual.fall_moderate == b->gradual.fall_moderate &&
        a->gradual.emergency == b->gradual.emergency &&
        a->gradual.min_hold_s == b->gradual.min_hold_s &&
        a->gradual.max_age_s == b->gradual.max_age_s &&
        a->exact.enabled == b->exact.enabled &&
        a->exact.stop_c == b->exact.stop_c &&
        a->exact.resume_c == b->exact.resume_c &&
        a->exact.max_age_s == b->exact.max_age_s &&
        a->capacity.enabled == b->capacity.enabled &&
        a->capacity.max_percent == b->capacity.max_percent &&
        a->capacity.resume_percent == b->capacity.resume_percent &&
        a->capacity.max_age_s == b->capacity.max_age_s;
}

ta_config ta_default_config(void) {
    ta_config c;
    c.gradual_enabled = 0;
    c.gradual = tp_default_config();
    c.exact = tn_stop_default_config();
    c.capacity = nc_default_config();
    return c;
}
int ta_config_valid(const ta_config *c) {
    tp_policy scratch;
    return c && (c->gradual_enabled == 0 || c->gradual_enabled == 1) &&
        tp_init(&scratch, &c->gradual) &&
        tn_stop_config_valid(&c->exact) && nc_config_valid(&c->capacity);
}
int ta_init(ta_state *s, const ta_config *config) {
    ta_state fresh;
    ta_config c = config ? *config : ta_default_config();
    if (!s || !ta_config_valid(&c)) return 0;
    memset(&fresh, 0, sizeof fresh);
    fresh.config = c;
    fresh.initialized_config = c;
    if (!tp_init(&fresh.gradual, &c.gradual) ||
        !tn_stop_init(&fresh.exact, &c.exact)) return 0;
    nc_policy_init(&fresh.capacity);
    *s = fresh;
    return 1;
}
int ta_step(ta_state *s, const ta_input *in, ta_output *out) {
    ta_state next;
    ta_output d;
    tp_sample ts;
    tn_stop_sample es;
    nc_sample cs;
    int valid, owner, active, emergency;
    double age;
    if (!s || !in || !out || (void *)s == (void *)out ||
        !ta_config_valid(&s->config) ||
        !same_config(&s->config, &s->initialized_config)) return 0;
    /* Settings are applied only via ta_init; detect direct edits to core configs. */
    if (s->gradual.config.rise_light != s->config.gradual.rise_light ||
        s->gradual.config.rise_moderate != s->config.gradual.rise_moderate ||
        s->gradual.config.fall_light != s->config.gradual.fall_light ||
        s->gradual.config.fall_moderate != s->config.gradual.fall_moderate ||
        s->gradual.config.emergency != s->config.gradual.emergency ||
        s->gradual.config.min_hold_s != s->config.gradual.min_hold_s ||
        s->gradual.config.max_age_s != s->config.gradual.max_age_s ||s->exact.config.enabled != s->config.exact.enabled ||
        s->exact.config.stop_c != s->config.exact.stop_c ||
        s->exact.config.resume_c != s->config.exact.resume_c ||
        s->exact.config.max_age_s != s->config.exact.max_age_s) return 0;
    next = *s;
    memset(&d, 0, sizeof d);
    d.reason = TA_STEADY;
    if (!isfinite(in->now) || (s->has_last_now && in->now <= s->last_now)) {
        d.reason = TA_BAD_CLOCK;
        goto done;
    }
    next.has_last_now = 1;
    next.last_now = in->now;
    owner = in->ownership == TP_OURS;
    active = in->plugged == 1 && !in->paused && !in->system_critical;
    age = in->now - in->temp_sampled_at;
    valid = in->has_temp == 1 && in->has_temp_sampled_at == 1 &&
        isfinite(in->temp_c) && in->temp_c >= -20 && in->temp_c <= 90 &&
        isfinite(age) && age >= 0 &&
        age <= s->config.gradual.max_age_s &&
        (!s->config.exact.enabled || age <= s->config.exact.max_age_s) &&
        (!s->has_last_temp_at || in->temp_sampled_at > s->last_temp_at);
    d.temperature_valid = valid;
    if (valid && owner && active) {
        next.has_last_temp_at = 1;
        next.last_temp_at = in->temp_sampled_at;
    }
    emergency = valid && in->temp_c >= s->config.gradual.emergency;
    memset(&ts, 0, sizeof ts);
    ts.now = in->now;
    ts.sampled_at = in->temp_sampled_at;
    ts.temp_c = in->temp_c;
    ts.has_sampled_at = in->has_temp_sampled_at;
    ts.has_temp = in->has_temp;
    ts.plugged = in->plugged;
    ts.paused = in->paused;
    ts.system_critical = in->system_critical;
    ts.ownership = in->ownership;
    /* A repeated sample under the strictest active freshness limit cannot
       be accepted by a less strict individual core. */
    if (!valid) ts.has_temp = 0;
    if (!tp_step(&next.gradual, &ts, &d.gradual)) return 0;
    memset(&es, 0, sizeof es);
    es.now = in->now;
    es.has_sampled_at = in->has_temp_sampled_at;
    es.sampled_at = in->temp_sampled_at;
    es.has_temp_c = valid;
    es.temp_c = in->temp_c;
    es.plugged = in->plugged && !in->paused && !in->system_critical;
    es.ownership_ours = owner;
    if (!tn_stop_step(&next.exact, &es, &d.exact)) return 0;
    memset(&cs, 0, sizeof cs);
    cs.now = in->now;
    cs.has_sampled_at = in->has_percent_sampled_at;
    cs.sampled_at = in->percent_sampled_at;
    cs.has_percent = in->has_percent;
    cs.percent = in->percent;
    cs.plugged = es.plugged;
    cs.ownership = owner ? "ours" : NULL;
    /* Never infer external verification from a synthetic temperature or
       ownership assertion. This bit is caller-supplied, not checked here. */
    cs.thermal_safe = in->external_safety_verified == 1 && valid &&
        !emergency && !d.exact.latched &&
        (!s->config.gradual_enabled || d.gradual.state == TP_OFF);
    if (!nc_step(&next.capacity, &s->config.capacity, &cs, &d.capacity)) return 0;
    d.exact_latched = d.exact.latched;
    d.capacity_held = d.capacity.held;
    d.gradual_level = s->config.gradual_enabled ? d.gradual.state : TP_OFF;
    if (!owner) d.reason = TA_NO_OWNER;
    else if (in->system_critical) {
        d.hint = TA_SYSTEM_STOP_REVIEW; d.reason = TA_SYSTEM_BLOCK;
    } else if (!active) d.reason = TA_INACTIVE;
    else if (emergency) {
        d.hint = TA_EMERGENCY_STOP_REVIEW; d.reason = TA_EMERGENCY_BLOCK;
    } else if (d.exact_latched) {
        d.hint = TA_EXACT_STOP_REVIEW; d.reason = TA_EXACT_BLOCK;
    } else if (d.capacity_held) {
        d.hint = TA_CAPACITY_STOP_REVIEW; d.reason = TA_CAPACITY_BLOCK;
    } else if (!valid) d.reason = TA_BAD_TEMPERATURE;
    else if (d.gradual_level != TP_OFF) {
        d.hint = TA_GRADUAL_REVIEW; d.reason = TA_GRADUAL_BLOCK;
    } else if (in->external_safety_verified == 1 &&
               d.exact.advisory == TN_RESUME_REVIEW)
        d.hint = TA_EXACT_RESUME_REVIEW;
    else if (in->external_safety_verified == 1 &&
             !strcmp(d.capacity.suggestion, "resume-review"))
        d.hint = TA_CAPACITY_RESUME_REVIEW;
    else if (in->external_safety_verified == 1 &&
             s->config.gradual_enabled &&
             s->gradual.level != TP_OFF && d.gradual_level == TP_OFF)
        d.hint = TA_GRADUAL_RELEASE_REVIEW;
done:
    *s = next;
    *out = d;
    return 1;
}
