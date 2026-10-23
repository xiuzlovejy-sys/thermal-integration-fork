#include "../ChargeLimiter/OfflineAdvisory/intermittent_policy.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned int assertions;
static uint64_t sessions;

static void check(int valid, const char *name) {
    assertions++;
    if (!valid) {
        fprintf(stderr, "FAIL %s\n", name);
        exit(1);
    }
}

static ic_config config(void) {
    ic_config value = {40, 36, 60, 90, 600, 15, 10};
    return value;
}

static ic_sample sample(double now, double temperature) {
    ic_sample value = {now, now, temperature, 1, 1, 1, 0, 1, 1, 1};
    return value;
}

static ic_policy fresh(void) {
    ic_policy policy = {0};
    ic_config settings = config();
    ic_sample first = sample(0, 30);
    ic_decision output;
    check(ic_init(&policy, &settings, ++sessions), "valid model initializes");
    check(ic_step(&policy, &first, &output), "first sample accepted");
    check(output.action == IC_NONE, "initialization does not write");
    return policy;
}

static ic_decision step(ic_policy *policy, double now, double temperature) {
    ic_sample input = sample(now, temperature);
    ic_decision output;
    check(ic_step(policy, &input, &output), "sample processed");
    return output;
}

static ic_policy cooling(void) {
    ic_policy policy = fresh();
    ic_decision output = step(&policy, 60, 40);
    check(output.action == IC_PROPOSE_STOP, "warm sample proposes pause");
    check(ic_ack(&policy, output.session_id, output.command_id, IC_CONFIRMED, 61), "stop confirmation accepted");
    check(policy.state == IC_COOLING && policy.owns_stop && policy.unresolved,
        "confirmed pause retains owned recovery obligation");
    return policy;
}

static void cycle_and_hysteresis(void) {
    ic_policy policy = fresh();
    ic_decision output = step(&policy, 59, 42);
    check(output.action == IC_NONE, "minimum run prevents premature pause");
    output = step(&policy, 60, 40);
    check(output.action == IC_PROPOSE_STOP && output.recovery_required, "pause emitted at threshold");
    uint64_t first = output.command_id;
    output = step(&policy, 62, 40);
    check(output.action == IC_NONE && policy.command_id == first, "pending pause is not repeated");
    check(ic_ack(&policy, output.session_id, first, IC_CONFIRMED, 63), "pause readback confirmed");
    output = step(&policy, 64, 34);
    check(output.action == IC_NONE, "minimum pause applies despite rapid cooling");
    output = step(&policy, 153, 37);
    check(output.action == IC_NONE, "hysteresis blocks release above cooling threshold");
    output = step(&policy, 154, 36);
    check(output.action == IC_PROPOSE_RELEASE_OWN && output.command_id > first,
        "cooled pause releases only its own ownership");
    output = step(&policy, 155, 36);
    check(output.action == IC_NONE, "pending release is not repeated");
    check(!ic_ack(&policy, policy.session_id, first, IC_CONFIRMED, 156), "old acknowledgment rejected");
    check(ic_ack(&policy, policy.session_id, policy.command_id, IC_CONFIRMED, 156), "release confirmed");
    check(policy.state == IC_OBSERVING && !policy.owns_stop && !policy.unresolved,
        "release confirmation clears only model ownership");
    output = step(&policy, 215, 41);
    check(output.action == IC_NONE, "new minimum run starts at confirmed release");
    output = step(&policy, 216, 41);
    check(output.action == IC_PROPOSE_STOP, "later warm cycle can propose pause");
}

