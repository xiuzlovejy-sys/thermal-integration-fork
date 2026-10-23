set -eu
cd "$(dirname "$0")/.."
probe_output="${CLPC_APPLE_OUTPUT:-PowercuffProbe/apple-minimal}"
mkdir -p "$probe_output"
probe_cxx="$(xcrun --sdk iphoneos --find clang++)"
probe_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
{
    "$probe_cxx" --version
    xcrun --sdk iphoneos --show-sdk-version
    printf 'compiler=%s\nsdk=%s\ntarget=arm64e-apple-ios15.0\n' "$probe_cxx" "$probe_sdk"
} > "$probe_output/toolchain.txt"
"$probe_cxx" -target arm64e-apple-ios15.0 -isysroot "$probe_sdk" \
    -fobjc-arc -std=c++17 -c tests/powercuff_abi_fixture.mm \
    -o "$probe_output/fixture.o" > "$probe_output/compile.log" 2>&1
probe_gate=0
python3 scripts/check_arm64e_objc_metadata.py "$probe_output/fixture.o" \
    --json "$probe_output/metadata.json" > "$probe_output/metadata.log" 2>&1 || probe_gate=$?
printf '%s\n' "$probe_gate" > "$probe_output/gate-exit.txt"
if [ "$probe_gate" -ne 0 ]; then
    cat "$probe_output/metadata.log"
    printf 'ABI check failed; diagnostics retained in %s\n' "$probe_output"
    exit "$probe_gate"
fi
"$probe_cxx" -target arm64e-apple-ios15.0 -isysroot "$probe_sdk" \
    -fobjc-arc -std=c++17 -framework Foundation \
    tests/powercuff_arm64e_load_check.mm "$probe_output/fixture.o" \
    -o "$probe_output/minimal-arm64e" > "$probe_output/link.log" 2>&1
printf 'Cross-build complete: %s; not signed or executed\n' "$probe_output/minimal-arm64e"
