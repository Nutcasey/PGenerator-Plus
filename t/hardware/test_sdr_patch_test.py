"""Offline contracts for the hardware-only experiment; no device is contacted."""
import argparse
import random
import unittest

import sdr_patch_test as h


class ShadowContracts(unittest.TestCase):
    def setUp(self):
        self.curve=[round(i*32767/1023) for _ in range(3) for i in range(1024)]

    def test_changed_entries_stay_between_fixed_neighbours(self):
        rng=random.Random(42)
        current=self.curve
        for _ in range(100):
            current=h.localized_curve(self.curve,current,[rng.randint(-150,150) for _ in range(3)])
            self.assertEqual([v for i,v in enumerate(current) if not 19<i%1024<26],
                             [v for i,v in enumerate(self.curve) if not 19<i%1024<26])
            for channel in range(3):
                region=current[channel*1024+19:channel*1024+27]
                self.assertEqual(region,sorted(region))

    def test_bad_snapshot_and_outside_edit_are_rejected(self):
        for bad in (self.curve[:-1],self.curve+[0],[float(v) for v in self.curve]):
            with self.assertRaises(ValueError):h.validate_curve(bad)
        modified=list(self.curve);modified[30]+=1
        with self.assertRaises(ValueError):h.assert_preserved(self.curve,modified)
        modified=list(self.curve);modified[21]=0
        with self.assertRaises(ValueError):h.validate_curve(modified)

    def test_archived_result_uses_same_production_target_and_itp(self):
        value=h.production_math(84,{'X':.060084,'Y':.0631265,'Z':.067705},307.834057,'2.2')
        self.assertAlmostEqual(value['target_y'],.0617421460450506,places=12)
        self.assertAlmostEqual(value['delta_e'],.43369287648839,places=10)
        self.assertEqual(value['index'],21)

    def test_sample_average_uses_xyz_not_delta_e(self):
        self.assertEqual(h.mean_xyz([{'X':1,'Y':2,'Z':3},{'X':3,'Y':4,'Z':5}]),{'X':2,'Y':3,'Z':4})
        with self.assertRaises(ValueError):h.mean_xyz([])

    def test_failed_acquisition_cannot_stop_another_meter(self):
        harness=object.__new__(h.Harness)
        harness.claimed=False
        harness.api=lambda *args,**kwargs:self.fail('No device requests without ownership')
        harness.cleanup()

    def test_calibration_status_failure_still_restores_panel_protection(self):
        harness=object.__new__(h.Harness)
        harness.claimed=True
        harness.meter_owned=True
        harness.meter_uncertain=False
        harness.protection_pending=True
        calls=[]
        def api(path,payload=None,**kwargs):
            calls.append((path,payload))
            if path=='/api/lg/status':raise RuntimeError('TV status unavailable')
            return {'status':'ok'}
        harness.api=api
        harness.remote=lambda *_:'1'
        harness.save=lambda *args:None
        harness.event=lambda *args,**kwargs:None
        from io import StringIO
        harness.owner=argparse.Namespace(stdin=StringIO())
        with self.assertRaisesRegex(RuntimeError,'ownership retained'):
            harness.cleanup()
        self.assertIn(('/api/lg/panel-protection',{'enable':True}),calls)
        self.assertTrue(harness.claimed)
        self.assertFalse(harness.protection_pending)

    def test_live_context_uses_picture_settings_input_readback(self):
        harness=object.__new__(h.Harness)
        harness.idle=lambda:None
        harness.tv_input='hdmi4'
        harness.mode='cinema'
        harness.signal={key:None for key in h.SIGNAL_KEYS}
        response={'current_input':'hdmi4','picture_settings':{'pictureMode':'cinema'}}
        def api(path,payload=None,**kwargs):
            if path=='/api/config':return {}
            self.assertEqual(path,'/api/lg/picture-settings')
            self.assertTrue(payload['include_current_input'])
            return response
        harness.api=api
        harness.context()
        response['current_input']='hdmi1'
        with self.assertRaisesRegex(RuntimeError,'input changed'):harness.context()

    def test_existing_manual_meter_is_rejected_before_cleanup_ownership(self):
        harness=object.__new__(h.Harness)
        harness.remote=lambda *_:'busy'
        for status in ('starting','measuring','running','setup_busy','setup','ok'):
            harness.api=lambda *args,**kwargs:{'status':status}
            with self.assertRaises(RuntimeError):harness.meter_free()
        harness.remote=lambda *_:'free'
        harness.api=lambda *args,**kwargs:{'status':'idle'}
        harness.meter_free()

    def test_meter_retries_are_bounded_and_never_supply_fake_readings(self):
        harness=object.__new__(h.Harness)
        harness.event=lambda *args,**kwargs:None
        harness.condition=lambda:None
        harness.meter_free=lambda:None
        stops=[]
        harness.api=lambda *args,**kwargs:stops.append(args) or {'status':'ok'}
        attempts=[]
        def failed(code):
            attempts.append(code)
            raise h.ApiRejected('Meter session closed for clean retry')
        harness._measure_one=failed
        with self.assertRaises(h.ApiRejected):harness.measure_one(84)
        self.assertEqual(attempts,[84,84,84])
        self.assertEqual(len(stops),2)

    def test_rejection_and_transport_failure_have_distinct_ownership(self):
        harness=object.__new__(h.Harness)
        harness.guard=lambda:None
        harness.event=lambda *args,**kwargs:None
        harness.number=0
        harness.run='test'
        harness.meter={'display_type':'oled_generic','ccss_override':'fixture.ccss'}
        harness.meter_owned=False
        harness.meter_uncertain=False
        def rejected(*args,**kwargs):raise h.ApiRejected('Busy')
        harness.api=rejected
        with self.assertRaises(h.ApiRejected):harness._measure_one(84)
        self.assertFalse(harness.meter_owned)
        self.assertFalse(harness.meter_uncertain)
        def timed_out(*args,**kwargs):raise TimeoutError('Unknown acceptance')
        harness.api=timed_out
        with self.assertRaises(TimeoutError):harness._measure_one(84)
        self.assertFalse(harness.meter_owned)
        self.assertTrue(harness.meter_uncertain)

    def test_no_near_black_threshold_relaxation(self):
        # The production reference still computes the exact code-based target
        # at 2.3%; the experiment compares this number directly with < 0.2.
        target=.0617421460450506
        ideal={'X':target*.3127/.329,'Y':target,'Z':target*(1-.3127-.329)/.329}
        value=h.production_math(84,ideal,307.834057,'2.2')
        self.assertLess(value['delta_e'],1e-10)
        self.assertGreater(h.production_math(84,{k:v*1.1 for k,v in ideal.items()},307.834057,'2.2')['delta_e'],.2)


if __name__=='__main__':unittest.main()