static void arbitration(void) {
    ic_policy policy = cooling();
    ic_sample input = sample(62, 35);
    ic_decision output;
    input.enabled = 0;
    check(ic_step(&policy, &input, &output), "disable processed");
    check(output.action == IC_PROPOSE_RELEASE_OWN, "user disable bypasses minimum hold for own release");
    check(ic_ack(&policy, output.session_id, output.command_id, IC_ACCEPTED_UNVERIFIED, 63),
        "accepted but unverified release recorded");
    check(policy.state == IC_SUSPENDED && policy.owns_stop && policy.unresolved,
        "unknown release never becomes restored");

    policy = cooling();
    input = sample(62, 30);
    input.higher_priority_stop = 1;
    input.enabled = 0;
    ic_step(&policy, &input, &output);
    check(output.action == IC_REVIEW_RECOVERY && output.recovery_required,
        "higher priority stop vetoes even disabled release");
    check(policy.owns_stop, "arbitration does not silently drop own recovery record");
    output = step(&policy, 100, 30);
    check(output.action == IC_NONE && output.recovery_required, "suspended model does not auto-rearm");

    policy = cooling();
    input = sample(62, 30);
    input.external_power = 0;
    ic_step(&policy, &input, &output);
    check(output.action == IC_REVIEW_RECOVERY && policy.state == IC_SUSPENDED,
        "unplugged owned pause hands off instead of forcing charging");

    policy = fresh();
    input = sample(60, 42);
    input.ownership_exclusive = 0;
    ic_step(&policy, &input, &output);
    check(output.action == IC_REVIEW_RECOVERY && !output.recovery_required,
        "foreign ownership prevents any new pause");
}

static void acknowledgments(void) {
    for (int result = IC_ACCEPTED_UNVERIFIED; result <= IC_FAILED; result++) {
        ic_policy policy = fresh();
        ic_decision output = step(&policy, 60, 41);
        check(ic_ack(&policy, output.session_id, output.command_id, (ic_result)result, 61), "nonconfirmed result accepted");
        check(policy.state == IC_SUSPENDED && policy.unresolved && !policy.owns_stop,
            "ambiguous or failed pause preserves unresolved journal");
        output = step(&policy, 80, 30);
        check(output.action == IC_NONE && output.recovery_required, "no blind recovery rewrite");
    }
    ic_policy policy = fresh();
    ic_decision output = step(&policy, 60, 41);
    check(!ic_ack(&policy, output.session_id, output.command_id, IC_CONFIRMED, 59), "backdated acknowledgment rejected");
    output = step(&policy, 70, 41);
    check(output.action == IC_REVIEW_RECOVERY && policy.unresolved, "timeout stops issuing commands");
    check(!ic_ack(&policy, policy.session_id, policy.command_id, IC_CONFIRMED, 71), "late acknowledgment after timeout rejected");
    policy = fresh();
    output = step(&policy, 60, 41);
    check(ic_ack(&policy, output.session_id, output.command_id, IC_CONFIRMED, 70), "deadline acknowledgment classified");
    check(policy.state == IC_SUSPENDED, "acknowledgment at deadline cannot resurrect command");
}

static void input_faults(void) {
    for (int fault = 0; fault < 7; fault++) {
        ic_policy policy = cooling();
        ic_sample input = sample(80, 30);
        ic_decision output;
        if (fault == 0) input.sampled_at = 60;
        if (fault == 1) input.sampled_at = NAN;
        if (fault == 2) input.sampled_at = 81;
        if (fault == 3) input.temperature_c = NAN;
        if (fault == 4) input.temperature_valid = 0;
        if (fault == 5) input.temperature_c = 100;
        if (fault == 6) input.now = 60;
        ic_step(&policy, &input, &output);
        check(output.action == IC_REVIEW_RECOVERY && output.recovery_required,
            "invalid inputs suspend without a resume write");
    }
    ic_policy policy = cooling();
    ic_sample repeated = sample(62, 30);
    repeated.sampled_at = 60;
    ic_decision output;
    ic_step(&policy, &repeated, &output);
    check(output.action == IC_REVIEW_RECOVERY, "fresh-age but repeated sample rejected");
    policy = cooling();
    output = step(&policy, 661, 40);
    check(output.action == IC_REVIEW_RECOVERY && policy.owns_stop,
        "maximum pause raises unresolved recovery without overriding hot condition");
    for (int condition = 0; condition < 2; condition++) {
        policy = fresh();
        ic_sample input = sample(60, 42);
        input.recovery_ready = condition == 0 ? 0 : 1;
        input.controls_known_clear = condition == 1 ? 0 : 1;
        ic_step(&policy, &input, &output);
        check(policy.state == IC_SUSPENDED && output.action == IC_REVIEW_RECOVERY,
            "missing journal or control verification prevents new stop");
        check(!output.recovery_required, "no invented ownership when stop was not issued");
    }
}

