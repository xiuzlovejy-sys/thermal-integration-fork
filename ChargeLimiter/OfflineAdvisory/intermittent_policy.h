#ifndef CL_INTERMITTENT_POLICY_H
#define CL_INTERMITTENT_POLICY_H

#include <stdint.h>

typedef enum {
    IC_OBSERVING, IC_WAIT_STOP, IC_COOLING, IC_WAIT_RELEASE, IC_SUSPENDED
} ic_state;

typedef enum {
    IC_NONE, IC_PROPOSE_STOP, IC_PROPOSE_RELEASE_OWN, IC_REVIEW_RECOVERY
} ic_action;

typedef enum {
    IC_CONFIRMED, IC_ACCEPTED_UNVERIFIED, IC_FAILED
} ic_result;

typedef struct {
    double stop_c, resume_c;
    double min_run_s, min_pause_s, max_pause_s;
    double max_age_s, ack_timeout_s;
} ic_config;

typedef struct {
    double now, sampled_at, temperature_c;
    int temperature_valid, enabled, external_power;
    int higher_priority_stop, ownership_exclusive;
    int recovery_ready, controls_known_clear;
} ic_sample;

typedef struct {
    ic_config config;
    ic_state state;
    double last_now, transition_at, command_at, last_sample_at;
    int has_now, has_sample, owns_stop, unresolved, initialized, run_active;
    uint64_t session_id, command_id;
} ic_policy;

typedef struct {
    ic_action action;
    ic_state state;
    uint64_t session_id, command_id;
    int recovery_required;
    const char *reason;
} ic_decision;

#ifdef __cplusplus
extern "C" {
#endif
int ic_init(ic_policy *policy, const ic_config *config, uint64_t session_id);
int ic_step(ic_policy *policy, const ic_sample *sample, ic_decision *decision);
int ic_ack(ic_policy *policy, uint64_t session_id, uint64_t command_id, ic_result result, double now);
#ifdef __cplusplus
}
#endif

#endif
