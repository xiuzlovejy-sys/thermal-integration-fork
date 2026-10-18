#!/usr/bin/env python3
"""Register CLThermalGovernor (.mm compiled in 3 daemon targets, .h as group member)."""
import sys

PATH = 'ChargeLimiter.xcodeproj/project.pbxproj'
src = open(PATH, encoding='utf-8').read()
if 'CLThermalGovernor.mm' in src:
    sys.exit('already registered, aborting')

MM_UUID = '2A43498E4FC44DF0A8347601'
H_UUID = '2A43498E4FC44DF0A8347602'
BF_BASE = '2A43498E4FC44DF0A834761'   # 7611/7612/7613 for 3 targets
GROUP_UUID = '2A43498E4FC44DF0A8347500'  # existing OfflineAdvisory group

# 1. PBXBuildFile x3 (mm in 3 daemon targets)
anchor = ('\t\t18C123CB2C8C08CB00FAAC6C /* daemon.mm in Sources */ = '
          '{isa = PBXBuildFile; fileRef = 187886422B51976B00E48B28 /* daemon.mm */; };\n')
assert anchor in src
bf = ''.join(
    f'\t\t{BF_BASE}{i} /* CLThermalGovernor.mm in Sources */ = {{isa = PBXBuildFile; '
    f'fileRef = {MM_UUID} /* CLThermalGovernor.mm */; }};\n' for i in range(1, 4))
src = src.replace(anchor, anchor + bf, 1)

# 2. PBXFileReference x2 (mm + h), after daemon.mm fileRef
anchor = ('\t\t187886422B51976B00E48B28 /* daemon.mm */ = {isa = PBXFileReference; '
          'lastKnownFileType = sourcecode.cpp.objcpp; path = daemon.mm; sourceTree = "<group>"; };\n')
assert anchor in src
fr = (f'\t\t{MM_UUID} /* CLThermalGovernor.mm */ = {{isa = PBXFileReference; '
      f'lastKnownFileType = sourcecode.cpp.objcpp; path = CLThermalGovernor.mm; sourceTree = "<group>"; }};\n'
      f'\t\t{H_UUID} /* CLThermalGovernor.h */ = {{isa = PBXFileReference; '
      f'lastKnownFileType = sourcecode.c.h; path = CLThermalGovernor.h; sourceTree = "<group>"; }};\n')
src = src.replace(anchor, anchor + fr, 1)

# 3. OfflineAdvisory group children += 2 (after triple_advisory.c member)
anchor = '\t\t\t\t2A43498E4FC44DF0A8347505 /* triple_advisory.c */,\n'
assert anchor in src
src = src.replace(anchor, anchor +
                  f'\t\t\t\t{MM_UUID} /* CLThermalGovernor.mm */,\n'
                  f'\t\t\t\t{H_UUID} /* CLThermalGovernor.h */,\n', 1)

# 4. three daemon sources phases += mm buildFile (after each phase's own triple line)
import re
for idx, tgt in enumerate(('18C123E82C8C09A400FAAC6C', '18C123CB2C8C08CB00FAAC6C',
                           '2A43498E4FC44DF0A8347461'), 1):
    dm = f'\t\t\t\t{tgt} /* daemon.mm in Sources */,\n'
    assert src.count(dm) == 1
    pos = src.index(dm)
    m = re.search(r'\t\t\t\t[0-9A-F]{24} /\* triple_advisory\.c in Sources \*/,\n',
                  src[pos:pos + 2000])
    assert m, f'triple line missing near {tgt}'
    insert_pos = pos + m.end()
    u = f'{BF_BASE}{idx}'
    src = (src[:insert_pos]
           + f'\t\t\t\t{u} /* CLThermalGovernor.mm in Sources */,\n'
           + src[insert_pos:])

open(PATH, 'w', encoding='utf-8', newline='').write(src)
print('registered CLThermalGovernor: 3 buildFiles, 2 fileRefs, 2 group members, 3 phase updates')
