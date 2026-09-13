# Top-N client harness

Agents should begin with the bootstrap and evidence workflow in
[`top-n-client-harness-agent-runbook.md`](top-n-client-harness-agent-runbook.md).

The harness runs three or more independent Mac Catalyst clients through a real
MoQ relay. Each client uses the production libquicr connection, namespace
filter, subscription, H.264 decoder, simulreceive selection, and display path.
The publisher is a deterministic five-second, 30 fps H.264 fixture. It does
not exercise camera capture, microphone capture, FVAD, the production encoder,
or the production capture lifecycle. Network and callback timing remain real;
the encoded media bytes and scenario timeline are deterministic.

## Prerequisites

Install Xcode with a Mac Catalyst destination, build the repository dependency
frameworks, and provide an executable `lapsRelay` together with its sibling
`relay_health_check` for local runs. The existing Catalyst Downloads
read/write entitlement is used for temporary sandbox-visible staging. External
relay runs only require a reachable `moq://host:port` endpoint.

If Catalyst signing is not already configured, pass the 10-character Apple team
identifier with `--development-team`. The runner supplies it to `xcodebuild`; do
not write a personal team identifier into the project file.

Validate the bundled fixture and its VideoToolbox decode path with:

```bash
python3 tools/run_topn_client_harness.py --fixture-preflight
```

Regenerate the synthetic fixture only when its format or source image changes:

```bash
xcrun swift tools/generate_topn_h264_fixture.swift \
  Tests/TopNHarness/Fixtures/topn-gop.qth264
shasum -a 256 Tests/TopNHarness/Fixtures/topn-gop.qth264
```

The checked-in fixture hash is
`ceb5c8f4bbbfac12ea7774b02bd33db45351ecf3951f3e8771a858e5bab484ab`.

## Running scenarios

Local mode starts and stops only the relay child created by the runner. Replace
`/path/to/lapsRelay` with the actual executable path:

```bash
python3 tools/run_topn_client_harness.py --laps-binary /path/to/lapsRelay \
  --scenario orderly --join-policy ngr --participants 3 --top-n 1 --seed 101
python3 tools/run_topn_client_harness.py --laps-binary /path/to/lapsRelay \
  --scenario overlap --join-policy ngr --participants 3 --top-n 1 --seed 102
python3 tools/run_topn_client_harness.py --laps-binary /path/to/lapsRelay \
  --scenario lifecycle --join-policy ngr --participants 3 --top-n 1 --seed 103
python3 tools/run_topn_client_harness.py --laps-binary /path/to/lapsRelay \
  --scenario seeded --duration-seconds 60 --join-policy ngr --participants 4 --top-n 1 --seed 424242
python3 tools/run_topn_client_harness.py --laps-binary /path/to/lapsRelay \
  --scenario round-robin --duration-seconds 500 --join-policy ngr --participants 3 --top-n 1
python3 tools/run_topn_client_harness.py --laps-binary /path/to/lapsRelay \
  --scenario lifecycle-conversation --duration-seconds 500 --join-policy ngr \
  --participants 3 --top-n 1 --seed 1704
python3 tools/run_topn_client_harness.py --laps-binary /path/to/lapsRelay \
  --scenario drop-idr-recovery --join-policy ngr --participants 3 --top-n 1 --seed 104
```

`round-robin` is event-driven: the next participant starts only after every
other client has freshly received, accepted, decoded, and displayed the current
participant. It overlaps speakers by 150 ms and repeats until the requested
duration. `media-convergence-seconds` bounds each hand-off.

`lifecycle-conversation` uses a seeded, replayable turn sequence with random
100–600 ms overlaps. It repeatedly keeps one publisher inactive long enough to
exercise the production video-handler cleanup timer, then requires every other
client to observe a new handler generation and a sustained
receive/usable/decode/select/display pipeline after reactivation. Lifecycle
failures are recorded at each checkpoint but deferred until the complete
timeline has run.

For an externally managed relay, use `--relay-uri`; the runner does not start,
stop, or clean up that relay:

```bash
python3 tools/run_topn_client_harness.py --relay-uri moq://relay.example:33435 \
  --scenario overlap --join-policy ngr --participants 3 --top-n 1 --seed 11
```

Replay the exact resolved timeline from a previous run with:

```bash
python3 tools/run_topn_client_harness.py --scenario-file /path/to/run/scenario.json \
  --join-policy ngr --participants 3 --top-n 1 --seed 11
```