static void invalid_configuration(void) {
    ic_policy policy = fresh();
    ic_policy previous = policy;
    ic_config settings = config();
    settings.resume_c = settings.stop_c;
    check(!ic_init(&policy, &settings, ++sessions), "invalid hysteresis rejected");
    check(memcmp(&policy, &previous, sizeof policy) == 0, "failed init preserves existing policy");
    settings = config();
    settings.min_pause_s = settings.max_pause_s;
    check(!ic_init(&policy, &settings, ++sessions), "invalid pause limits rejected");
    check(!ic_ack(&policy, policy.session_id, 1, IC_CONFIRMED, 2), "unsolicited acknowledgment rejected");
}

static void interrupted_sessions(void) {
    ic_policy policy = fresh();
    ic_decision old = step(&policy, 60, 40);
    step(&policy, 70, 40);
    ic_policy previous = policy;
    ic_config settings = config();
    check(!ic_init(&policy, &settings, ++sessions), "reinitialization cannot erase unresolved obligation");
    check(memcmp(&policy, &previous, sizeof policy) == 0, "rejected reinitialization preserves journal state");
    ic_policy next = fresh();
    ic_decision current = step(&next, 60, 40);
    check(current.command_id == old.command_id && current.session_id != old.session_id,
        "new session distinguishes same sequence number");
    check(!ic_ack(&next, old.session_id, old.command_id, IC_CONFIRMED, 61),
        "late previous-session acknowledgment rejected");
    check(next.state == IC_WAIT_STOP && next.unresolved, "old session cannot confirm new stop");

    for (int disabled = 0; disabled < 2; disabled++) {
        ic_policy idle = {0};
        check(ic_init(&idle, &settings, ++sessions), "idle session initializes");
        ic_sample input = sample(0, 40);
        input.external_power = disabled ? 1 : 0;
        input.enabled = disabled ? 0 : 1;
        ic_decision output;
        ic_step(&idle, &input, &output);
        check(output.action == IC_NONE, "idle session does not propose stop");
        output = step(&idle, 120, 40);
        check(output.action == IC_NONE, "unplugged or disabled time cannot satisfy minimum run");
        output = step(&idle, 179, 40);
        check(output.action == IC_NONE, "reactivated minimum run remains enforced");
        output = step(&idle, 180, 40);
        check(output.action == IC_PROPOSE_STOP, "reactivated session waits full minimum run");
    }

    for (int disabled = 0; disabled < 2; disabled++) {
        policy = fresh();
        current = step(&policy, 60, 40);
        ic_sample interrupted = sample(62, 40);
        interrupted.external_power = disabled ? 1 : 0;
        interrupted.enabled = disabled ? 0 : 1;
        ic_decision output;
        ic_step(&policy, &interrupted, &output);
        check(output.action == IC_REVIEW_RECOVERY && policy.unresolved,
            "power or enable change during pending stop remains unresolved");
        check(!ic_ack(&policy, current.session_id, current.command_id, IC_CONFIRMED, 63),
            "late stop confirmation cannot erase interruption");
        output = step(&policy, 64, 40);
        check(output.action == IC_NONE && policy.state == IC_SUSPENDED,
            "reconnection never silently resumes interrupted session");
    }
}

int main(void) {
    cycle_and_hysteresis();
    arbitration();
    acknowledgments();
    input_faults();
    invalid_configuration();
    interrupted_sessions();
    printf("PASS %u intermittent policy assertions; no hardware executor linked\n", assertions);
    return 0;
}
