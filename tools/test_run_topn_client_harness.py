#!/usr/bin/env python3

from contextlib import redirect_stderr
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


MODULE_PATH = Path(__file__).with_name("run_topn_client_harness.py")
SPEC = importlib.util.spec_from_file_location("run_topn_client_harness", MODULE_PATH)
assert SPEC and SPEC.loader
HARNESS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HARNESS)


class RelayReadinessTests(unittest.TestCase):
    def test_reports_failure_after_all_health_checks_fail(self) -> None:
        result = mock.Mock(returncode=1)
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(HARNESS.subprocess, "run", return_value=result):
            ready = HARNESS.wait_for_relay(Path("/tmp/relay_health_check"), "moq://127.0.0.1:33435",
                                           Path(directory) / "health.log", attempts=3)

        self.assertFalse(ready)

    def test_stops_after_the_first_successful_health_check(self) -> None:
        failures_then_success = [mock.Mock(returncode=1), mock.Mock(returncode=0)]
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            HARNESS.subprocess, "run", side_effect=failures_then_success
        ) as run:
            ready = HARNESS.wait_for_relay(Path("/tmp/relay_health_check"), "moq://127.0.0.1:33435",
                                           Path(directory) / "health.log", attempts=3)

        self.assertTrue(ready)
        self.assertEqual(run.call_count, 2)


class DevelopmentTeamTests(unittest.TestCase):
    def test_accepts_an_apple_team_identifier(self) -> None:
        self.assertEqual(HARNESS.development_team("A1B2C3D4E5"), "A1B2C3D4E5")

    def test_rejects_a_value_that_could_be_interpreted_as_a_build_setting(self) -> None:
        with self.assertRaises(HARNESS.argparse.ArgumentTypeError):
            HARNESS.development_team("TEAM OTHER=value")

    def test_redacts_sensitive_arguments_from_metadata(self) -> None:
        argv = ["runner", "--development-team", "A1B2C3D4E5", "--fault={\"id\":\"x\"}",
                "DEVELOPMENT_TEAM=A1B2C3D4E5"]

        self.assertEqual(HARNESS.recorded_argv(argv),
                         ["runner", "--development-team", "<redacted>", "--fault=<redacted>",
                          "DEVELOPMENT_TEAM=<redacted>"])


class RelayURITests(unittest.TestCase):
    def test_rejects_userinfo(self) -> None:
        with self.assertRaises(ValueError):
            HARNESS.validate_relay_uri("moq://user:password@relay.example:33435")

    def test_rejects_query_or_fragment_credentials(self) -> None:
        for uri in ("moq://relay.example:33435?access_token=SECRET",
                    "moq://relay.example:33435#access_token=SECRET"):
            with self.subTest(uri=uri), self.assertRaises(ValueError):
                HARNESS.validate_relay_uri(uri)


class RunnerFailureTests(unittest.TestCase):
    def test_finalises_metadata_and_removes_staging_after_infrastructure_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            results = root / "results"
            staging = root / "staging"
            argv = [str(MODULE_PATH), "--laps-binary", str(root / "missing-lapsRelay"),
                    "--results-root", str(results), "--no-qlog"]
            with mock.patch.object(HARNESS, "STAGING_ROOT", staging), mock.patch.object(sys, "argv", argv):
                with redirect_stderr(io.StringIO()):
                    status = HARNESS.main()

            self.assertEqual(status, 2)
            run_directory = next(results.iterdir())
            metadata = json.loads((run_directory / "run.json").read_text(encoding="utf-8"))
            self.assertEqual(metadata["outcomeClass"], "infrastructure")
            self.assertIn("must be executable", metadata["failure"]["message"])
            self.assertEqual(list(staging.iterdir()), [])

    def test_finalises_metadata_after_subprocess_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            results = root / "results"
            staging = root / "staging"
            argv = [str(MODULE_PATH), "--results-root", str(results), "--no-qlog"]
            failure = HARNESS.subprocess.CalledProcessError(1, ["openssl"])
            with mock.patch.object(HARNESS, "STAGING_ROOT", staging), \
                    mock.patch.object(HARNESS, "run_full_run", side_effect=failure), \
                    mock.patch.object(sys, "argv", argv), redirect_stderr(io.StringIO()):
                status = HARNESS.main()

            self.assertEqual(status, 2)
            run_directory = next(results.iterdir())
            metadata = json.loads((run_directory / "run.json").read_text(encoding="utf-8"))
            self.assertEqual(metadata["outcomeClass"], "infrastructure")
            self.assertIsNotNone(metadata["endedAt"])
            self.assertEqual(list(staging.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
