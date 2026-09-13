#!/usr/bin/env python3
"""Run the opt-in Catalyst top-N client harness."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parent.parent
STAGING_ROOT = Path.home() / "Downloads" / "QuicRTopNHarnessStaging"


def positive(value: str) -> float:
    number = float(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def positive_int(value: str) -> int:
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def development_team(value: str) -> str:
    if len(value) != 10 or not value.isascii() or not value.isalnum() or value.upper() != value:
        raise argparse.ArgumentTypeError("must be a 10-character uppercase Apple team identifier")
    return value


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture-preflight", action="store_true")
    parser.add_argument("--relay-uri")
    parser.add_argument("--laps-binary", type=Path)
    parser.add_argument("--port", type=positive_int, default=33435)
    parser.add_argument("--participants", type=positive_int, default=3)
    parser.add_argument("--top-n", type=positive_int, default=1)
    parser.add_argument("--filter-timeout-ms", type=positive_int, default=500)
    parser.add_argument("--join-policy", choices=("ngr", "fetch", "wait", "mixed"), default="ngr")
    parser.add_argument("--fetch-threshold-seconds", type=float)
    parser.add_argument("--new-group-threshold-seconds", type=float)
    parser.add_argument("--scenario", choices=("orderly", "overlap", "lifecycle", "abrupt-reconnect",
                                               "seeded", "round-robin", "lifecycle-conversation",
                                               "drop-idr-recovery"), default="orderly")
    parser.add_argument("--scenario-file", type=Path)
    parser.add_argument("--duration-seconds", type=positive, default=None)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--media-convergence-seconds", type=positive, default=10)
    parser.add_argument("--liveness-seconds", type=positive, default=2)
    parser.add_argument("--max-display-gap-seconds", type=positive, default=0.75)
    parser.add_argument("--lifecycle-seconds", type=positive, default=20)
    parser.add_argument("--diagnostic-drain-seconds", type=positive, default=1)
    parser.add_argument("--results-root", type=Path, default=Path(".topn-harness-results"))
    parser.add_argument("--derived-data-path", type=Path)
    parser.add_argument("--development-team", type=development_team)
    parser.add_argument("--no-test-diagnostics", action="store_true")
    parser.add_argument("--fault", action="append", default=[])
    parser.add_argument("--no-qlog", action="store_true")
    return parser


def fail(message: str) -> int:
    print(f"error: {message}", file=sys.stderr)
    return 2


def git_value(*args: str) -> str | None:
    try:
        return subprocess.check_output(["git", *args], cwd=ROOT, text=True, stderr=subprocess.DEVNULL).strip()
    except subprocess.CalledProcessError:
        return None


def sha256(path: Path) -> str | None:
    if not path.is_file():
        return None
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def git_identity(path: Path) -> dict[str, object]:
    try:
        revision = subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"],
                                           text=True, stderr=subprocess.DEVNULL).strip()
        dirty = bool(subprocess.check_output(["git", "-C", str(path), "status", "--porcelain"],
                                             text=True, stderr=subprocess.DEVNULL).strip())
        return {"path": str(path), "revision": revision, "dirty": dirty}
    except subprocess.CalledProcessError:
        return {"path": str(path), "available": False}


def laps_identity(args: argparse.Namespace) -> dict[str, object]:
    if args.relay_uri:
        return {"mode": "external"}
    binary = (args.laps_binary or ROOT.parent / "laps/build/src/lapsRelay").resolve()
    repository = binary.parent.parent.parent if binary.name == "lapsRelay" else binary.parent
    identity = git_identity(repository)
    identity["binaryPath"] = str(binary)
    identity["binarySHA256"] = sha256(binary)
    return identity


def qlog_pairs(run_dir: Path, enabled: bool) -> list[dict[str, object]] | str:
    if not enabled:
        return "disabled"
    relay_qlog_dir = run_dir / "relay" / "qlog"
    pairs: list[dict[str, object]] = []
    for client_qlog_dir in sorted((run_dir / "clients").glob("*/generation-*/qlog")):
        participant = client_qlog_dir.parts[-3]
        generation = client_qlog_dir.parts[-2]
        client_logs = sorted(client_qlog_dir.glob("*.client.qlog"))
        if len(client_logs) != 1:
            pairs.append({"participant": participant, "generation": generation,
                          "status": "unpaired", "clientCount": len(client_logs)})
            continue
        client_log = client_logs[0]
        cid = client_log.name.removesuffix(".client.qlog")
        exact = relay_qlog_dir / f"{cid}.server.qlog"
        candidates = [exact] if exact.is_file() else sorted(relay_qlog_dir.glob(f"{cid}.*.server.qlog"))
        status = "paired" if len(candidates) == 1 else ("unpaired" if not candidates else "ambiguous")
        pairs.append({"participant": participant, "generation": generation,
                      "initialConnectionID": cid, "client": str(client_log),
                      "server": str(candidates[0]) if len(candidates) == 1 else None,
                      "status": status})
    return pairs


def final_file_metadata(run_dir: Path) -> dict[str, object]:
    result: dict[str, object] = {}
    for name in ("config.json", "scenario.json", "events.jsonl", "summary.json", "xcodebuild.log"):
        path = run_dir / name
        if path.is_file():
            result[name] = {"path": str(path), "size": path.stat().st_size, "sha256": sha256(path)}
    return result


def write_json(path: Path, value: object) -> bytes:
    encoded = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
    path.write_bytes(encoded)
    return encoded


def validate_relay_uri(value: str) -> None:
    parsed = urlparse(value)
    if (parsed.scheme != "moq" or not parsed.hostname or parsed.port is None or
            parsed.username is not None or parsed.password is not None or
            parsed.query or parsed.fragment):
        raise ValueError("relay URI must use moq:// with an explicit host and port")


def recorded_argv(argv: list[str]) -> list[str]:
    sensitive = {"--development-team", "--fault"}
    result: list[str] = []
    redact_next = False
    for value in argv:
        if redact_next:
            result.append("<redacted>")
            redact_next = False
        elif value in sensitive:
            result.append(value)
            redact_next = True
        elif any(value.startswith(option + "=") for option in sensitive):
            result.append(value.split("=", 1)[0] + "=<redacted>")
        elif value.startswith("DEVELOPMENT_TEAM="):
            result.append("DEVELOPMENT_TEAM=<redacted>")
        else:
            result.append(value)
    return result


def parse_faults(values: list[str]) -> list[dict[str, object]]:
    faults: list[dict[str, object]] = []
    ids: set[str] = set()
    allowed_keys = {"id", "kind", "localParticipant", "remoteParticipant", "connectionGeneration",
                    "locationRange", "delaySeconds", "activity", "cached"}
    for value in values:
        fault = json.loads(value)
        if not isinstance(fault, dict) or not isinstance(fault.get("id"), str) or not fault["id"]:
            raise ValueError("each --fault must be a JSON object with a non-empty id")
        unknown_keys = set(fault) - allowed_keys
        if unknown_keys:
            raise ValueError(f"unsupported --fault keys: {', '.join(sorted(unknown_keys))}")
        if fault["id"] in ids:
            raise ValueError(f"duplicate fault id: {fault['id']}")
        ids.add(fault["id"])
        faults.append(fault)
    return faults


def scenario_selection(args: argparse.Namespace, scenario_file: Path | None) -> dict[str, object]:
    if scenario_file:
        return {"builtIn": None, "durationMilliseconds": None, "kind": "replay", "replayPath": str(scenario_file), "seed": None}
    if args.scenario == "seeded":
        duration = args.duration_seconds if args.duration_seconds is not None else 30
        return {"builtIn": None, "durationMilliseconds": int(duration * 1000), "kind": "seeded", "replayPath": None, "seed": args.seed}
    if args.scenario == "round-robin":
        duration = args.duration_seconds if args.duration_seconds is not None else 500
        return {"builtIn": None, "durationMilliseconds": int(duration * 1000), "kind": "roundRobin", "replayPath": None, "seed": None}
    if args.scenario == "lifecycle-conversation":
        duration = args.duration_seconds if args.duration_seconds is not None else 500
        return {"builtIn": None, "durationMilliseconds": int(duration * 1000),
                "kind": "lifecycleConversation", "replayPath": None, "seed": args.seed}
    if args.duration_seconds is not None:
        raise ValueError("--duration-seconds is only valid with --scenario seeded, round-robin, or lifecycle-conversation")
    return {"builtIn": args.scenario, "durationMilliseconds": None, "kind": "builtIn", "replayPath": None, "seed": None}


def join_policy(args: argparse.Namespace) -> dict[str, object]:
    custom = args.fetch_threshold_seconds is not None or args.new_group_threshold_seconds is not None
    if custom and args.join_policy != "mixed":
        raise ValueError("custom thresholds require --join-policy mixed")
    if args.join_policy == "mixed" and (args.fetch_threshold_seconds is None or args.new_group_threshold_seconds is None):
        raise ValueError("mixed policy requires both threshold values")
    defaults = {"ngr": (0, 5), "fetch": (5, 5), "wait": (0, 0)}
    fetch, new_group = defaults.get(args.join_policy, (args.fetch_threshold_seconds, args.new_group_threshold_seconds))
    if not 0 <= fetch <= new_group <= 5:
        raise ValueError("join thresholds must satisfy 0 <= fetch <= new-group <= 5")
    return {"fetchUpperThresholdSeconds": fetch, "name": args.join_policy, "newGroupUpperThresholdSeconds": new_group}


def make_config(args: argparse.Namespace, run_dir: Path, staging_dir: Path | None, timestamp: str, scenario_file: Path | None) -> dict[str, object]:
    minimum_participants = 2 if args.scenario == "abrupt-reconnect" or scenario_file else 3
    if args.participants < minimum_participants or args.participants > 65535:
        raise ValueError(f"participants must be in {minimum_participants}...65535")
    if not 1 <= args.top_n < args.participants:
        raise ValueError("top-n must be in 1..<participants")
    if args.max_display_gap_seconds > args.liveness_seconds:
        raise ValueError("max display gap must be no greater than liveness")
    if args.relay_uri:
        validate_relay_uri(args.relay_uri)
        relay_uri = args.relay_uri
    else:
        relay_uri = f"moq://127.0.0.1:{args.port}"
    selection = scenario_selection(args, scenario_file)
    faults = parse_faults(args.fault)
    if args.scenario == "drop-idr-recovery" and not scenario_file:
        recovery_fault_id = "drop-p3-p1-next-idr"
        configured_ids = {fault["id"] for fault in faults}
        if recovery_fault_id in configured_ids:
            raise ValueError(f"--scenario drop-idr-recovery reserves fault id: {recovery_fault_id}")
        faults.append({"activity": 2, "cached": False, "connectionGeneration": 1,
                       "delaySeconds": None, "id": recovery_fault_id,
                       "kind": "dropNextIDR", "localParticipant": "p3",
                       "locationRange": None, "remoteParticipant": "p1"})
    return {
        "artifactDirectory": str(staging_dir or run_dir),
        "deadlines": {
            "diagnosticDrainSeconds": args.diagnostic_drain_seconds,
            "lifecycleSeconds": args.lifecycle_seconds,
            "livenessSeconds": args.liveness_seconds,
            "maxDisplayGapSeconds": args.max_display_gap_seconds,
            "mediaConvergenceSeconds": args.media_convergence_seconds,
        },
        "enableQlog": not args.no_qlog,
        "faults": faults,
        "filterTimeoutMilliseconds": args.filter_timeout_ms,
        "joinPolicy": join_policy(args),
        "meetingID": f"topn-{timestamp}-seed{args.seed}",
        "participants": [f"p{index}" for index in range(1, args.participants + 1)],
        "relayURI": relay_uri,
        "scenario": selection,
        "topN": args.top_n,
        "version": 1,
    }


def run_process(command: list[str], environment: dict[str, str], log_path: Path, cwd: Path | None = None) -> int:
    with log_path.open("w", encoding="utf-8") as log:
        process = subprocess.Popen(command, cwd=cwd, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        assert process.stdout is not None
        for line in process.stdout:
            print(line, end="")
            log.write(line)
        return process.wait()


def wait_for_relay(health_check: Path, relay_uri: str, log_path: Path, attempts: int = 20) -> bool:
    for _ in range(attempts):
        with log_path.open("a", encoding="utf-8") as log:
            result = subprocess.run([str(health_check), "--uri", relay_uri, "--timeout-ms", "2000"],
                                    stdout=log, stderr=subprocess.STDOUT, check=False)
        if result.returncode == 0:
            return True
    return False


def main() -> int:
    args = build_parser().parse_args()
    if args.relay_uri and args.laps_binary:
        return fail("--relay-uri and --laps-binary are mutually exclusive")
    if args.scenario_file and args.scenario != "orderly":
        return fail("--scenario-file and --scenario are mutually exclusive")
    staging_dir: Path | None = None
    run_dir: Path | None = None
    run_metadata: dict[str, object] | None = None
    started_at: datetime | None = None
    try:
        scenario_file = args.scenario_file.resolve() if args.scenario_file else None
        if scenario_file and not scenario_file.is_absolute():
            raise ValueError("scenario file must be absolute after resolution")
        results_root = args.results_root.resolve()
        results_root.mkdir(parents=True, exist_ok=True)
        started_at = datetime.now(timezone.utc)
        timestamp = started_at.strftime("%Y%m%dT%H%M%S.%fZ")
        scenario_name = "replay" if scenario_file else args.scenario
        run_name = f"{timestamp}-seed{args.seed}-{args.join_policy}-{scenario_name}"
        run_dir = results_root / run_name
        run_dir.mkdir()
        (run_dir / "relay").mkdir()
        (run_dir / "clients").mkdir()
        derived_data = args.derived_data_path.resolve() if args.derived_data_path else run_dir / "DerivedData"
        if not args.fixture_preflight:
            STAGING_ROOT.mkdir(parents=True, exist_ok=True)
            staging_dir = Path(tempfile.mkdtemp(prefix=run_name + "-", dir=STAGING_ROOT))
            (staging_dir / "clients").mkdir()
        config = make_config(args, run_dir, staging_dir, timestamp, scenario_file)
        write_json(run_dir / "config.json", config)
        if staging_dir:
            write_json(staging_dir / "config.json", config)
            if scenario_file:
                shutil.copy2(scenario_file, staging_dir / "scenario-input.json")
        run_metadata = {
            "argv": recorded_argv(sys.argv),
            "endedAt": None,
            "outcomeClass": None,
            "quicrMacRevision": git_value("rev-parse", "HEAD"),
            "quicrMacDirty": bool(git_value("status", "--porcelain")),
            "relayMode": "external" if args.relay_uri else "local",
            "relayURI": config["relayURI"],
            "seed": args.seed,
            "startedAt": started_at.isoformat().replace("+00:00", "Z"),
            "timeZone": datetime.now().astimezone().tzname(),
            "fixtureSHA256": sha256(ROOT / "Tests/TopNHarness/Fixtures/topn-gop.qth264"),
            "derivedDataPath": str(derived_data),
            "developmentTeamConfigured": args.development_team is not None,
        }
        write_json(run_dir / "run.json", run_metadata)
        command: list[str]
        if args.fixture_preflight:
            command = ["xcodebuild", "test", "-quiet", "-project", "QuicR.xcodeproj", "-scheme", "QuicR", "-testPlan", "TestPlan",
                       "TOPN_HARNESS_FIXTURE_PREFLIGHT=1",
                       "-destination", "platform=macOS,variant=Mac Catalyst",
                       "-derivedDataPath", str(derived_data),
                       "-resultBundlePath", str(run_dir / "TopNHarness.xcresult"),
                       "-only-testing:Tests/TestTopNClientHarness/testTopNClientFlow"]
            if args.development_team:
                command.append(f"DEVELOPMENT_TEAM={args.development_team}")
            if args.no_test_diagnostics:
                command += ["-collect-test-diagnostics", "never"]
            environment = os.environ.copy()
            environment["TOPN_HARNESS_FIXTURE_PREFLIGHT"] = "1"
            status = run_process(command, environment, run_dir / "xcodebuild.log", ROOT)
        else:
            status = run_full_run(args, config, staging_dir, run_dir, derived_data)
        run_metadata["xcodebuildExitStatus"] = status
        run_metadata["endedAt"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        run_metadata["durationSeconds"] = (datetime.now(timezone.utc) - started_at).total_seconds()
        run_metadata["outcomeClass"] = "passed" if status == 0 else "infrastructure"
        summary_path = run_dir / "summary.json"
        if summary_path.is_file():
            try:
                summary_value = json.loads(summary_path.read_text(encoding="utf-8"))
                run_metadata["outcomeClass"] = summary_value.get("outcomeClass", run_metadata["outcomeClass"])
                run_metadata["failure"] = summary_value.get("failure")
            except json.JSONDecodeError:
                pass
        if not args.fixture_preflight:
            command = ["xcodebuild", "test", "-quiet", "-project", "QuicR.xcodeproj", "-scheme", "QuicR",
                       "-testPlan", "TestPlan",
                       "-destination", "platform=macOS,variant=Mac Catalyst",
                       "-derivedDataPath", str(derived_data), "-resultBundlePath",
                       str(run_dir / "TopNHarness.xcresult"),
                       "-only-testing:Tests/TestTopNClientHarness/testTopNClientFlow"]
            if args.development_team:
                command.append(f"DEVELOPMENT_TEAM={args.development_team}")
            if args.no_test_diagnostics:
                command += ["-collect-test-diagnostics", "never"]
        run_metadata["xcodebuildCommand"] = recorded_argv(command)
        run_metadata["artifactFiles"] = final_file_metadata(run_dir)
        run_metadata["qlogPairs"] = qlog_pairs(run_dir, not args.no_qlog)
        run_metadata["fixturePath"] = str((ROOT / "Tests/TopNHarness/Fixtures/topn-gop.qth264").resolve())
        run_metadata["laps"] = laps_identity(args)
        framework_candidates = sorted(derived_data.glob("Build/Products/**/quicr.framework/quicr"))
        if framework_candidates:
            run_metadata["quicrFramework"] = {"path": str(framework_candidates[0]),
                                               "sha256": sha256(framework_candidates[0])}
        write_json(run_dir / "run.json", run_metadata)
        return status
    except (OSError, ValueError, json.JSONDecodeError, subprocess.SubprocessError) as error:
        if run_dir is not None and run_metadata is not None:
            ended_at = datetime.now(timezone.utc)
            run_metadata["endedAt"] = ended_at.isoformat().replace("+00:00", "Z")
            if started_at is not None:
                run_metadata["durationSeconds"] = (ended_at - started_at).total_seconds()
            run_metadata["outcomeClass"] = "infrastructure"
            run_metadata["failure"] = {"message": str(error)}
            try:
                write_json(run_dir / "run.json", run_metadata)
            except OSError:
                pass
        return fail(str(error))
    finally:
        if staging_dir is not None and staging_dir.exists():
            shutil.rmtree(staging_dir)


def run_full_run(args: argparse.Namespace, config: dict[str, object], staging_dir: Path,
                 run_dir: Path, derived_data: Path) -> int:
    if "com.apple.security.files.downloads.read-write" not in (ROOT / "Decimus/Decimus.entitlements").read_text():
        raise ValueError(f"Decimus entitlements do not permit staging access: {staging_dir}")
    relay_process: subprocess.Popen[str] | None = None
    try:
        if not args.relay_uri:
            laps_binary = (args.laps_binary or ROOT.parent / "laps/build/src/lapsRelay").resolve()
            health_check = laps_binary.parent / "relay_health_check"
            if not os.access(laps_binary, os.X_OK) or not os.access(health_check, os.X_OK):
                raise ValueError("lapsRelay and relay_health_check must be executable")
            relay_dir = run_dir / "relay"
            subprocess.run(["openssl", "req", "-nodes", "-x509", "-newkey", "rsa:2048", "-days", "1", "-subj", "/CN=localhost",
                            "-keyout", str(relay_dir / "server-key.pem"), "-out", str(relay_dir / "server-cert.pem")], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            (relay_dir / "qlog").mkdir()
            stdout = (relay_dir / "stdout.log").open("w")
            stderr = (relay_dir / "stderr.log").open("w")
            relay_process = subprocess.Popen([str(laps_binary), "-d", "-b", "127.0.0.1", "-p", str(urlparse(config["relayURI"]).port),
                                              "-e", "topn-relay", "-c", str(relay_dir / "server-cert.pem"), "-k", str(relay_dir / "server-key.pem"),
                                              "-q", str(relay_dir / "qlog"), "-s", "0", "-t", "5000", "--cache_duration", "60000"],
                                             cwd=laps_binary.parent, stdout=stdout, stderr=stderr)
            stdout.close()
            stderr.close()
            health_log = relay_dir / "health-check.log"
            if not wait_for_relay(health_check, str(config["relayURI"]), health_log):
                raise ValueError("lapsRelay did not become ready after 20 health checks")
        environment = os.environ.copy()
        environment["TOPN_HARNESS_CONFIG"] = str(staging_dir / "config.json")
        command = ["xcodebuild", "test", "-quiet", "-project", "QuicR.xcodeproj", "-scheme", "QuicR", "-testPlan", "TestPlan",
                   f"TOPN_HARNESS_CONFIG={staging_dir / 'config.json'}",
                   "-destination", "platform=macOS,variant=Mac Catalyst",
                   "-derivedDataPath", str(derived_data),
                   "-resultBundlePath", str(run_dir / "TopNHarness.xcresult"), "-only-testing:Tests/TestTopNClientHarness/testTopNClientFlow"]
        if args.development_team:
            command.append(f"DEVELOPMENT_TEAM={args.development_team}")
        if args.no_test_diagnostics:
            command += ["-collect-test-diagnostics", "never"]
        status = run_process(command, environment, run_dir / "xcodebuild.log", ROOT)
        for name in ("scenario.json", "events.jsonl", "summary.json"):
            source = staging_dir / name
            if source.exists():
                shutil.copy2(source, run_dir / name)
        staged_clients = staging_dir / "clients"
        if staged_clients.exists():
            shutil.copytree(staged_clients, run_dir / "clients", dirs_exist_ok=True)
        return status
    finally:
        if relay_process is not None:
            relay_process.send_signal(signal.SIGTERM)
            try:
                relay_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                relay_process.kill()
                relay_process.wait()


if __name__ == "__main__":
    raise SystemExit(main())
