"""The deployment handshake: polling, parsing and the fail-closed checks."""

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from lab.deploy import await_record, record_path, ssh_command, verify_record

FAKE_SSH = str(Path("tests/fake/deploy-ssh").resolve())
DIGEST = "sha256:" + "1" * 64
DEPLOYMENT = "0f0e0d0c-0b0a-4a19-8a7b-6c5d4e3f2a10"


class FakeSsh:
    def __init__(self, after=1, role="dns", digest=DIGEST):
        self.dir = tempfile.mkdtemp()
        self.count_file = os.path.join(self.dir, "count")
        self.env = {
            "LAB_DEPLOY_SSH": FAKE_SSH,
            "FAKE_DEPLOY_COUNT": self.count_file,
            "FAKE_DEPLOY_AFTER": str(after),
            "FAKE_DEPLOY_ROLE": role,
            "FAKE_DEPLOY_DIGEST": digest,
        }

    def calls(self):
        try:
            return int(Path(self.count_file).read_text().strip())
        except FileNotFoundError:
            return 0

    def __enter__(self):
        self._patch = mock.patch.dict(os.environ, self.env, clear=False)
        self._patch.start()
        return self

    def __exit__(self, *exc):
        self._patch.stop()


class TestSshCommand(unittest.TestCase):
    def test_default_names_the_lab_key(self):
        command = ssh_command()
        self.assertIn("-i", command)
        key = command[command.index("-i") + 1]
        self.assertTrue(key.endswith("lab-secrets/id_ed25519"))

    def test_a_test_supplied_command_wins(self):
        with mock.patch.dict(os.environ, {"LAB_DEPLOY_SSH": "fakessh -q"}, clear=False):
            self.assertEqual(ssh_command(), ["fakessh", "-q"])

    def test_record_path_is_under_the_deployment_directory(self):
        self.assertEqual(
            record_path(DEPLOYMENT), f"/var/lib/ultus-corp/deployments/{DEPLOYMENT}.json"
        )


class TestAwaitRecord(unittest.TestCase):
    def test_polls_until_the_guest_records_the_deployment(self):
        with FakeSsh(after=3) as fake:
            record = await_record(
                "10.100.10.11", DEPLOYMENT, "dns", DIGEST, timeout=10, interval=0.01
            )
            self.assertEqual(record["id"], DEPLOYMENT)
            self.assertEqual(fake.calls(), 3, "the harness stopped polling too early")

    def test_a_malformed_record_does_not_end_the_wait(self):
        with FakeSsh(after=3) as fake:
            with mock.patch.dict(os.environ, {"FAKE_DEPLOY_GARBAGE": "1"}):
                record = await_record(
                    "10.100.10.11",
                    DEPLOYMENT,
                    "dns",
                    DIGEST,
                    timeout=10,
                    interval=0.01,
                )
            self.assertEqual(record["id"], DEPLOYMENT)
            self.assertEqual(fake.calls(), 3, "a non-JSON body ended the wait")

    def test_a_guest_that_never_records_fails_closed(self):
        with FakeSsh(after=99):
            with self.assertRaises(RuntimeError) as caught:
                await_record(
                    "10.100.10.11", DEPLOYMENT, "dns", DIGEST, timeout=0.05, interval=0.01
                )
        self.assertIn("no deployment record", str(caught.exception))
        self.assertIn(DEPLOYMENT, str(caught.exception))

    def test_a_record_for_another_role_is_refused_at_once(self):
        with FakeSsh(after=1, role="hub") as fake:
            with self.assertRaises(RuntimeError) as caught:
                await_record(
                    "10.100.10.11", DEPLOYMENT, "dns", DIGEST, timeout=10, interval=0.01
                )
        self.assertIn("expected dns", str(caught.exception))
        self.assertEqual(fake.calls(), 1, "a contract breach was polled past")

    def test_a_record_for_another_digest_is_refused_at_once(self):
        other = "sha256:" + "2" * 64
        with FakeSsh(after=1, digest=other) as fake:
            with self.assertRaises(RuntimeError) as caught:
                await_record(
                    "10.100.10.11", DEPLOYMENT, "dns", DIGEST, timeout=10, interval=0.01
                )
        self.assertIn(other, str(caught.exception))
        self.assertEqual(fake.calls(), 1, "a digest mismatch was polled past")


class TestVerifyRecord(unittest.TestCase):
    def record(self, **overrides):
        base = {
            "id": DEPLOYMENT,
            "image_digest": DIGEST,
            "role": "dns",
            "completed_at": "2026-11-27T00:00:00Z",
        }
        base.update(overrides)
        return base

    def test_a_matching_record_is_accepted(self):
        verify_record(self.record(), DEPLOYMENT, "dns", DIGEST)

    def test_a_missing_key_is_rejected(self):
        broken = self.record()
        del broken["completed_at"]
        with self.assertRaises(ValueError) as caught:
            verify_record(broken, DEPLOYMENT, "dns")
        self.assertIn("completed_at", str(caught.exception))

    def test_a_different_id_is_rejected(self):
        with self.assertRaises(ValueError):
            verify_record(self.record(), "11111111-1111-4111-8111-111111111111", "dns")

    def test_a_different_role_is_rejected(self):
        with self.assertRaises(ValueError):
            verify_record(self.record(), DEPLOYMENT, "hub")

    def test_a_different_digest_is_rejected(self):
        with self.assertRaises(ValueError):
            verify_record(
                self.record(), DEPLOYMENT, "dns", "sha256:" + "2" * 64
            )

    def test_a_record_is_json_round_trippable(self):
        text = json.dumps(self.record())
        verify_record(json.loads(text), DEPLOYMENT, "dns", DIGEST)


class TestDeploymentHistory(unittest.TestCase):
    def test_a_redeploy_adds_a_record_and_keeps_the_old_one(self):
        from lab import state as runstate

        state = runstate.new("s1-dns")
        first = {"id": DEPLOYMENT, "role": "dns"}
        second = {"id": "11111111-1111-4111-8111-111111111111", "role": "dns"}
        runstate.record_deployment(state, first)
        runstate.record_deployment(state, second)
        self.assertEqual(set(state["deployments"]), {first["id"], second["id"]})

    def test_an_old_state_file_gains_the_map(self):
        from lab import state as runstate

        state = {"schema": 1, "scenario": "s0-base", "nodes": {}, "resources": []}
        runstate.record_deployment(state, {"id": DEPLOYMENT})
        self.assertEqual(state["deployments"][DEPLOYMENT], {"id": DEPLOYMENT})


if __name__ == "__main__":
    unittest.main()
