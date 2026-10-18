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
         'out/', 'build_rootful/', 'build_rootless/', 'build_roothide/', 'Payload/',
         'ChargeLimiter/libroot.a', 'ChargeLimiter/libroothide.tbd')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def allowed(rel):
    return any(rel == a or rel.startswith(a) for a in ALLOW)


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
    assert 'CLOfflineAdvisory' not in live and 'triple_advisory' not in live
    assert 'CLOfflineAdvisory' not in project and 'triple_advisory' not in project
    print(f'PASS: {len(originals) - len(diverged)} baseline files unchanged; '
          f'{len(diverged)} allowlisted divergence(s) {diverged}; '
          f'{len(additional)} allowlisted offline additions; no daemon/project registration')


if __name__ == '__main__':
    audit()
