# NAB Active Speaker Switching — Reference

This document describes the active speaker switching flow used in the NAB demo. This flow uses MoQ relay-side top-N track filtering to achieve active speaker switching. The relay does not know it's doing "active speaker" — it performs generic ranking of tracks by a header property value. We leverage that by embedding voice activity detection (VAD) state in object headers, so the relay's top-N ranking naturally delivers the most active speakers.

**This is NOT** the client-side `ActiveSpeakerNotifier` flow (where the relay publishes a JSON active speaker list and the client subscribes/unsubscribes). That's a separate mechanism used in the manifest-based flow.

## End-to-End Pipeline

The signal chain from microphone to displayed video:

```
Microphone → Opus Encoder VAD → AudioActivityStateMachine → Header on Audio Objects
                                        ↓
                                SharedVoiceActivityState
                                        ↓
                              Video VAD Dampening → Header on Video Objects
                                        ↓
                              Relay Top-N Filter (per namespace)
                                        ↓
                              Object Delivery to Client
                                        ↓
                              Client Display (clamped to N)
```

### VAD Detection

The Opus encoder produces a raw `voiceActive` boolean. This is too noisy to use directly — it flickers on and off with breathing, hesitations, background noise. The `AudioActivityStateMachine` smooths this into a three-state signal.

### AudioActivityStateMachine

Converts raw VAD into a stable state with hysteresis. The three states and their wire values:

| State | Value | Meaning |
|-------|-------|---------|
| `speechEnd` | 0 | Silence |
| `continuousSpeech` | 1 | Sustained speech |
| `speechStart` | 2 | Speech just detected (highest value = highest relay priority) |

Note: `speechStart` has the highest numeric value (2), which means the relay will prioritise someone who just started speaking over someone in continuous speech. This is intentional — it biases switching toward new speakers.

**Timing parameters** (all configurable via `demoTime*` settings on `CallState`):

| Parameter | Default | Controls |
|-----------|---------|----------|
| `timeToSpeechStart` | 150ms | How long raw VAD must be active before entering `speechStart` |
| `timeToContinuous` | 500ms | How long in `speechStart` before promoting to `continuousSpeech` |
| `timeToDropStart` | 250ms | How long silent before dropping from `speechStart` → `speechEnd` |
| `timeToDropContinuous` | 600ms | How long silent before dropping from `continuousSpeech` → `speechEnd` |

**State transition diagram:**

```
                    VAD active for
                    timeToSpeechStart
  speechEnd (0) ─────────────────────→ speechStart (2)
       ↑                                     │
       │ silent for                          │ VAD active for
       │ timeToDropStart                     │ timeToContinuous
       │                                     ↓
       ←──────────────────────────── continuousSpeech (1)
            silent for
            timeToDropContinuous
```

### Header Encoding

The state machine value is embedded as header extension `audioActivityIndicator` (ID 12, `AppHeadersRegistry`) on both audio and video objects. This is a single `UInt8` — just the raw state value (0, 1, or 2).

**Audio side** (`OpusPublication.swift:294-301`): State machine runs on every encoded audio packet. The value is set as a header extension and also posted to `SharedVoiceActivityState` for the video publisher.

**Video side** (`H264Publication.swift`): Video publisher consumes the latest audio state from `SharedVoiceActivityState` and embeds it in video frame headers. Transitions are detected by `VideoVADTransition` to trigger group/subgroup rolls.

### Video-Side VAD Handling

The video publisher receives the state machine output via `SharedVoiceActivityState` and embeds it in video object headers. It also manages group/subgroup rolls based on transitions:

- **Upward transition → roll group (keyframe).** When the raw header value rises (e.g., speechEnd(0) → speechStart(2)), the video publisher triggers a keyframe via `VideoVADTransition`. The reasoning: if our relay ranking just went up, we're likely about to be switched in by the top-N filter, so we want a keyframe ready so the receiving client can immediately start decoding our stream. Note: speechStart(2) → continuousSpeech(1) is a raw value *drop*, so no keyframe — we already sent one when speech started.
- **Downward transition → roll subgroup.** The relay may only examine header values at subgroup boundaries (not every object), so rolling a subgroup on drop ensures the relay sees the change promptly. This includes the speechStart → continuousSpeech transition (raw 2→1).

The `rollSubgroup` mechanism is controlled by `demoVadRollSubgroup` (default true).

### SharedVoiceActivityState

A `Mutex<AudioActivityValue?>` that allows the audio publisher to post its latest state and all video quality publications to read it. Uses latest-value semantics — `latestActivity()` reads without clearing, so multiple video quality publications all see the same value. This is critical: each participant has one `SharedVoiceActivityState` shared across all quality publications. If the read were consume-once, only one quality would get each update, causing different header values across quality namespaces and divergent relay ranking (selecting different participants per quality).

## Catalog & Namespace Topology

### How the Catalog Works

The client subscribes to a catalog track published by the relay. The catalog is a JSON document that provides **publish templates** — it tells each client what tracks to publish and at what qualities.

