#!/usr/bin/env python3
"""Patch Jikan 1.0.2 so it prefers the external ETA from Jy's charge.

Jikan estimates from InstantAmperage; under our soft-PWM the battery current is a
0 <-> 3A square wave, so its estimate is badly biased. Jy's charge computes
rate = amp * duty and exposes it at POST http://127.0.0.1:1230 {"api":"status"}.

Usage: patch_tt100.py <path to Tweak/TT100/TT100.m>
Idempotent: exits 0 if already patched.
"""
import sys

MARKER = "JYS_EXTERNAL_ETA"

IMPORT_ANCHOR = '#import "TT100.h"\n'
IMPORT_LINE = '#import "TT100ExternalEstimate.h"  // JYS_EXTERNAL_ETA\n'

TIME_ANCHOR = "NSString *timeString = [TT100HistoryEstimator formattedTimeForSeconds:remainingSeconds];\n"

EXTERNAL_BLOCK = """
\t\t\t// JYS_EXTERNAL_ETA: 优先使用 Jy's charge 的外部估算（已显式乘 PWM 占空比）。
\t\t\t// Jikan 的瞬时电流估算在软 PWM 下会看到 0↔3A 方波，严重失真。
\t\t\t[TT100ExternalEstimate refreshIfNeeded];
\t\t\tNSDictionary *jysExternal = [TT100ExternalEstimate cachedEstimate];
\t\t\tBOOL jysUsingExternal = NO;
\t\t\tif (jysExternal != nil) {
\t\t\t\tNSInteger jysEtaMin = [jysExternal[@"eta_min"] integerValue];
\t\t\t\tNSString *jysEtaState = jysExternal[@"eta_state"];
\t\t\t\tif (jysEtaMin > 0 &&
\t\t\t\t    ![jysEtaState isEqualToString:@"at_target"] &&
\t\t\t\t    ![jysEtaState isEqualToString:@"unplugged"]) {
\t\t\t\t\tremainingSeconds = (double)jysEtaMin * 60.0;
\t\t\t\t\ttimeString = [TT100HistoryEstimator formattedTimeForSeconds:remainingSeconds];
\t\t\t\t\tjysUsingExternal = YES;
\t\t\t\t}
\t\t\t}
"""

HAS_ESTIMATE_ANCHOR = (
    'if (!appleResult) hasEstimate = ![timeString isEqualToString:'
    'JikanLocalizedString(@"jikan.tt100.value.na", @"N/A")];\n'
)
HAS_ESTIMATE_PATCH = HAS_ESTIMATE_ANCHOR + "\t\t\tif (jysUsingExternal) hasEstimate = YES;  // JYS_EXTERNAL_ETA\n"

STATUS_ANCHOR = '@"estimateStatus": appleResult[@"status"] ?: (hasEstimate ? @"available" : @"unavailable"),'
STATUS_PATCH = ('@"estimateStatus": jysUsingExternal ? @"external" : '
                '(appleResult[@"status"] ?: (hasEstimate ? @"available" : @"unavailable")),'
                '  // JYS_EXTERNAL_ETA')


def die(msg):
    print(f"[patch] ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def main():
    if len(sys.argv) != 2:
        die("usage: patch_tt100.py <Tweak/TT100/TT100.m>")
    path = sys.argv[1]
    with open(path, "r", encoding="utf-8", newline="") as f:
        raw = f.read()

    # 保留原始换行风格，避免整文件 diff（源码可能是 CRLF）。
    newline = "\r\n" if "\r\n" in raw else "\n"
    src = raw.replace("\r\n", "\n")

    if MARKER in src:
        print("[patch] already patched, nothing to do")
        return

    for name, anchor in (("import", IMPORT_ANCHOR), ("timeString", TIME_ANCHOR),
                         ("hasEstimate", HAS_ESTIMATE_ANCHOR), ("estimateStatus", STATUS_ANCHOR)):
        if src.count(anchor) != 1:
            die(f"anchor '{name}' not found exactly once (Jikan version mismatch?)")

    src = src.replace(IMPORT_ANCHOR, IMPORT_ANCHOR + IMPORT_LINE, 1)
    src = src.replace(TIME_ANCHOR, TIME_ANCHOR + EXTERNAL_BLOCK, 1)
    src = src.replace(HAS_ESTIMATE_ANCHOR, HAS_ESTIMATE_PATCH, 1)
    src = src.replace(STATUS_ANCHOR, STATUS_PATCH, 1)

    out = src.replace("\n", newline)
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(out)
    print("[patch] TT100.m patched (external ETA preferred)")


if __name__ == "__main__":
    main()
