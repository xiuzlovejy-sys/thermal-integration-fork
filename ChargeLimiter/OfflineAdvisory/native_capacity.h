#ifndef NATIVE_CAPACITY_H
#define NATIVE_CAPACITY_H
#ifdef __cplusplus
extern "C" {
#endif

/* C99 offline capacity-ceiling advice. No I/O, charging APIs or device writes.
 * A held latch is internal policy memory, never a verified hardware state.
 * Boolean inputs are 0/1; optional fields use has_* (not sentinel values).
 * Strings in the returned decision are static and must not be freed.
 */
typedef struct {
    int enabled;
    int max_percent;
    int resume_percent;
    double max_age_s;
} nc_config;

typedef struct {
    double now;
    int has_sampled_at;
    double sampled_at;
    int has_percent;
    double percent;
    int plugged;
    const char *ownership; /* NULL means unknown; only "ours" is exclusive */
    int thermal_safe;       /* validated external safety arbitration only */
} nc_sample;

typedef struct {
    int held;
    int has_last_now;
    double last_now;
    int has_last_sample_at;
    double last_sample_at;
} nc_policy;

typedef struct {
    const char *suggestion; /* none / stop-review / resume-review */
    const char *reason;
    int held;
    int has_age_s;
    double age_s;
    const char *evidence; /* always unverified (mock only) */
} nc_decision;

nc_config nc_default_config(void);
/* Returns 1 if valid, 0 otherwise; rejects invalid booleans and thresholds. */
int nc_config_valid(const nc_config *config);
void nc_policy_init(nc_policy *policy);
/* Caller must pass initialized policy and valid config; returns 0 for bad args/config.
 * On error neither state nor decision is modified. */
int nc_step(nc_policy *policy, const nc_config *config,
            const nc_sample *sample, nc_decision *decision);
#ifdef __cplusplus
}
#endif
#endif
