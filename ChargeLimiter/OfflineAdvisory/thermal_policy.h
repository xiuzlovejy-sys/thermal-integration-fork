#ifndef THERMAL_POLICY_H
#define THERMAL_POLICY_H
/* C99 offline advisory engine. No hardware access or clock reads. Caller supplies
 * monotonic seconds, explicit presence flags, and an ownership observation.
 * Numeric levels match the Python policy: OFF=0, LIGHT=2, MODERATE=3.
 * Output requested is advisory only; never send it to a device without separate
 * safety review. No implementation here performs charging operations. */
#ifdef __cplusplus
extern "C" {
#endif

typedef enum { TP_OFF=0, TP_LIGHT=2, TP_MODERATE=3 } tp_level;
typedef enum { TP_UNKNOWN=0, TP_OURS=1, TP_OTHER=2 } tp_ownership;
typedef enum { TP_NONE=0, TP_PROPOSE_ONLY=1,
               TP_PROPOSE_RELEASE_ONLY=2, TP_MANUAL_STOP_REVIEW=3 } tp_action;
typedef struct {
    double rise_light, rise_moderate, fall_light, fall_moderate;
    double emergency, min_hold_s, max_age_s;
} tp_config;
typedef struct {
    double now, sampled_at, temp_c;
    int has_sampled_at, has_temp;
    int plugged, system_critical, paused;
    tp_ownership ownership;
    /* SOC, current, observed_level are intentionally irrelevant to policy. */
} tp_sample;
typedef struct {
    tp_config config;
    tp_level level;
    double last_change, last_now, last_sample_at;
    int has_last_change, has_last_now, has_last_sample_at;
} tp_policy;
typedef struct {
    int has_requested; /* 0 means no command, even if state is OFF */
    tp_level requested;
    tp_action action;
    const char *reason; /* static string: never free */
    int has_age;
    double age_s;
    tp_level state;
} tp_decision;

tp_config tp_default_config(void);
/* Returns 1 on success; 0 for null pointer or invalid configuration.
 * Failed initialization does not modify *p. No global mutable state. */
int tp_init(tp_policy *p, const tp_config *config);
/* Returns 1 on success; 0 on null pointer, leaving *p and *out unchanged.
 * p and out must not overlap. Output may be copied by value. */
int tp_step(tp_policy *p, const tp_sample *s, tp_decision *out);
#ifdef __cplusplus
}
#endif
#endif
