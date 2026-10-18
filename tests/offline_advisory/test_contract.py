#!/usr/bin/env python3
"""Portable source-contract checks; no iOS SDK or app execution needed."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / 'ChargeLimiter/OfflineAdvisory/CLOfflineAdvisory.mm'
HEADER = ADAPTER.with_suffix('.h')
DAEMON = ROOT / 'ChargeLimiter/daemon.mm'
PROJECT = ROOT / 'ChargeLimiter.xcodeproj/project.pbxproj'

class OfflineContract(unittest.TestCase):
    def test_fork_is_wired_readonly(self):
        """2026-10-18 接线后演进（取代 test_fork_is_unwired）。

        INTEGRATION_OFFLINE.md "Precise later hook" 落地：daemon 侧只读观察桥。
        允许：import + observeBattery 调用；禁止：actuator 路径与 app 侧注册。
        v2（柔性温控）：daemon 经 CLThermalGovernor 决策，observeBattery 移居
        governor.mm；daemon.mm 持 import governor.h + evaluateBattery: 调用。
        """
        d = DAEMON.read_text()
        p = PROJECT.read_text()
        g = (ROOT / 'ChargeLimiter/OfflineAdvisory/CLThermalGovernor.mm').read_text()
        self.assertIn('#import "ChargeLimiter/OfflineAdvisory/CLOfflineAdvisory.h"', d)
        self.assertIn('#import "ChargeLimiter/OfflineAdvisory/CLThermalGovernor.h"', d)
        self.assertIn('evaluateBattery:', d)
        self.assertIn('observeBattery:', g)
        for m in re.finditer(r'applyChargePolicy\s*\(([^;]*?)\)\s*;', d, re.S):
            args = m.group(1)
            self.assertNotIn('dvisory', args)
            self.assertNotIn('observeBattery', args)
        for f in ('thermal_policy.c', 'native_capacity.c', 'temperature_stop.c',
                  'triple_advisory.c', 'CLOfflineAdvisory.mm', 'CLThermalGovernor.mm'):
            self.assertIn(f, p)

    def test_no_side_effects_or_actuator_link(self):
        text = ADAPTER.read_text()
        self.assertIn('#if !CL_OFFLINE_ADVISORY_DRY_RUN', text)
        self.assertIn('CL_OFFLINE_ADVISORY_ENABLE_WRITES', text)
        self.assertIn('CL_OFFLINE_ADVISORY_APPLY_CHARGE_POLICY', text)
        self.assertNotRegex(text, r'\b(?:applyChargePolicy|setProperties|notify_post|notify_set_state|setLocal\w*|IORegistryEntrySetCFProperties|setChargeStatus|setInflowStatus)\s*\(')
        self.assertNotRegex(text, r'\b(?:dlopen|dlsym|performSelector|NSClassFromString)\s*\(')
        self.assertIn('cs.thermal_safe = 0', text)
        self.assertIn('ownership_verified": @NO', text)
        self.assertIn('physical_state_verified": @NO', text)
        self.assertIn('dry_run": @YES', text)
        self.assertIn('actuator_available": @NO', text)
        self.assertIn('CLKnownKeys(settings', text)
        self.assertIn('nc_config_valid(cc)', text)
        self.assertIn('tp_init(&scratch, tc)', text)
        self.assertIn('CLKnownKeys(t,', text)
        self.assertIn('CLKnownKeys(c,', text)
        self.assertIn('hasStamp = CLNumber(sampleAt)', text)
        self.assertNotRegex(text, r'\[b\[@"UpdateTime"\]')
        self.assertIn('CL_OFFLINE_ADVISORY_DRY_RUN 1', HEADER.read_text())

    def test_fixed_upstream_observation_fields(self):
        d = DAEMON.read_text()
        for key in ('CurrentCapacity', 'Temperature', 'ExternalConnected', 'ExternalChargeCapable', 'UpdateTime'):
            self.assertIn('@"'+key+'"', d)
        self.assertRegex(d, r'temperature_\.intValue / 100\.0')
        self.assertRegex(d, r'static void onBatteryEvent\(io_service_t serv\)')
        self.assertRegex(d, r'static void refreshBatteryStateAndApplyPolicy\(void\)')

if __name__ == '__main__':
    unittest.main()
