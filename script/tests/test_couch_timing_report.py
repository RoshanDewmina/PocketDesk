import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('couch_timing', Path(__file__).parents[1] / 'couch_timing_report.py')
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


class CouchTimingReportTests(unittest.TestCase):
    def test_overlapping_prefixes_match_the_original_callback_arrival(self):
        r = report.summarize(report.parse([
            'couchTiming stage=arrival key=a.b.7 applied=1 first=1 send=100 uncertainty=2 arrival=104 main=105 lane=pointer',
            'couchTiming stage=arrival key=a.b.7 applied=2 first=1 send=110 uncertainty=2 arrival=114 main=115 lane=pointer',
            'couchTiming stage=post key=a.b.7 applied=1 sourceArrival=104 at=116 end=116.2 accepted=1',
        ]))
        self.assertEqual(r['arrivalToPost']['p50Ms'], 12)
        self.assertEqual(r['sendToPost']['p50Ms'], 16)

    def test_orphan_and_duplicate_arrivals_are_counted_without_latency(self):
        r = report.summarize(report.parse([
            'couchTiming stage=post key=orphan applied=1 sourceArrival=104 at=106 end=106.2 accepted=1',
            'couchTiming stage=arrival key=duplicate applied=1 first=1 send=100 uncertainty=2 arrival=104 main=105 lane=pointer',
            'couchTiming stage=arrival key=duplicate applied=1 first=1 send=100 uncertainty=2 arrival=104 main=105 lane=pointer',
            'couchTiming stage=post key=duplicate applied=1 sourceArrival=104 at=106 end=106.2 accepted=1',
        ]))
        self.assertEqual(r['unmatchedOrAmbiguousPosts'], 2)
        self.assertEqual(r['arrivalToPost']['n'], 0)

    def test_correlated_gaps_separate_network_and_host_queue_jitter(self):
        rows = report.parse([
            'couchTiming stage=arrival key=a.b.7 applied=1 first=1 send=100 uncertainty=2 arrival=104 main=105 lane=pointer',
            'couchTiming stage=post key=a.b.7 applied=1 sourceArrival=104 at=106 end=106.2 accepted=1',
            'couchTiming stage=arrival key=a.b.7 applied=2 first=2 send=110 uncertainty=2 arrival=119 main=120 lane=pointer',
            'couchTiming stage=post key=a.b.7 applied=2 sourceArrival=119 at=126 end=126.3 accepted=1',
        ])
        r = report.summarize(rows)
        self.assertEqual(r['arrivalJitterVsSendGap']['p90Ms'], 5)
        self.assertEqual(r['postJitterVsSendGap']['p90Ms'], 10)
        self.assertEqual(r['arrivalToPost']['p90Ms'], 7)
        self.assertEqual(r['sendToArrival']['p50Ms'], 4)
        self.assertEqual(r['clockUncertainty']['p90Ms'], 2)

    def test_missing_clock_retries_retired_keys_and_idle_do_not_invent_jitter(self):
        rows = report.parse([
            'couchTiming stage=arrival key=a.b.7 applied=1 first=1 send=-1 uncertainty=-1 arrival=104 main=105 lane=pointer',
            'couchTiming stage=post key=a.b.7 applied=1 sourceArrival=104 at=106 end=106.2 accepted=1',
            'couchTiming stage=arrival key=a.b.7 applied=1 first=1 send=100 uncertainty=2 arrival=107 main=108 lane=reliable',
            'couchTiming stage=arrival key=a.c.7 applied=2 first=2 send=110 uncertainty=2 arrival=114 main=115 lane=pointer',
            'couchTiming stage=arrival key=a.c.7 applied=3 first=3 send=310 uncertainty=2 arrival=314 main=315 lane=pointer',
            'couchTiming stage=post key=a.b.7 applied=2 sourceArrival=114 at=116 end=116.2 accepted=1',
        ])
        r = report.summarize(rows)
        self.assertEqual(r['arrivalJitterVsSendGap']['n'], 0)
        self.assertIsNone(r['postJitterVsSendGap']['p50Ms'])
        self.assertEqual(r['arrivalToPost']['n'], 1)
        self.assertEqual(r['sendToPost']['n'], 0)

    def test_json_numeric_phone_stages_and_permission_costs(self):
        rows = report.parse([
            json.dumps({'eventMessage': 'couchTiming stage=touch sample=100 callback=103 samples=2'}),
            'couchTiming stage=pump offer=103 at=111 actions=2',
            'couchTiming stage=permission api=post at=110 end=110.5 granted=1',
            'couchTiming stage=permission api=AX at=111 end=nan granted=1',
        ])
        r = report.summarize(rows)
        self.assertEqual(r['phoneTouchToCallback']['p50Ms'], 3)
        self.assertEqual(r['phoneOfferToSend']['p90Ms'], 8)
        self.assertEqual(r['permissionCost']['post']['p50Ms'], .5)
        self.assertNotIn('AX', r['permissionCost'])


if __name__ == '__main__':
    unittest.main()
