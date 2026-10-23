set -eu
cd "$(dirname "$0")/.."
probe_output="probe/host-checks"
mkdir -p "$probe_output"
probe_cxx="$(xcrun --sdk iphoneos --find clang++)"
probe_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
perl "$THEOS/vendor/logos/bin/logos.pl" -c generator=MobileSubstrate \
    PowercuffProbe/CLPowercuffProbe.xm > "$probe_output/CLPowercuffProbe.mm"
"$probe_cxx" -target arm64e-apple-ios15.0 -isysroot "$probe_sdk" \
    -fobjc-arc -std=c++17 -framework Foundation -DCLPC_TESTING=0 \
    -DCLPC_HOST_TESTING=1 -DCLPC_ENABLE_APPLY=0 -dynamiclib \
    -Wl,-undefined,dynamic_lookup -Wl,-ignore_auto_link \
    -I"$THEOS/vendor/include" -IPowercuffProbe \
    "$probe_output/CLPowercuffProbe.mm" -x objective-c++ PowercuffProbe/CLPowercuffCore.m \
    -o "$probe_output/observer.dylib" > "$probe_output/observer-build.log" 2>&1
"$probe_cxx" -target arm64e-apple-ios15.0 -isysroot "$probe_sdk" \
    -fobjc-arc -std=c++17 -framework Foundation -DCLPC_TESTING=0 \
    -DCLPC_HOST_TESTING=1 -DCLPC_ENABLE_APPLY=0 \
    tests/powercuff_probe_host.mm -o "$probe_output/host" > "$probe_output/host-build.log" 2>&1
"$probe_cxx" -target arm64e-apple-ios15.0 -isysroot "$probe_sdk" \
    -fobjc-arc -framework Foundation -DCLPC_TESTING=0 \
    -DCLPC_HOST_TESTING=1 -DCLPC_ENABLE_APPLY=0 \
    PowercuffProbe/CLPowercuffProbeCtl.m -o "$probe_output/controller" \
    > "$probe_output/controller-build.log" 2>&1
printf 'Built production-entry observer, host and controller; not signed or executed\n'