Join policies expose the production conversion used by `SubscriptionConfig`:

```text
ngr:   fetchUpperThreshold=0s, newGroupUpperThreshold=5s
fetch: fetchUpperThreshold=5s, newGroupUpperThreshold=5s
wait:  fetchUpperThreshold=0s, newGroupUpperThreshold=0s
mixed: --fetch-threshold-seconds 1 --new-group-threshold-seconds 4
```

Faults are injected test behaviour, not evidence of a natural relay or network
fault. Pass each rule as JSON with `--fault`. Examples for the six rule kinds:

```bash
--fault '{"id":"d","kind":"dropNextIDR","localParticipant":"p3","remoteParticipant":"p1","connectionGeneration":1,"locationRange":null,"delaySeconds":null,"activity":2,"cached":false}'
--fault '{"id":"r","kind":"dropLocationRange","localParticipant":"p3","remoteParticipant":"p1","connectionGeneration":1,"locationRange":{"firstGroupId":2,"firstObjectId":0,"lastGroupId":2,"lastObjectId":10},"delaySeconds":null,"activity":null,"cached":null}'
--fault '{"id":"l","kind":"delayLocationRange","localParticipant":"p3","remoteParticipant":"p1","connectionGeneration":1,"locationRange":{"firstGroupId":2,"firstObjectId":0,"lastGroupId":2,"lastObjectId":10},"delaySeconds":0.1,"activity":null,"cached":null}'
--fault '{"id":"n","kind":"suppressNextNGR","localParticipant":null,"remoteParticipant":"p1","connectionGeneration":1,"locationRange":null,"delaySeconds":null,"activity":null,"cached":null}'
--fault '{"id":"u","kind":"reuseGroupBaseOnNextRejoin","localParticipant":null,"remoteParticipant":"p3","connectionGeneration":2,"locationRange":null,"delaySeconds":null,"activity":null,"cached":null}'
--fault '{"id":"g","kind":"regressGroupBaseOnNextRejoin","localParticipant":null,"remoteParticipant":"p3","connectionGeneration":2,"locationRange":null,"delaySeconds":null,"activity":null,"cached":null}'
```

The drop-IDR recovery scenario adds its required `drop-p3-p1-next-idr` rule
automatically unless a conflicting rule is supplied.

## Artefacts

Each run is written below `.topn-harness-results/<timestamp>-seed<seed>-...`:

```text
run.json                 host, build, relay, hashes, qlog pairing, outcome
config.json              supplied canonical configuration
scenario.json            resolved timeline executed by XCTest
events.jsonl             ordered production and harness events
summary.json             checkpoint counts, outcome class, first failure
xcodebuild.log           streamed Catalyst test output
TopNHarness.xcresult     Xcode result bundle
clients/<id>/generation-N/qlog/
relay/qlog/
```

Event timestamps are monotonic and run-relative. Missing stages remain absent;
the harness never fills them with synthetic zero values.

Use `summary.json` first, then follow the ordered stages in `events.jsonl`:

```bash
rg 'faultApplied|objectRejected|joinDecision|newGroupRequested|publishedObject|decoderOutput|displayEnqueued' /path/to/run/events.jsonl
python3 -m json.tool /path/to/run/summary.json
```

The outcome classes are `passed`, `infrastructure`, `transport`,
`relayConvergence`, and `clientMedia`. Triage in that order of evidence:
summary and failure detail, causal event stages, client/relay logs, then paired
picoquic qlogs. A client qlog is paired by its initial connection ID with the
matching relay `.server.qlog`; qlog pairing is disabled with `--no-qlog`.

## CLI reference

The executable is the source of truth for options. Inspect the current list
with:

```bash
python3 tools/run_topn_client_harness.py --help
```

Important options include `--relay-uri`, `--laps-binary`, `--port`,
`--participants`, `--top-n`, `--filter-timeout-ms`, `--join-policy`,
`--scenario`, `--scenario-file`, `--duration-seconds`, `--seed`, all deadline
options, repeated `--fault`, `--development-team`, `--no-qlog`, and
`--results-root`.

The first increment deliberately keeps all logical clients in one XCTest host.
It still creates independent transport and receive stacks, but it is not a
multi-process isolation test. Generic offline transport replay is outside the
scope of this harness; the fixture is deterministic while relay and callback
ordering are live.
