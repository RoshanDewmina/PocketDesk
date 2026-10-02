"""Safe fixtures only: no subprocesses, launchctl, installations or GUI operations."""
import importlib.util
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("domains", Path(__file__).resolve().parents[1] / "domains.py")
domains = importlib.util.module_from_spec(spec)
spec.loader.exec_module(domains)


class CleanupInventoryTests(unittest.TestCase):
    def test_exact_inventory_excludes_pid_views_and_other_blocks(self):
        text = "system = {\n subdomains = {\n pid/123\n user/501\n login/44\n gui/502\n }\n services = {\n gui/999\n }\n}"
        self.assertEqual(domains.children(text), ["user/501", "login/44", "gui/502"])

    def test_unknown_body_entries_never_certify_empty_inventory(self):
        for line in ["login/123 = {...}", "future/123", "gui/not-a-number"]:
            with self.subTest(line=line), self.assertRaises(ValueError):
                domains.children("subdomains = {\n " + line + "\n}\n")

    def test_absent_inventory_block_is_a_verification_failure(self):
        with self.assertRaises(ValueError):
            domains.children("Changed launchctl output format")


if __name__ == "__main__":
    unittest.main()
