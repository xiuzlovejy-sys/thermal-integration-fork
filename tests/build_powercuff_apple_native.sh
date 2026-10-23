set -eu
cd "$(dirname "$0")/.."
probe_output="${CLPC_APPLE_NATIVE_OUTPUT:-probe/native-checks}"
mkdir -p "$probe_output"
probe_cxx="$(xcrun --sdk iphoneos --find clang++)"
probe_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
{
    "$probe_cxx" --version
    xcrun --sdk iphoneos --show-sdk-version
    git -C "$THEOS" rev-parse HEAD
    git -C "$THEOS" submodule status vendor/logos vendor/include vendor/lib
} > "$probe_output/toolchain.txt"
perl "$THEOS/vendor/logos/bin/logos.pl" -c generator=MobileSubstrate \
    PowercuffProbe/CLPowercuffProbe.xm > "$probe_output/CLPowercuffProbe.mm"
for probe_apply in 0 1; do
    "$probe_cxx" -target arm64e-apple-ios15.0 -isysroot "$probe_sdk" \
        -fobjc-arc -std=c++17 -framework Foundation -DCLPC_TESTING=1 \
        -DCLPC_ENABLE_APPLY="$probe_apply" -Wl,-dead_strip_dylibs \
        -I"$THEOS/vendor/include" -F"$THEOS/vendor/lib" -IPowercuffProbe \
        "$probe_output/CLPowercuffProbe.mm" tests/powercuff_probe_native.mm \
        -x objective-c++ PowercuffProbe/CLPowercuffCore.m \
        -o "$probe_output/probe-check-arm64e-$probe_apply" \
        > "$probe_output/compile-$probe_apply.log" 2>&1
done
printf 'Built arm64e observer/fake receiver tests; not signed or executed\n'
