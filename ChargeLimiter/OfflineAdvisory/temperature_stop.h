#ifndef THERMAL_NATIVE_STOP_H
#define THERMAL_NATIVE_STOP_H

/* C99, pure advisory state machine. No hardware interface or device writes. */
#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int enabled;               /* 0 or 1 */
    double stop_c;              /* [15,60], strictly above resume_c */
    double resume_c;            /* [15,stop_c) */
    double max_age_s;           /* finite, >= 0 */
} tn_stop_config;

typedef struct {
    double now;
    int has_sampled_at;       /* 0=None, 1=provided */
    double sampled_at;
    int has_temp_c;           /* 0=None, 1=provided */
    double temp_c;
    int plugged;              /* 0 or 1 */
    int ownership_ours;       /* 1 iff ownership string equals "ours" */
} tn_stop_sample;

typedef enum {
    TN_NONE = 0,
    TN_STOP_REVIEW = 1,
    TN_RESUME_REVIEW = 2
} tn_advisory;

typedef enum {
    TN_DISABLED = 0,
    TN_BAD_CLOCK,
    TN_NO_OWNER,
    TN_UNPLUGGED,
    TN_BAD_TEMPERATURE,
    TN_STOP_REACHED,
    TN_RECOVERED,
    TN_STEADY
} tn_reason;

typedef struct {
    tn_advisory advisory;
    tn_reason reason;
    int latched;
} tn_stop_decision;

typedef struct {
    tn_stop_config config;
    int latched;
    int has_last_now;
    double last_now;
    int has_last_sample_at;
    double last_sample_at;
} tn_stop_state;

/* Default is disabled: stop 42 C, resume 37 C, freshness 15 s. */
tn_stop_config tn_stop_default_config(void);
/* Returns 1 if valid, 0 otherwise. No state change on failed init. */
int tn_stop_config_valid(const tn_stop_config *config);
/* config=NULL uses defaults. Resets all history on success. */
int tn_stop_init(tn_stop_state *state, const tn_stop_config *config);
/* Returns 1 on success; 0 on null arguments (no state change). */
int tn_stop_step(tn_stop_state *state, const tn_stop_sample *sample,
                 tn_stop_decision *decision);
const char *tn_stop_advisory_name(tn_advisory advisory);
const char *tn_stop_reason_name(tn_reason reason);

#ifdef __cplusplus
}
#endif
#endif
