#include "temperature_stop.h"
#include <math.h>

static tn_stop_decision result(tn_advisory a, tn_reason r, int latched)
{
    tn_stop_decision d;
    d.advisory = a;
    d.reason = r;
    d.latched = latched;
    return d;
}

tn_stop_config tn_stop_default_config(void)
{
    tn_stop_config c = {0, 42.0, 37.0, 15.0};
    return c;
}

int tn_stop_config_valid(const tn_stop_config *c)
{
    return c && (c->enabled == 0 || c->enabled == 1) &&
           isfinite(c->stop_c) && isfinite(c->resume_c) &&
           isfinite(c->max_age_s) && c->resume_c >= 15.0 &&
           c->resume_c < c->stop_c && c->stop_c <= 60.0 &&
           c->max_age_s >= 0.0;
}

int tn_stop_init(tn_stop_state *state, const tn_stop_config *config)
{
    tn_stop_config c = config ? *config : tn_stop_default_config();
    if (!state || !tn_stop_config_valid(&c)) return 0;
    state->config = c;
    state->latched = 0;
    state->has_last_now = 0;
    state->last_now = 0.0;
    state->has_last_sample_at = 0;
    state->last_sample_at = 0.0;
    return 1;
}

int tn_stop_step(tn_stop_state *state, const tn_stop_sample *s,
                 tn_stop_decision *out)
{
    double age = 0.0;
    if (!state || !s || !out) return 0;
    if (!state->config.enabled) {
        state->latched = 0;
        *out = result(TN_NONE, TN_DISABLED, 0);
        return 1;
    }
    if (!isfinite(s->now) || (state->has_last_now && s->now <= state->last_now)) {
        *out = result(TN_NONE, TN_BAD_CLOCK, state->latched);
        return 1;
    }
    state->last_now = s->now;
    state->has_last_now = 1;
    if (s->ownership_ours != 1) {
        state->latched = 0;
        *out = result(TN_NONE, TN_NO_OWNER, 0);
        return 1;
    }
    if (s->plugged != 1) {
        state->latched = 0;
        *out = result(TN_NONE, TN_UNPLUGGED, 0);
        return 1;
    }
    if (s->has_sampled_at) age = s->now - s->sampled_at;
    if (!s->has_temp_c || !isfinite(s->temp_c) ||
        s->temp_c < -20.0 || s->temp_c > 90.0 ||
        !s->has_sampled_at || !isfinite(age) || age < 0.0 ||
        age > state->config.max_age_s ||
        (state->has_last_sample_at && s->sampled_at <= state->last_sample_at)) {
        *out = result(TN_NONE, TN_BAD_TEMPERATURE, state->latched);
        return 1;
    }
    state->last_sample_at = s->sampled_at;
    state->has_last_sample_at = 1;
    if (s->temp_c >= state->config.stop_c) {
        state->latched = 1;
        *out = result(TN_STOP_REVIEW, TN_STOP_REACHED, 1);
    } else if (state->latched && s->temp_c <= state->config.resume_c) {
        state->latched = 0;
        *out = result(TN_RESUME_REVIEW, TN_RECOVERED, 0);
    } else {
        *out = result(TN_NONE, TN_STEADY, state->latched);
    }
    return 1;
}

const char *tn_stop_advisory_name(tn_advisory a)
{
    switch (a) {
    case TN_NONE: return "none";
    case TN_STOP_REVIEW: return "stop-review";
    case TN_RESUME_REVIEW: return "resume-review";
    default: return "unknown";
    }
}

const char *tn_stop_reason_name(tn_reason r)
{
    switch (r) {
    case TN_DISABLED: return "temperature stop disabled";
    case TN_BAD_CLOCK: return "non-monotonic clock; no release";
    case TN_NO_OWNER: return "ownership unverified; do not claim control";
    case TN_UNPLUGGED: return "unplugged; do not command charge";
    case TN_BAD_TEMPERATURE: return "temperature invalid/stale/repeated; no release";
    case TN_STOP_REACHED: return "configured user temperature reached; advisory only";
    case TN_RECOVERED: return "temperature recovered; other blockers still apply";
    case TN_STEADY: return "temperature hysteresis/steady";
    default: return "unknown";
    }
}
