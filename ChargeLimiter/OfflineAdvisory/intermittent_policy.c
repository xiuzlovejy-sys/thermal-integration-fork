#include "intermittent_policy.h"
#include <math.h>
#include <string.h>

static int valid_config(const ic_config *config) {
    return config && isfinite(config->stop_c) && isfinite(config->resume_c) &&
        config->resume_c < config->stop_c &&
        isfinite(config->min_run_s) && config->min_run_s > 0 &&
        isfinite(config->min_pause_s) && config->min_pause_s > 0 &&
        isfinite(config->max_pause_s) && config->max_pause_s > config->min_pause_s &&
        isfinite(config->max_age_s) && config->max_age_s > 0 &&
        isfinite(config->ack_timeout_s) && config->ack_timeout_s > 0;
}

int ic_init(ic_policy *policy, const ic_config *config, uint64_t session_id) {
    ic_policy fresh;
    if (!policy || !valid_config(config) || session_id == 0 || policy->initialized) return 0;
    memset(&fresh, 0, sizeof fresh);
    fresh.config = *config;
    fresh.state = IC_OBSERVING;
    fresh.session_id = session_id;
    fresh.initialized = 1;
    *policy = fresh;
    return 1;
}

static void suspend_policy(ic_policy *policy, ic_decision *decision, const char *reason) {
    policy->state = IC_SUSPENDED;
    decision->state = policy->state;
    decision->action = IC_REVIEW_RECOVERY;
    decision->recovery_required = policy->unresolved || policy->owns_stop;
    decision->reason = reason;
}

static void propose(ic_policy *policy, ic_decision *decision, int stop, double now) {
    if (policy->command_id == UINT64_MAX) {
        suspend_policy(policy, decision, "command sequence exhausted");
        return;
    }
    policy->command_id++;
    policy->command_at = now;
    policy->unresolved = 1;
    policy->state = stop ? IC_WAIT_STOP : IC_WAIT_RELEASE;
    decision->action = stop ? IC_PROPOSE_STOP : IC_PROPOSE_RELEASE_OWN;
    decision->state = policy->state;
    decision->command_id = policy->command_id;
    decision->recovery_required = 1;
    decision->reason = stop ? "warm; propose journaled charge pause" :
                             "release only this policy's stop through arbiter";
}

int ic_step(ic_policy *policy, const ic_sample *sample, ic_decision *decision) {
    ic_decision output;
    double age;
    if (!policy || !policy->initialized || !sample || !decision) return 0;
    memset(&output, 0, sizeof output);
    output.state = policy->state;
    output.command_id = policy->command_id;
    output.session_id = policy->session_id;
    output.recovery_required = policy->unresolved || policy->owns_stop;
    output.reason = "steady";
    if (policy->state == IC_SUSPENDED) {
        output.reason = "suspended; explicit recovery and rearm required";
    } else if (!isfinite(sample->now) ||
               (policy->has_now && sample->now <= policy->last_now)) {
        suspend_policy(policy, &output, "clock invalid or non-monotonic");
    } else {
        if (!policy->has_now) policy->transition_at = sample->now;
        policy->last_now = sample->now;
        policy->has_now = 1;
        if (!sample->ownership_exclusive || sample->higher_priority_stop) {
            suspend_policy(policy, &output, "defer to other owner or protection; no charging write");
        } else if ((policy->state == IC_WAIT_STOP || policy->state == IC_WAIT_RELEASE) &&
                   (!sample->external_power || !sample->enabled)) {
            suspend_policy(policy, &output, "power or enable changed during command; require recovery");
        } else if (policy->state == IC_WAIT_STOP || policy->state == IC_WAIT_RELEASE) {
            if (sample->now - policy->command_at >= policy->config.ack_timeout_s) {
                suspend_policy(policy, &output, "command acknowledgment timeout; do not retry");
            } else {
                output.reason = "await acknowledgment; no duplicate command";
            }
        } else if (!sample->external_power) {
            if (policy->owns_stop) {
                suspend_policy(policy, &output, "unplugged with owned stop; hand off recovery");
            } else {
                policy->transition_at = sample->now;
                policy->run_active = 0;
                output.reason = "unplugged; no write";
            }
        } else if (!sample->enabled) {
            if (policy->owns_stop) {
                propose(policy, &output, 0, sample->now);
            } else {
                policy->transition_at = sample->now;
                policy->run_active = 0;
                output.reason = "disabled; no write";
            }
        } else {
            age = sample->now - sample->sampled_at;
            if (!sample->temperature_valid || !isfinite(sample->temperature_c) ||
                sample->temperature_c < -20 || sample->temperature_c > 90 ||
                !isfinite(age) || age < 0 || age > policy->config.max_age_s ||
                (policy->has_sample && sample->sampled_at <= policy->last_sample_at)) {
                suspend_policy(policy, &output, "temperature invalid, stale or repeated");
            } else {
                if (policy->state == IC_OBSERVING && !policy->run_active) {
                    policy->transition_at = sample->now;
                    policy->run_active = 1;
                }
                policy->last_sample_at = sample->sampled_at;
                policy->has_sample = 1;
                if (policy->state == IC_COOLING) {
                    double duration = sample->now - policy->transition_at;
                    if (duration >= policy->config.max_pause_s) {
                        suspend_policy(policy, &output, "maximum pause reached; require recovery review");
                    } else if (sample->temperature_c <= policy->config.resume_c &&
                               duration >= policy->config.min_pause_s) {
                        propose(policy, &output, 0, sample->now);
                    } else {
                        output.reason = "cooling; hysteresis or minimum pause";
                    }
                } else if (!sample->controls_known_clear || !sample->recovery_ready) {
                    suspend_policy(policy, &output, "stop preconditions unknown; no new stop");
                } else if (sample->temperature_c >= policy->config.stop_c &&
                           sample->now - policy->transition_at >= policy->config.min_run_s) {
                    propose(policy, &output, 1, sample->now);
                } else {
                    output.reason = "observe; threshold or minimum run not reached";
                }
            }
        }
    }
    *decision = output;
    return 1;
}

int ic_ack(ic_policy *policy, uint64_t session_id, uint64_t command_id, ic_result result, double now) {
    int stopping;
    if (!policy || !policy->initialized || session_id != policy->session_id ||
        (policy->state != IC_WAIT_STOP && policy->state != IC_WAIT_RELEASE) ||
        command_id != policy->command_id || !isfinite(now) || now < policy->last_now ||
        result < IC_CONFIRMED || result > IC_FAILED) return 0;
    if (now - policy->command_at >= policy->config.ack_timeout_s ||
        result != IC_CONFIRMED) {
        policy->state = IC_SUSPENDED;
        return 1;
    }
    stopping = policy->state == IC_WAIT_STOP;
    policy->owns_stop = stopping;
    policy->unresolved = stopping;
    policy->state = stopping ? IC_COOLING : IC_OBSERVING;
    policy->transition_at = now;
    policy->run_active = !stopping;
    policy->last_now = now;
    return 1;
}
