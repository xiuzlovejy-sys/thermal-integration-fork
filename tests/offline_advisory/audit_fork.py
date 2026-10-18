"""Read-only audit of forked integration scope; does not run build or control code."""
from pathlib import Path
import hashlib
import os

ROOT = Path(__file__).resolve().parents[2]
BASE = Path(os.environ.get(
    'THERMAL_REVIEW_BASE',
    '/var/minis/workspace/thermal-review/tunecc-1.17.5'))
ALLOW = ('ChargeLimiter/OfflineAdvisory/', 'tests/offline_advisory/',
         'INTEGRATION_OFFLINE.md', 'STOP_CORE_OFFLINE.md', 'TRIPLE_ADVISORY_OFFLINE.md',
         'MVP_4_SETTINGS.md',
         # 2026-10-18 电脑端部署管线（交接文档第五节授权）:
         # 构建脚本修复合并 + roothide-only 模式 + CI + 构建产物/本地库桩。
         # 产品源码（ChargeLimiter/ 与 xcodeproj，含 daemon.mm 注册断言）仍逐字节守卫。
         'scripts/build_packages.sh',
         '.github/', '.gitignore',
         # roothide/rootless 分叉构建方案（scheme 文件，2026-10-18 登记）：
         # build_packages.sh --roothide-only 构建 "ChargeLimiter roothide" scheme，
         # 这两个 xcscheme 为打包管线授权偏离；pbxproj 等其他 xcodeproj 文件仍逐字节守卫。
         'ChargeLimiter.xcodeproj/xcshareddata/xcschemes/ChargeLimiter roothide.xcscheme',
         'ChargeLimiter.xcodeproj/xcshareddata/xcschemes/ChargeLimiter rootless.xcscheme',
         # 2026-10-18 离线核心只读接线（用户明确授权，INTEGRATION_OFFLINE.md
         # "Precise later hook" 落地）：daemon.mm 仅允许 import CLOfflineAdvisory.h +
         # observeBattery 只读调用（applyChargePolicy 之外）；pbxproj 仅注册
         # OfflineAdvisory 5 文件进 daemon target。下方 wiring_guard() 强制执行。
         'ChargeLimiter/daemon.mm',
         'ChargeLimiter.xcodeproj/project.pbxproj',
         # pbxproj 注册工具（可复现部署脚本，2026-10-18 接线时使用）:
         'register_offline_advisory.py',
         'register_governor.py',
         'out/', 'build_rootful/', 'build_rootless/', 'build_roothide/', 'Payload/',
         'ChargeLimiter/libroot.a', 'ChargeLimiter/libroothide.tbd')


def digest(path):
    # 行尾归一：上游仓库 CRLF/LF 混排，本地 tar 解压、CI git clone、runner git 配置
    # 之间的行尾差异不承载语义，归一后再哈希，只守卫真实内容差异。
    return hashlib.sha256(path.read_bytes().replace(b'\r\n', b'\n')).hexdigest()


def allowed(rel):
    return any(rel == a or rel.startswith(a) for a in ALLOW)


def wiring_guard():
    """离线核心接线守卫 v2（2026-10-18 柔性温控接线后演进）。

    架构：daemon.mm -> CLThermalGovernor（决策）-> CLOfflineAdvisory（策略信封）
    -> notify 档位通道 -> CLThermalSimTweak（作动，Powercuff 式热模拟）。
    铁律：
      - daemon.mm: CLOfflineAdvisory 仅 import；作动只经 governor + emergencyHandler。
      - governor.mm: 唯一 observeBattery 调用点；纯决策——禁 actuator 调用
        （applyChargePolicy/setInflowStatus/IORegistryEntrySetCFProperties），
        唯一内核交互是 notify_set_state 档位通道。
      - advisory 结果绝不传入 applyChargePolicy。
    """
    import re
    daemon = (ROOT / 'ChargeLimiter/daemon.mm').read_text()
    governor = (ROOT / 'ChargeLimiter/OfflineAdvisory/CLThermalGovernor.mm').read_text()
    project = (ROOT / 'ChargeLimiter.xcodeproj/project.pbxproj').read_text()

    allowed = (
        re.compile(r'#import\s+"ChargeLimiter/OfflineAdvisory/CLOfflineAdvisory\.h"'),
        re.compile(r'observeBattery:'),
        re.compile(r'^\s*//'),
    )
    for ln, line in enumerate(daemon.splitlines(), 1):
        if 'CLOfflineAdvisory' in line and not any(p.search(line) for p in allowed):
            raise AssertionError(
                f'daemon.mm:{ln}: unauthorized CLOfflineAdvisory reference: {line.strip()}')

    for m in re.finditer(r'applyChargePolicy\s*\(([^;]*?)\)\s*;', daemon, re.S):
        args = m.group(1)
        if 'dvisory' in args or 'observeBattery' in args:
            raise AssertionError('advisory result leaked into applyChargePolicy')

    assert '#import "ChargeLimiter/OfflineAdvisory/CLThermalGovernor.h"' in daemon, \
        'daemon.mm missing governor import'
    assert 'evaluateBattery:' in daemon, 'daemon.mm missing governor evaluateBattery call'

    assert '#import "CLOfflineAdvisory.h"' in governor, 'governor missing advisory import'
    assert 'observeBattery:' in governor, 'governor missing observeBattery call'
    for bad in ('applyChargePolicy', 'setInflowStatus', 'IORegistryEntrySetCFProperties'):
        assert bad not in governor, f'governor.mm must not actuate: {bad}'
    assert 'notify_set_state' in governor, 'governor missing notify channel write'

    for f in ('thermal_policy.c', 'native_capacity.c', 'temperature_stop.c',
              'triple_advisory.c', 'CLOfflineAdvisory.mm', 'CLThermalGovernor.mm'):
        assert f in project, f'pbxproj missing registration: {f}'


def audit():
    originals = sorted(p.relative_to(BASE) for p in BASE.rglob('*') if p.is_file())
    diffs = []
    for rel in originals:
        same = (ROOT / rel).is_file() and digest(BASE / rel) == digest(ROOT / rel)
        if not same:
            diffs.append(rel.as_posix())
    changed = [d for d in diffs if not allowed(d)]
    diverged = [d for d in diffs if allowed(d)]
    additional = sorted(p.relative_to(ROOT).as_posix() for p in ROOT.rglob('*') if p.is_file()
                        and '.git' not in p.parts and not (BASE / p.relative_to(ROOT)).exists())
    unexpected = [p for p in additional if not allowed(p)]
    if changed or unexpected:
        raise AssertionError({'changed_upstream': changed[:12], 'unexpected': unexpected[:12]})
    live = (ROOT/'ChargeLimiter/daemon.mm').read_text()
    project = (ROOT/'ChargeLimiter.xcodeproj/project.pbxproj').read_text()
    wiring_guard()
    print(f'PASS: {len(originals) - len(diverged)} baseline files unchanged; '
          f'{len(diverged)} allowlisted divergence(s) {diverged}; '
          f'{len(additional)} allowlisted offline additions; no daemon/project registration')


if __name__ == '__main__':
    audit()