For example, a catalog might say: "publish 3 video qualities (high/medium/low) and 1 audio track." Each published track has a MoQ namespace that ends in the participant's ID.

### Deriving Subscribe Namespaces

To subscribe, the client takes each catalog entry's namespace and **drops the participant ID suffix**. This gives a namespace prefix that covers all participants at that quality level.

```
Catalog says publish:    meeting/video/high/<participant-id>
Client subscribes to:    meeting/video/high/
                         ↑ catches all participants at high quality
```

This means the client ends up with one subscribe namespace per quality bucket:
- `meeting/video/high/` (all participants, high quality)
- `meeting/video/medium/` (all participants, medium quality)
- `meeting/video/low/` (all participants, low quality)
- `meeting/audio/` (all participants, audio)

Each subscribe namespace handler has the same top-N filter attached.

### Namespace Handler Lifecycle

Namespace handlers are created in `CallState.handleCatalogUpdate()` (lines 629-646). When the catalog changes:
- New namespace prefixes get new handlers with filters attached
- Removed namespace prefixes get their handlers torn down
- Handlers stored in `nabNamespaceHandlers` dictionary keyed by prefix

## Relay-Side Top-N Filtering

### The Generic Mechanism

The relay's filter is configured via `QTrackFilterObjC` with:

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `propertyType` | 12 (`audioActivityIndicator`) | Which header extension to rank by |
| `maxTracksSelected` | 3 | How many tracks to actively deliver |
| `maxTracksDeselected` | 10 | How many inactive tracks to keep state for |
| `maxTimeSelected` | 500ms | Time window for selection stability |

The relay examines the specified header property on every object flowing through each track in the namespace. It ranks tracks by the property value and delivers objects only for the top-N tracks. This is purely a data delivery decision — there is no signalling to the client about which tracks are selected or deselected.

### What "Switching" Looks Like

When the relay selects a new track into the top-N:
- Objects start being delivered on that track's subscription
- The client starts receiving frames

When the relay deselects a track:
- Objects stop being delivered
- The subscription remains alive — no teardown

There is no control message. The client detects switching implicitly by whether objects are arriving.

## Client-Side Subscription Lifecycle

