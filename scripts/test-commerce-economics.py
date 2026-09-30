import json
import importlib.util
import math
import pathlib
import sys
import unittest
spec = importlib.util.spec_from_file_location('economics', pathlib.Path(__file__).with_name('commerce-economics.py'))
m = importlib.util.module_from_spec(spec); sys.modules[spec.name] = m; spec.loader.exec_module(m)
class EconomicsTests(unittest.TestCase):
    def test_charged_egress_units_and_relay_fraction(self):
        self.assertAlmostEqual(m.Scenario(8, 20, 1).monthly_cost(), 3.6)
        self.assertAlmostEqual(m.Scenario(8, 20, .5).monthly_cost(), 1.8)
        self.assertEqual(m.Scenario(8, 20, 0).monthly_cost(), 0)
    def test_full_unmetered_tail_has_no_finite_undiscounted_cap(self):
        self.assertTrue(math.isinf(m.perpetual_tail(1)))
        self.assertTrue(math.isinf(m.perpetual_tail(1, .05, .05)))
        self.assertEqual(m.perpetual_tail(1, .05), 240)
        self.assertGreater(m.tail_cost(1, 40), m.tail_cost(1, 20))
    def test_heavy_tail_exceeds_lifetime_candidate_and_recurring_plans(self):
        cost = m.Scenario(16, 80, 1).monthly_cost()
        self.assertGreater(cost, m.net_usd(7.99, 1.35, .15))
        self.assertGreater(m.tail_cost(cost, 10), m.net_usd(199, 1.35, .15))
    def test_prepared_lifetime_and_founder_are_full_unmetered_not_live(self):
        record = json.loads(pathlib.Path(__file__).parents[1].joinpath('Docs/launch/PREPARED-LIFETIME-OFFERS.json').read_text())
        self.assertFalse(record['live'])
        self.assertEqual([x['kind'] for x in record['offers']], ['lifetime', 'founder_lifetime'])
        for offer in record['offers']:
            self.assertEqual(offer['billing'], 'one_time')
            self.assertTrue(offer['unmetered_remote_access'])
            self.assertIsNone(offer['usage_hour_cap']); self.assertIsNone(offer['relay_quota'])
            self.assertIsNone(offer['price']); self.assertIsNone(offer['storekit_product_id'])
    def test_invalid_inputs_never_create_plausible_margin(self):
        for fx in (0, -1, math.nan):
            with self.assertRaises(ValueError): m.net_usd(199, fx, .15)
        with self.assertRaises(ValueError): m.Scenario(8, 20, 1.1).monthly_cost()
        with self.assertRaises(ValueError): m.Scenario(math.nan, 20, .5).monthly_cost()
if __name__ == '__main__': unittest.main()
