#ifndef TRIPLE_ADVISORY_H
#define TRIPLE_ADVISORY_H
/* Pure C99 offline review hints. No charging state is observed or changed.
 * Supply monotonic seconds and explicit ownership; never infer ownership.
 * Reinitialize with ta_init after ANY settings change (history is reset).
 * State/output must not overlap. No global mutable state or I/O. */
#include "thermal_policy.h"
#include "native_capacity.h"
#include "temperature_stop.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
    int gradual_enabled; /* default 0; exact stop and capacity also default 0 */
    tp_config gradual;
    tn_stop_config exact;
    nc_config capacity;
} ta_config;
typedef struct {
    double now;
    int has_temp, has_temp_sampled_at;
    double temp_c, temp_sampled_at;
    int has_percent, has_percent_sampled_at;
    double percent, percent_sampled_at;
    int plugged, paused, system_critical;
    int external_safety_verified; /* explicit caller assertion; default 0, NOT inferred */
    tp_ownership ownership; /* TP_OURS required for every hint */
} ta_input;
typedef enum {
    TA_NONE=0, TA_SYSTEM_STOP_REVIEW, TA_EMERGENCY_STOP_REVIEW,
    TA_EXACT_STOP_REVIEW, TA_CAPACITY_STOP_REVIEW,
    TA_GRADUAL_REVIEW, TA_EXACT_RESUME_REVIEW,
    TA_CAPACITY_RESUME_REVIEW, TA_GRADUAL_RELEASE_REVIEW
} ta_hint;
typedef enum {
    TA_STEADY=0, TA_BAD_CLOCK, TA_NO_OWNER, TA_INACTIVE,
    TA_SYSTEM_BLOCK, TA_EMERGENCY_BLOCK, TA_BAD_TEMPERATURE,
    TA_EXACT_BLOCK, TA_CAPACITY_BLOCK, TA_GRADUAL_BLOCK
} ta_reason;
typedef struct {
    ta_hint hint; /* single highest priority review hint, never a command */
    ta_reason reason;
    int temperature_valid;
    int exact_latched, capacity_held;
    tp_level gradual_level;
    /* Raw subdecisions are diagnostic ONLY: never interpret as permissions. */
    tp_decision gradual;
    tn_stop_decision exact;
    nc_decision capacity;
} ta_output;
typedef struct {
    ta_config config;
    ta_config initialized_config; /* immutable snapshot; direct config edits rejected */
    tp_policy gradual;
    tn_stop_state exact;
    nc_policy capacity;
    int has_last_now;
    double last_now;
    int has_last_temp_at;
    double last_temp_at;
} ta_state;
ta_config ta_default_config(void);
int ta_config_valid(const ta_config *config);
/* Invalid init/step leaves state and output unmodified. */
int ta_init(ta_state *state, const ta_config *config); /* NULL config: defaults */
int ta_step(ta_state *state, const ta_input *input, ta_output *output);
#ifdef __cplusplus
}
#endif
#endif