Subscriptions are **long-lived**. When a track first appears (via the subscribe namespace's `CreateHandler` callback), `CallState.nabCreateHandler()` creates a subscription by matching the track's namespace against catalog entries. That subscription persists for the duration of the call.

The top-N switching only controls object delivery — it does not create or destroy subscriptions. A subscription that's been deselected just stops receiving objects. When it's selected again, objects resume.

In principle, tracks that have been inactive for a long time may be unpublished by the relay, which would tear down the subscription. But for the typical NAB demo scenario, subscriptions should be treated as always-up once created.

### CreateHandler Flow

1. Relay offers a new track in a subscribed namespace
2. libquicr invokes the `CreateHandler` callback on `QSubscribeNamespaceHandler`
3. This calls through to `CallState.publishReceived()` → `nabCreateHandler()`
4. `nabCreateHandler()` extracts the namespace prefix, matches it against catalog entries
5. Creates a subscription from the matched catalog profile
6. Stores it in `nabSubscriptionsByNamespace` for lifecycle tracking

## Client-Side Display

The intended behaviour is to clamp the number of visible video tiles to `maxTracksSelected` (N). This means:
- Show the N subscriptions that are currently receiving fresh data
- When a switch happens, the newly-active subscription replaces a stale one
- Stale video from deselected tracks is never shown

The actual display mechanism goes through `VideoSubscriptionSet`, which has its own quality selection logic (simulreceive — choosing between multiple quality levels for the same participant) and quality hysteresis (not switching quality on every frame).

## Audio vs Video

Audio and video subscribe namespaces have independent top-N filter instances. Currently they are configured with the same parameters.

In an ideal world, audio could be more reactive (shorter time thresholds, faster switching) since audio switching is less jarring than video switching. Video could be more stable (longer thresholds) to avoid visual disruption, accepting slightly slower switching. But for now, same config for both is good enough.

## Key Files

| File | What It Does |
|------|-------------|
| `Decimus/CallState.swift` | Orchestrator — catalog handling, namespace setup, subscription creation |
| `Decimus/Publications/AudioActivityStateMachine.swift` | VAD state machine (silence/start/continuous) |
| `Decimus/Publications/SharedVoiceActivityState.swift` | Audio→video VAD sharing |
| `Decimus/Publications/OpusPublication.swift` | Audio header encoding |
| `Decimus/Publications/H264Publication.swift` | Video header encoding + group/subgroup rolls |
| `Decimus/Publications/VideoVADTransition.swift` | Transition detection (raw value comparison) |
| `Decimus/AppHeaderRegistry.swift` | Header extension IDs (audioActivityIndicator = 12) |
| `Decimus/MoQImplementations/QSubscribeNamespaceHandler.swift` | Subscribe namespace handler + filter |
| `Decimus/CallController.swift` | Low-level subscribe/unsubscribe namespace calls |
| `Decimus/Subscriptions/VideoSubscriptionSet.swift` | Quality selection + display |
| `Decimus/ActiveSpeakerStats.swift` | Switch latency tracking |

## Configuration Parameters

All configurable on `CallState` (prefixed `demo*` in the current code):

| Parameter | Default | Stage |
|-----------|---------|-------|
| `demoMaxTracksSelected` | 3 | Relay filter — how many tracks to deliver |
| `demoMaxTracksDeselected` | 10 | Relay filter — inactive tracks kept in state |
| `demoMaxTimeSelected` | 0.5s | Relay filter — selection stability window |
| `demoTimeToSpeechStart` | 150ms | VAD state machine — silence to speech start |
| `demoTimeToContinuous` | 500ms | VAD state machine — speech start to continuous |
| `demoTimeToDropStart` | 250ms | VAD state machine — speech start to silence |
| `demoTimeToDropContinuous` | 600ms | VAD state machine — continuous to silence |
| `demoVadRollSubgroup` | true | Video — roll subgroup on VAD change |

## Known Issues & Open Questions

1. **NAB path never sets up display clamping or staleness checks.** The `maxDisplayCount` and `startStalenessChecks()` are only configured in the demo path (`if self.demoEnabled`, CallState.swift:403-407). The NAB path (`if self.nab`, line 380) sets up the catalog subscription but never configures the staleness machinery. So for NAB, `maxDisplayCount` is nil and staleness checks never run — every participant that's ever received a frame stays visible with its last frame frozen. Fix: the NAB `handleCatalogUpdate` (or the initial NAB setup) needs to set `videoParticipants.maxDisplayCount = demoMaxTracksSelected` and call `startStalenessChecks()`. Additionally, the staleness check has a subtle guard (`freshCount >= target`) that prevents hiding stale tiles until enough fresh replacements exist, which can cause momentary N+1 display during switches.

2. **Audio and video filters use identical parameters.** Audio switching could be faster/more reactive, video switching could be more stable. Independent tuning is possible since they're separate filter instances on separate namespaces.

3. **speechStart (2) > continuousSpeech (1) — is this the right ranking?** This means a new speaker always trumps a continuous speaker in the relay's ranking. Good for responsiveness, but could cause ping-ponging if two people are having a rapid back-and-forth.

4. **No explicit switch signal from relay.** The client has to infer switching from data flow. This makes switch detection timing dependent on object cadence — if objects are infrequent (low framerate), switch detection is slower.

5. **Subscription cleanup on unpublish.** Long-lived subscriptions assume tracks stay published. If a participant leaves and their tracks are unpublished, what's the cleanup path?

6. **Relay header inspection granularity.** Does the relay examine the header property on every object, or only at subgroup/group boundaries? This affects whether subgroup rolls on VAD drops are necessary for prompt relay reaction, or just a nice-to-have.

## Design Decisions

1. **Why long-lived subscriptions?** Avoids the overhead of teardown/recreate cycles on every switch. The relay is already handling selection — the client just needs to consume whatever arrives. Subscription setup has latency cost (especially for video which may need a keyframe), so keeping them alive means faster re-selection.

2. **Why roll group (keyframe) on VAD rise?** If our activity just went up, the relay is likely about to switch us into someone's top-N. A keyframe lets the receiving client start decoding immediately rather than waiting for the next periodic IDR. The cost is bandwidth (keyframes are large), but genuine speech starts are infrequent enough that this is acceptable.

3. **Removed video dampening layer (2026-03-27).** The `updateDampenedVAD` function was removed from `H264Publication`. It added a second dampening layer (300ms rise threshold) on top of the state machine, intended to prevent keyframe spam, but the SM already eliminates VAD flicker. The extra layer added 300ms of video switching latency and caused audio/video header desync at the relay. Replaced with `VideoVADTransition` — a simple struct that compares current vs previous raw value. Group roll on raw value rise (only speechEnd→speechStart in practice), subgroup roll on raw value drop. Transitions use raw value ordering to match the relay's ranking semantics.

4. **Future: separate state machines per media type.** Rather than layering two different mechanisms, audio and video should each run their own `AudioActivityStateMachine` instance from the raw VAD boolean. Audio SM: fast parameters (quick switching, audio is forgiving). Video SM: slower parameters (keyframe protection, visual stability). Both would produce the same 3-state output, just with different timing. This replaces the current architecture where audio runs the SM and shares its output to video. Instead, `SharedVoiceActivityState` would share the raw VAD boolean.

5. **Why speechStart > continuousSpeech in ranking?** Biases toward new speakers entering the conversation. Someone who just started talking will temporarily rank higher than someone who's been talking for a while. This prevents a single continuous speaker from monopolising the top-N slots when someone else tries to interject.

6. **Why embed VAD in both audio and video headers?** The relay filters per-namespace, and audio/video are in separate namespaces. Each namespace's filter needs to see the ranking property on the objects flowing through it. Audio objects carry the audio VAD state directly. Video objects carry it too so the relay can independently rank video tracks.

7. **Why catalog-driven namespace discovery?** The relay can change the available quality levels or track topology without client code changes. The catalog is the source of truth for what's available — the client just derives subscribe namespaces from it.
