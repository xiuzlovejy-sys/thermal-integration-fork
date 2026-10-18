"""Register CLButlerViewController.h/.m into the three app targets.

Mirrors the existing CLMainViewController.m entries (same group, same three
Sources phases, same 3 PBXBuildFile pattern). Idempotent: aborts if already
registered. pbxproj is a guarded file, so the edit is minimal and verifiable.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PBX = ROOT / 'ChargeLimiter.xcodeproj' / 'project.pbxproj'

HEADER = 'CLButlerViewController.h'
IMPL = 'CLButlerViewController.m'
BUILD_PREFIX = '2A43498E4FC44DF0A83477'

src = PBX.read_text(encoding='utf-8')
assert IMPL not in src, 'already registered'

# Existing anchor: CLMainViewController.m build-file entries reveal the app phases.
anchor_build_ids = re.findall(
    r'\t\t([0-9A-F]{24}) /\* CLMainViewController\.m in Sources \*/ = \{isa = PBXBuildFile;',
    src)
assert len(anchor_build_ids) == 3, f'expected 3 app phases, got {len(anchor_build_ids)}'

# 1. File references
header_ref = BUILD_PREFIX + '01'
impl_ref = BUILD_PREFIX + '02'
for uid in (header_ref, impl_ref):
    assert uid not in src, f'UUID collision {uid}'

ref_lines = (
    f'\t\t{header_ref} /* {HEADER} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; '
    f'path = {HEADER}; sourceTree = "<group>"; }};\n'
    f'\t\t{impl_ref} /* {IMPL} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.c.objc; '
    f'path = {IMPL}; sourceTree = "<group>"; }};\n'
)
marker = '/* End PBXFileReference section */'
src = src.replace(marker, ref_lines + marker, 1)

# 2. Build files (one per app target phase)
build_ids = []
for i, _ in enumerate(anchor_build_ids):
    uid = BUILD_PREFIX + f'1{i + 1}'
    assert uid not in src, f'UUID collision {uid}'
    build_ids.append(uid)
build_lines = ''.join(
    f'\t\t{uid} /* {IMPL} in Sources */ = {{isa = PBXBuildFile; fileRef = {impl_ref} /* {IMPL} */; }};\n'
    for uid in build_ids)
marker = '/* End PBXBuildFile section */'
src = src.replace(marker, build_lines + marker, 1)

# 3. Group membership: UIKit group (path = "UIKit") —— 不能放 Controllers 子组，
#    否则 path 相对 Controllers/ 解析，构建时报文件不存在。
group_anchor = '\t\t\t\tA720B97A2F2F0995008B9C91 /* CLUIKit.h */,\n'
assert src.count(group_anchor) == 1, 'UIKit group anchor missing'
src = src.replace(
    group_anchor,
    group_anchor
    + f'\t\t\t\t{header_ref} /* {HEADER} */,\n'
    + f'\t\t\t\t{impl_ref} /* {IMPL} */,\n',
    1)

# 4. Sources phases: after each CLMainViewController.m entry
for anchor_build, new_build in zip(anchor_build_ids, build_ids):
    entry = f'\t\t\t\t{anchor_build} /* CLMainViewController.m in Sources */,\n'
    assert src.count(entry) == 1, f'phase anchor missing for {anchor_build}'
    src = src.replace(
        entry,
        entry + f'\t\t\t\t{new_build} /* {IMPL} in Sources */,\n',
        1)

assert src.count('{') == src.count('}'), 'brace mismatch'
assert src.count('(') == src.count(')'), 'paren mismatch'
PBX.write_bytes(src.encode('utf-8'))  # 字节写入：write_text 在 Windows 会把 \n 翻成 \r\n
print(f'registered {HEADER} + {IMPL}')
print('refs:', header_ref, impl_ref)
print('build:', build_ids)
