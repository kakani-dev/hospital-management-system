#!/usr/bin/env python3
"""Tests for credential_rotation.py with fake az/gh (no network, synthetic values)."""
import base64, contextlib, hashlib, hmac, io, os, stat, sys, tempfile, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import credential_rotation as cr

TENANT = ".synthref"
def conn(user, pw):
    return f"Host=db.example.test;Port=6543;Database=postgres;Username={user};Password={pw};SSL Mode=Require;Pooling=true"

class Fake:
    def __init__(self):
        self.secrets = {}   # (app, secret) -> value
        self.gh = {}
    def run(self, cmd, stdin=None):
        if cmd[:3] == ["az", "containerapp", "secret"]:
            app = cmd[cmd.index("-n") + 1]; name = cmd[cmd.index("--secret-name") + 1]
            if (app, name) not in self.secrets: raise cr.RotationError("az failed")
            return self.secrets[(app, name)] + "\n"
        if cmd[:3] == ["gh", "secret", "set"]:
            self.gh[cmd[3]] = stdin; return ""
        raise AssertionError(cmd)

class RotationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        os.environ.update(ROTATION_DIR=self.tmp.name + "/w", RG="rg-test")
        self.fake = Fake(); self.orig = cr.run; cr.run = self.fake.run
        self.old_pw = "OLD-synthetic-pw"
        self.fake.secrets[("ca-hms-patients", "hms-db")] = conn("hms_patients_login" + TENANT, self.old_pw)
    def tearDown(self):
        cr.run = self.orig; self.tmp.cleanup()

    def call(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = cr.main(list(argv))
        return rc, out.getvalue() + err.getvalue()

    def assert_no_secret(self, text):
        self.assertNotIn(self.old_pw, text)
        for v in self.fake.gh.values():
            self.assertNotIn(v, text)
            for part in cr.parse_connstr(v):
                if part[0] == "Password": self.assertNotIn(part[1], text)

    def test_slot_alternation(self):
        self.assertEqual(cr.standby_of("hms_patients_login"), "hms_patients_login_b")
        self.assertEqual(cr.standby_of("hms_patients_login_b"), "hms_patients_login")
        self.assertEqual(cr.group_role("hms_patients_login_b"), "hms_svc_patients")

    def test_prepare_publish_retire_cycle(self):
        rc, out = self.call("prepare", "patients"); self.assertEqual(rc, 0, out)
        d = Path(os.environ["ROTATION_DIR"])
        self.assertEqual(stat.S_IMODE(d.stat().st_mode), 0o700)
        for f in d.iterdir(): self.assertEqual(stat.S_IMODE(f.stat().st_mode), 0o600)
        new = (d / "patients.connstr").read_text()
        pairs = dict(cr.parse_connstr(new))
        self.assertEqual(pairs["Username"], "hms_patients_login_b" + TENANT)
        self.assertNotEqual(pairs["Password"], self.old_pw)
        self.assertEqual(pairs["Host"], "db.example.test"); self.assertEqual(pairs["SSL Mode"], "Require")
        sql = (d / "patients.prepare.sql").read_text()
        self.assertNotIn(pairs["Password"], sql); self.assertIn("SCRAM-SHA-256$", sql)
        self.assertIn("hms_svc_patients", sql)
        # retire refuses while app still on old slot
        rc, out2 = self.call("retire", "patients"); self.assertEqual(rc, 1); self.assertIn("still uses", out2)
        rc, out3 = self.call("publish", "patients"); self.assertEqual(rc, 0, out3)
        self.assertEqual(self.fake.gh["HMS_DB_PATIENTS"], new)
        self.fake.secrets[("ca-hms-patients", "hms-db")] = new  # deploy rolled the app
        rc, out4 = self.call("retire", "patients"); self.assertEqual(rc, 0, out4)
        self.assertIn("alter role hms_patients_login nologin", (d / "patients.retire.sql").read_text())
        rc, out5 = self.call("status", "patients"); self.assertIn("slot b", out5)
        self.assert_no_secret(out + out2 + out3 + out4 + out5)
        rc, _ = self.call("cleanup"); self.assertFalse(d.exists())

    def test_second_rotation_goes_back_to_slot_a(self):
        self.fake.secrets[("ca-hms-patients", "hms-db")] = conn("hms_patients_login_b" + TENANT, self.old_pw)
        self.call("prepare", "patients")
        new = (Path(os.environ["ROTATION_DIR"]) / "patients.connstr").read_text()
        self.assertIn("Username=hms_patients_login" + TENANT + ";", new)

    def test_unknown_service_and_bad_role_refused(self):
        rc, out = self.call("prepare", "nosuch"); self.assertEqual(rc, 1)
        self.fake.secrets[("ca-hms-patients", "hms-db")] = conn("x; drop role y", "p")
        rc, out = self.call("prepare", "patients"); self.assertEqual(rc, 1)
        self.assertNotIn("drop role", out)

    def test_publish_requires_prepare(self):
        rc, _ = self.call("publish", "patients"); self.assertEqual(rc, 1)
        self.assertEqual(self.fake.gh, {})

    def test_scram_verifier_matches_rfc7677(self):
        v = cr.scram_verifier("pencil", base64.b64decode("W22ZaJ0SNY7soEsUEjb6gQ=="), 4096)
        self.assertEqual(v, "SCRAM-SHA-256$4096:W22ZaJ0SNY7soEsUEjb6gQ==$WG5d8oPm3OtcPnkdi4Uo7BkeZkBFzpcXkuLmtbsT4qY=:wfPLwcE6nTWhTAmQ7tl2KeoiWGPlZqQxSrmfPwDl2dU=")

    def test_edge_prepare_and_retire(self):
        self.fake.secrets[("ca-hms-edge", "hms-edge-key")] = "LIVE-synthetic-key"
        rc, out = self.call("edge-prepare"); self.assertEqual(rc, 0, out)
        self.assertEqual(self.fake.gh["HMS_EDGE_KEY_PREVIOUS"], "LIVE-synthetic-key")
        self.assertNotEqual(self.fake.gh["HMS_EDGE_KEY"], "LIVE-synthetic-key")
        self.fake.secrets[("ca-hms-edge", "hms-edge-key")] = self.fake.gh["HMS_EDGE_KEY"]
        rc, out2 = self.call("edge-retire"); self.assertEqual(rc, 0)
        self.assertEqual(self.fake.gh["HMS_EDGE_KEY_PREVIOUS"], self.fake.gh["HMS_EDGE_KEY"])
        for t in (out, out2):
            self.assertNotIn("LIVE-synthetic-key", t); self.assertNotIn(self.fake.gh["HMS_EDGE_KEY"], t)

if __name__ == "__main__":
    unittest.main()
