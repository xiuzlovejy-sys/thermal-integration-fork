set -eu
test_base="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
if [ "$#" -ne 1 ]; then
    printf 'Usage: sh run-tests.sh /absolute/output/directory\n' >&2
    exit 2
fi
case "$1" in
    /*) test_output="$1" ;;
    *) printf 'Output directory must be absolute\n' >&2; exit 2 ;;
esac
test_prefix="${test_base%/usr/lib/jycharge-powercuff-loader-test}"
if [ "$test_prefix" = "$test_base" ]; then
    printf 'Run this script only from its installed package directory\n' >&2
    exit 2
fi
test_framework="$test_prefix/usr/lib/libellekit.dylib"
for test_file in "$test_base/host" "$test_base/controller" "$test_base/observer.dylib" "$test_framework"; do
    if [ ! -f "$test_file" ]; then
        printf 'Required file missing: %s\n' "$test_file" >&2
        exit 1
    fi
done
mkdir -p "$test_output"
for test_scenario in immediate delayed early absent; do
    printf 'Running dynamic scenario: %s\n' "$test_scenario"
    if "$test_base/host" "$test_framework" "$test_base/observer.dylib" \
        "$test_base/controller" "$test_scenario" > "$test_output/$test_scenario.log" 2>&1; then
        cat "$test_output/$test_scenario.log"
    else
        test_exit=$?
        cat "$test_output/$test_scenario.log"
        printf 'Scenario failed: %s (exit %s); later scenarios were not run\n' \
            "$test_scenario" "$test_exit" >&2
        exit "$test_exit"
    fi
done
