#!/usr/bin/env python3
"""Register OfflineAdvisory 5 files into the three daemon targets (NOT the app target).

pbxproj edits (idempotent-ish; anchors are unique strings):
  1. PBXBuildFile x15 (5 files x 3 daemon targets)
  2. PBXFileReference x5 (new OfflineAdvisory group members)
  3. PBXGroup: new OfflineAdvisory group + attach to ChargeLimiter group children
  4. PBXSourcesBuildPhase x3: 5 buildFile refs each (the 3 phases containing daemon.mm)
UUIDs use the unused 2A43498E4FC44DF0A83475xx series. LF endings preserved.
"""
import re
import sys

PATH = 'ChargeLimiter.xcodeproj/project.pbxproj'
src = open(PATH, encoding='utf-8').read()
if 'CLOfflineAdvisory.mm' in src:
    sys.exit('already registered, aborting')

FILES = [  # (filename, filetype)
    ('CLOfflineAdvisory.mm', 'sourcecode.cpp.objcpp'),
    ('thermal_policy.c', 'sourcecode.c.c'),
    ('native_capacity.c', 'sourcecode.c.c'),
    ('temperature_stop.c', 'sourcecode.c.c'),
    ('triple_advisory.c', 'sourcecode.c.c'),
]
GROUP_UUID = '2A43498E4FC44DF0A8347500'
def fileref(i): return f'2A43498E4FC44DF0A834750{i}'          # 501..505
def buildfile(i): return f'2A43498E4FC44DF0A83475{i:02d}'     # 511..525 (15)

# --- 1. PBXBuildFile x15: insert after the first daemon.mm buildFile line ---
anchor = ('\t\t18C123CB2C8C08CB00FAAC6C /* daemon.mm in Sources */ = '
          '{isa = PBXBuildFile; fileRef = 187886422B51976B00E48B28 /* daemon.mm */; };\n')
assert anchor in src, 'buildfile anchor missing'
bf_lines = []
n = 11
for tgt in range(3):                       # three daemon targets
    for name, _ in FILES:
        u = buildfile(n)
        bf_lines.append(f'\t\t{u} /* {name} in Sources */ = {{isa = PBXBuildFile; '
                        f'fileRef = {fileref(1 + FILES.index((name, _)))} /* {name} */; }};\n')
        n += 1
src = src.replace(anchor, anchor + ''.join(bf_lines), 1)

# --- 2. PBXFileReference x5: insert after daemon.mm fileRef line ---
anchor = ('\t\t187886422B51976B00E48B28 /* daemon.mm */ = {isa = PBXFileReference; '
          'lastKnownFileType = sourcecode.cpp.objcpp; path = daemon.mm; sourceTree = "<group>"; };\n')
assert anchor in src, 'fileref anchor missing'
fr_lines = []
for i, (name, ftype) in enumerate(FILES, 1):
    fr_lines.append(f'\t\t{fileref(i)} /* {name} */ = {{isa = PBXFileReference; '
                    f'lastKnownFileType = {ftype}; path = {name}; sourceTree = "<group>"; }};\n')
src = src.replace(anchor, anchor + ''.join(fr_lines), 1)

# --- 3. PBXGroup: attach new OfflineAdvisory group into ChargeLimiter group children ---
anchor = '\t\t\t\t187886422B51976B00E48B28 /* daemon.mm */,\n'
assert anchor in src, 'group children anchor missing'
children = ''.join(f'\t\t\t\t{fileref(i)} /* {name} */,\n' for i, (name, _) in enumerate(FILES, 1))
new_group = (f'\t\t{GROUP_UUID} /* OfflineAdvisory */ = {{isa = PBXGroup; children = (\n'
             + children +
             f'\t\t\t); path = OfflineAdvisory; sourceTree = "<group>"; }};\n')
# place group definition right before the ChargeLimiter group definition line
# (multi-line format: UUID /* ChargeLimiter */ = {\n\t\t\tisa = PBXGroup;)
grp_anchor = '\t\t1878862F2B51976A00E48B28 /* ChargeLimiter */ = {\n'
assert grp_anchor in src, 'ChargeLimiter group definition missing'
src = src.replace(grp_anchor, new_group + grp_anchor, 1)
# and add the group itself as a child of ChargeLimiter group (next to daemon.mm entry)
src = src.replace(anchor,
                  anchor + f'\t\t\t\t{GROUP_UUID} /* OfflineAdvisory */,\n', 1)

# --- 4. PBXSourcesBuildPhase x3: add 5 buildFile refs after each daemon.mm-in-Sources line ---
phase_anchors = [
    '\t\t\t\t18C123E82C8C09A400FAAC6C /* daemon.mm in Sources */,\n',
    '\t\t\t\t18C123CB2C8C08CB00FAAC6C /* daemon.mm in Sources */,\n',
    '\t\t\t\t2A43498E4FC44DF0A8347461 /* daemon.mm in Sources */,\n',
]
assert src.count('\t\t\t\t18C123E82C8C09A400FAAC6C /* daemon.mm in Sources */,\n') == 1
assert src.count('\t\t\t\t18C123CB2C8C08CB00FAAC6C /* daemon.mm in Sources */,\n') == 1
assert src.count('\t\t\t\t2A43498E4FC44DF0A8347461 /* daemon.mm in Sources */,\n') == 1
for tgt, anchor in enumerate(phase_anchors):
    block = []
    for k in range(5):
        u = buildfile(11 + tgt * 5 + k)
        name = FILES[k][0]
        block.append(f'\t\t\t\t{u} /* {name} in Sources */,\n')
    src = src.replace(anchor, anchor + ''.join(block), 1)

open(PATH, 'w', encoding='utf-8', newline='').write(src)
print('registered: 15 buildFiles, 5 fileRefs, 1 group, 3 phase updates')
