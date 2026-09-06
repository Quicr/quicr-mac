# Top-N harness agent runbook

This document is the bootstrap context for an agent investigating a suspected
top-N video failure. The executable remains the source of truth for flags:
`python3 tools/run_topn_client_harness.py --help`.

## Mission and boundaries

Establish whether a selected remote participant reaches a fresh, visible video
frame through the real local stack. A valid path is:

```text
lapsRelay -> libquicr/QMedia -> VideoSubscription -> VideoHandler
          -> VideoSubscriptionSet/Simulreceive -> VideoGrid -> presented pixels
```

The media fixture and speaker timeline are synthetic. Relay, transport,
subscription, decoder, simulreceive and display-layer timing are live. Logical
clients have independent connections and receive stacks but share one XCTest
process; this is not a process-isolation test.

Do not change product, relay or harness source during a diagnostic run. Preserve
the working tree, do not commit, and do not call a skipped opt-in XCTest a pass.

## Bootstrap

Work from the repository root and capture its state before running anything:

```bash
git status --short
git rev-parse HEAD
python3 tools/run_topn_client_harness.py --help
```

Confirm these executables exist:

```text
../laps/build/src/lapsRelay
../laps/build/src/relay_health_check
```

Those are the normal sibling-repository paths; otherwise pass the absolute path
to the required LAPS build.

Use an existing DerivedData path when one is supplied by the operator. Otherwise
the runner creates and records one inside the result directory. If Xcode requires
a signing team, obtain the machine's configured Apple team identifier and pass it
with `--development-team`; never put it in the project file.

Validate the fixture before the first run after a checkout or toolchain change:

```bash
python3 tools/run_topn_client_harness.py --fixture-preflight \
  --development-team <APPLE_TEAM_ID> \
  --results-root /private/tmp/quicr-topn-preflight
```

The expected fixture SHA-256 is
`ceb5c8f4bbbfac12ea7774b02bd33db45351ecf3951f3e8771a858e5bab484ab`.

## Default investigation

For the active-speaker black-screen report, start with the long seeded lifecycle
conversation. It has three participants, top-1 selection, 100-600 ms overlaps,
and repeated inactivity windows that exercise handler cleanup and reactivation:

```bash
python3 tools/run_topn_client_harness.py \
  --laps-binary ../laps/build/src/lapsRelay \
  --scenario lifecycle-conversation --duration-seconds 500 \
  --participants 3 --top-n 1 --join-policy ngr --seed 1704 \
  --development-team <APPLE_TEAM_ID> \
  --results-root /private/tmp/quicr-topn-investigation
```

Do not disable qlogs for bug hunting. If this passes, run `overlap`, `lifecycle`
and `drop-idr-recovery`. Use a different seed only after preserving and reporting
the first run.

When a run fails, replay its exact resolved timeline before changing variables:

```bash
python3 tools/run_topn_client_harness.py \
  --laps-binary ../laps/build/src/lapsRelay \
  --scenario-file /absolute/path/to/run/scenario.json \
  --participants 3 --top-n 1 --join-policy ngr \
  --development-team <APPLE_TEAM_ID> \
  --results-root /private/tmp/quicr-topn-replay
```

## Evidence gate

Read `run.json` and `summary.json` first. Require non-zero and equal
`checkpointsExecuted`/`checkpointsPassed`, `outcomeClass: passed`, and no failure.
Then inspect the expected subscriber/publisher pair in `events.jsonl`.

A checkpoint is valid only when one causal frame has ordered evidence for:

```text
objectReceived -> objectUsable -> decoderOutput
               -> simulreceiveSelected(displayed=true) -> displayEnqueued
               -> displayPresented(non-black)
```

Receipt and usability are joined by group/subgroup/object. Decode, selection and
enqueue are joined in order by handler generation and presentation timestamp;
selection and enqueue also share a render epoch. The final presentation probe is
attributed to that subscriber/publisher view after the causal enqueue. It samples
the renderer's displayed pixel buffer when available and otherwise downsamples the
actual hosted view. Both paths reject black output. The probe records whether two
different frames were observed from the same source, but does not fail a non-black
view solely because Catalyst returns identical samples. This harness targets black
output; a frozen-but-visible frame remains a separate limitation. Publication
success alone is not receive evidence. Missing events remain missing; never treat
an absent value or an empty event stream as zero or success.

Useful commands:

```bash
python3 -m json.tool /path/to/run/summary.json
python3 -m json.tool /path/to/run/run.json
rg 'publishAccepted|publishRejected|objectReceived|objectUsable|objectRejected|handlerCreated|handlerStopped|decoderOutput|simulreceiveSelected|displayEnqueued|displayPresented|displayError' /path/to/run/events.jsonl
```

Check every `qlogPairs` entry in `run.json` before using qlogs for attribution.
Correlate the client and relay log by initial connection ID. An intentionally
terminated local relay may leave its active qlog without a graceful close; report
that fact rather than calling it a transport failure.

## Attribution

- `infrastructure`: build, fixture, signing, certificate, relay startup, staging
  or test invocation failed. A missing `summary.json` normally belongs here.
- `relayConvergence`: the expected top-N publication was not offered/accepted or
  no fresh object reached the client before the convergence deadline.
- `clientMedia`: objects arrived but the first causal gap is usability, decode,
  simulreceive selection, enqueue, non-black presentation or handler recovery.
- `transport`: use only when paired client/relay qlogs show the connection or
  stream failure. The XCTest summary does not establish this class by itself.

Fault-injection results prove recovery behaviour under the named injected fault;
they do not prove that the natural incident has the same cause. A relay `Internal
error` is likewise a symptom until timestamps and connection IDs correlate it to
the missing client stage.

## Report back

Return the following even for a clean run:

```text
Verdict: passed | reproducible product symptom | harness/infrastructure failure
Scenario: name, seed, duration, participants, top-N, join policy
Sources: quicr-mac revision/dirty state, LAPS revision and binary SHA-256
Result directory: absolute path
Checkpoints: passed/executed
First divergence: subscriber <- publisher, connection generation,
                  handler generation, last successful stage, first missing stage
Presentation: displayPresented count and any displayError diagnostics
Transport: qlog pair count and relevant close/error evidence
Replay: exact scenario replay result, if the original failed
Limitations: shared XCTest process, frozen-visible detection,
             and any truncated relay qlog
```

Do not recommend a product fix until the same replay fails consistently, the
first causal divergence is identified, and harness rejection, relay convergence
and transport evidence have been ruled in or out explicitly.
