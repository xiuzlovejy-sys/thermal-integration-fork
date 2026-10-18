#!/usr/bin/env python3
"""Source-only isolation and fail-closed contract checks."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / 'ChargeLimiter/OfflineAdvisory'

class TripleContract(unittest.TestCase):
    def test_wiring_readonly(self):
        """2026-10-18 接线后演进（取代 test_no_wiring）。

        daemon.mm 不直接引用 triple_advisory（经 CLThermalGovernor 间接）；
        pbxproj 注册 triple_advisory.c 于 daemon target（只读决策链的一环）。
        """
        self.assertNotIn('triple_advisory', (ROOT / 'ChargeLimiter/daemon.mm').read_text())
        self.assertIn('triple_advisory.c', (ROOT / 'ChargeLimiter.xcodeproj/project.pbxproj').read_text())

    def test_pure_c_and_external_gate(self):
        h = (CORE / 'triple_advisory.h').read_text()
        c = (CORE / 'triple_advisory.c').read_text()
        self.assertIn('external_safety_verified', h)
        self.assertRegex(c, r'cs\.thermal_safe\s*=\s*in->external_safety_verified\s*==\s*1\s*&&\s*valid')
        for raw, final in (('TN_RESUME_REVIEW', 'TA_EXACT_RESUME_REVIEW'),
                           ('"resume-review"', 'TA_CAPACITY_RESUME_REVIEW'),
                           ('s->gradual.level != TP_OFF', 'TA_GRADUAL_RELEASE_REVIEW')):
            self.assertRegex(c, r'in->external_safety_verified\s*==\s*1\s*&&[\s\S]{0,150}' +
                             re.escape(raw) + r'[\s\S]{0,100}' + re.escape(final))
        for txt in (h, c):
            self.assertNotRegex(txt, r'#\s*include\s*[<"](?:stdio|unistd|sys/|IOKit|UIKit|Foundation)')
            self.assertNotRegex(txt, r'\b(?:open|fopen|write|printf|setChargeStatus|setInflowStatus|notify_post|applyChargePolicy)\s*\(')
        for symbol in ('tp_step(', 'tn_stop_step(', 'nc_step(', 'ta_init(', 'ta_step('):
            self.assertIn(symbol, c)
        for fragment in ('c.gradual_enabled = 0', 'tn_stop_default_config()',
                         'nc_default_config()', 'if (!owner)', 'else if (!valid)',
                         'same_config(&s->config, &s->initialized_config)'):
            self.assertIn(fragment, c)

if __name__ == '__main__':
    unittest.main()
