set -eu
cd "$(dirname "$0")/.."
test_output="ChargeLimiter/.theos/intermittent-policy"
mkdir -p "$test_output"
clang-16 -target arm64-apple-ios15.0 \
    -isysroot "${CA_THEOS_SDKROOT:-$THEOS/sdks/iPhoneOS16.5.sdk}" \
    -std=c11 -Wall -Wextra -Werror \
    ChargeLimiter/OfflineAdvisory/intermittent_policy.c tests/intermittent_policy_test.c \
    -o "$test_output/policy-test"
ldid -SChargeLimiter/ChargeLimiter.entitlements "$test_output/policy-test"
"$test_output/policy-test"
