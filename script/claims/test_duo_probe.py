"""Runner safety checks with fabricated devices; never invokes native tools."""
import contextlib, io, json, pathlib, shutil, subprocess, sys, tempfile, unittest
from unittest.mock import patch
from duo_probe import probe
import simulators

class DuoProbeSafetyTests(unittest.TestCase):
    def exercise(self, boot=0, status=0, output='Boot complete', timeout=False):
        with tempfile.TemporaryDirectory() as folder:
            record=pathlib.Path(folder)/'result.json'; marker=pathlib.Path(folder)/'attempt.json'
            status_result=subprocess.CompletedProcess([],status,output)
            side=[subprocess.CompletedProcess([],boot)]
            if boot==0: side.append(subprocess.TimeoutExpired('fixture',180) if timeout else status_result)
            devices=json.dumps({'devices':{'fixture':[{'udid':'owned','state':'Booted'}]}})
            with patch('subprocess.run',side_effect=side) as native, patch('subprocess.check_output',return_value=devices), contextlib.redirect_stdout(io.StringIO()):
                code=probe('owned',record,marker)
                self.assertTrue(marker.exists())
                return code,json.loads(record.read_text()),native.call_count

    def testSuccessfulBoot(self):
        code,result,calls=self.exercise(); self.assertEqual((code,result['accepted'],calls),(0,True,2))
    def testZeroExitMigrationFailureCannotPass(self):
        code,result,calls=self.exercise(output='Data Migration Failed')
        self.assertEqual((code,result['accepted'],calls),(1,False,2))
    def testBootFailureStopsBeforeStatus(self):
        code,result,calls=self.exercise(boot=149); self.assertEqual((code,result['accepted'],calls),(1,False,1))
    def testStatusTimeoutFailsAndPreservesAttempt(self):
        code,result,calls=self.exercise(timeout=True); self.assertEqual((code,result['accepted'],calls),(124,False,2))
    def testAttemptCannotRepeat(self):
        with tempfile.TemporaryDirectory() as folder:
            marker=pathlib.Path(folder)/'attempt.json'; marker.write_text('{}')
            with patch('subprocess.run') as native, contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(probe('owned',pathlib.Path(folder)/'result.json',marker),1)
                native.assert_not_called()
    def testAlreadyBootedRefusesWithoutCleanup(self):
        source=(pathlib.Path(__file__).parent/'locked.py').read_text()
        devices=json.dumps({'devices':{'fixture':[{'udid':'owned','state':'Booted'}]}})
        with patch.object(sys,'argv',['locked.py','--shutdown-simulator','owned','--require-shutdown-simulator','fixture']), patch.object(simulators,'active_conflicts',return_value=[]), patch('pathlib.Path.exists',return_value=False), patch('pathlib.Path.glob',return_value=[]), patch.object(shutil,'disk_usage',return_value=shutil._ntuple_diskusage(100*1024**3,0,100*1024**3)), patch('subprocess.check_output',return_value=devices), patch('subprocess.call') as native, patch('subprocess.run') as cleanup, contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(SystemExit) as error: exec(compile(source,'locked.py','exec'),{'__name__':'__main__'})
            self.assertEqual(error.exception.code,79)
            native.assert_not_called(); cleanup.assert_not_called()

if __name__=='__main__': unittest.main()
