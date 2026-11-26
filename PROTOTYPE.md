# DEL / CONTROL — continuous native traffic

Open `AirTrafficControl.xcodeproj` in Xcode, choose **AirTrafficControl → My Mac**, then Run. The local build is `build/Build/Products/Debug/AirTrafficControl.app`. The shared simulation also builds for iOS. Physical iPhone gameplay remains untested.

## Playing

1. Start the shift from the briefing. Select an aircraft on the map or flight list. Only the selected aircraft shows its model/callsign labels; its details show origin, destination and assigned runway. Airport pairs are generated game schedules, not live flight information.
2. Arrivals already have a size-compatible runway assigned and follow it automatically. New arrivals continue spawning, with the interval gradually shortening. Hold/go around or change runway to manage the growing traffic. The tower controls hold/go-around; occupied runways do not trigger an automatic veto. Clearances act immediately; there is no Execute step or exclusive runway reservation.
3. Ready departures can receive pushback/taxi clearance. Passenger stands use local tugs; nose-out military aircraft taxi forward. Eligible runway choices are ranked by connected taxi distance. North/east-terminal departures only offer09/27 and10/28. Larger aircraft cannot use northern09/27. Smaller aircraft can use a traced intersection entry if sufficient runway remains; heavier aircraft require an earlier entry and a longer acceleration run.
4. Taxi and pushback traffic wait or reroute around conflicts, without locking whole future routes. If a taxi route crosses a runway, the aircraft stops and requests permission. Select it and approve the crossing only when safe. Issue takeoff clearance at the runway holding point. Landing/takeoff and airborne separation remain the player's responsibility.
5. Services dispatch automatically when an arrival parks. Passenger handling, baggage, fuel, power and other family-appropriate jobs have real native task states and effects. Passenger unloading/loading precedes fuel work. Crews return to their individual home bases after work. After service, crew clearance and a short randomized wait, the aircraft shows READY for departure.
6. Completed movements earn100points. Each aircraft lost in an airborne/runway collision costs500points. Collisions animate explosions/fire, close affected runways and dispatch emergency crews. Rescue/fire/cordon work precedes cleanup; tower can reopen when cleanup finishes. Accidents occur only when a landing or takeoff operation conflicts with another aircraft occupying that runway. Taxiway/apron conflicts wait safely and do not cause aircraft losses.
7. Pause/resume is in the toolbar. Pinch1–3×and drag while zoomed; Fit airport restores the full scene. New shift resets traffic, score, incidents, tasks and camera.

## Current airport and engine

The offline background is the user's unchanged expanded airport image (1672×941). Aircraft, shadows, wing lights, tiny roof beacons, service vehicles and gate markings are live SpriteKit objects. Ground aircraft are half their high-altitude display size. Air turns use broad tangent arcs and smoothly filtered banking; departures climb and accelerate beyond the image boundary. Ground vibration is a small visual displacement only; routing/collision positions never vibrate. Each model has measured red-port/green-starboard wing-tip anchors. Ground shadows are close; airborne shadows become offset, slightly larger, softer and fainter with altitude.

The approved layout has15passenger stands plus3fighter positions and1turboprop military-cargo position. Stand dimensions restrict accepted models. The initial fleet has9passenger aircraft and3military aircraft. Continuous incoming traffic then builds, with compatible gate queues and automatic approaches. Finite15movement mode is retained for regression checks. Initial departures are already serviced. Cargo model17 fits the military bay; the larger transport profiles16/18 are not spawned into that bay.

The newest saved tracing used for this build contains819aircraft nodes and519vehicle nodes, with1734edges. Exact source snapshot/provenance: `art/operational-routing/`. `AirTrafficControl/airport-routes.json` preserves every original node/edge and adds explicit local gate access and registered runway pins. The saved developer draft is untouched. Native binary-heap Dijkstra follows this network; taxi planning excludes runway-parallel acceleration edges and filters parked-aircraft obstructions. Taxi planning now searches safe time intervals against committed swept-footprint reservations. Movement follows the resulting timed legs and waits; unscheduled aircraft remain stationary obstacles. Local taxi conflicts wait or reroute and opposing traffic can use a tug-assisted passing maneuver. Runway landing/takeoff clearances remain under ATC authority even when occupied; no automatic runway occupancy veto applies. Service fleets stage at the north hangar apron and south service compound; emergency crews are available at both. Each vehicle has a fixed return depot. Carts are paired to their local baggage tractor. Crews may work beneath their assigned aircraft and wait for unrelated aircraft.

The image is edited artwork. Stand access was designed against approximate photographic apron/building geometry; runway-length limits are deliberate game rules, not certified aircraft performance or surveyed airport operations. This is a playable local game build, with no payments, publishing, network backend, live schedules, weather or scripted engine failures.

## Development

The temporary route editor is **Mac Debug only**, excluded from iOS/Release. See `ROUTE_EDITOR.md`. Routing graphs and technical planning details are hidden from normal play. Debug editor activation can override the bundled graph; saved drafts are never silently activated.

Current regression suite (the older SimulationChecks/RenderingChecks describe the preceding nine-gate layout):

```sh
swiftc -O -D DEBUG -parse-as-library AirTrafficControl/Simulation.swift AirTrafficControl/DelhiGroundData.swift AirTrafficControl/AirportLayout.swift AirTrafficControl/AircraftCatalog.swift AirTrafficControl/GroundServices.swift AirTrafficControl/GroundTrafficPlanner.swift AirTrafficControl/AirportDefinition.swift AirTrafficControl/SurfaceLayout.swift AirTrafficControl/RouteGraph.swift Tests/ATCAuthorityChecks.swift -o /tmp/del-authority-checks && /tmp/del-authority-checks
```

Current authority checks cover occupied/marked-closed runway clearances and runway accident consequences, safe taxi waiting, explicit crossing approval, approve-all taxi movement, centreline landing geometry and automatic service/home returns. SurfaceSafetyChecks.swift additionally verifies runway-only accident classification, landing/takeoff versus runway occupants, protected apron contacts, and real north-terminal head-on recovery. Earlier CoreEngineChecks and TrafficFlowChecks safety/deadlock assertions describe the superseded automatic-separation policy.

```sh
swiftc -O -D DEBUG -parse-as-library AirTrafficControl/Simulation.swift AirTrafficControl/DelhiGroundData.swift AirTrafficControl/AirportLayout.swift AirTrafficControl/AircraftCatalog.swift AirTrafficControl/GroundServices.swift AirTrafficControl/GroundTrafficPlanner.swift AirTrafficControl/AirportDefinition.swift AirTrafficControl/SurfaceLayout.swift AirTrafficControl/RouteGraph.swift AirTrafficControl/AirportScene.swift Tests/CoreRenderingChecks.swift -o /tmp/del-core-render-checks && /tmp/del-core-render-checks
```

Renderer checks validate lights, selection-only labels, shadows, vibration without physics displacement, gate/fleet/vehicle rendering, zoom and reset. Screenshot: `art/core-gameplay-preview.png`.

```sh
xcodebuild -project AirTrafficControl.xcodeproj -scheme AirTrafficControl -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
xcodebuild -project AirTrafficControl.xcodeproj -scheme AirTrafficControl -destination 'generic/platform=iOS Simulator' -derivedDataPath build-ios CODE_SIGNING_ALLOWED=NO build
```

To build and launch the macOS game from the terminal, run `./play.command` in the project root (or double-click it in Finder, or in VS Code use **Terminal → Run Task → Play Air Traffic Control**). Use `--skip-build` to relaunch the existing build and `--build-only` to build without launching.

For physical iPhone installation select your device and development team in Xcode. No developer credentials/team were changed.

## Taxi safety and ATC runway authority

Taxiway and apron aircraft wait, reroute or use a traced passing maneuver to avoid contact. There are no taxiway/apron accident penalties. Accidents happen only if an active landing/takeoff aircraft meets another aircraft occupying that runway. The tower can still issue landing, takeoff and crossing clearances on occupied or marked-closed runways; those runway instructions execute without a traffic veto. Crossings still require explicit approval. Aircraft size restrictions and connected taxi geometry remain. Continuous arrivals retain preassigned runways; the tower controls hold/go-around and runway changes.

## Shared timed ground planner (20 November 2026)

1. `GroundTrafficPlanner.swift` searches node/incoming-edge/safe-interval states and returns timed legs with explicit waits and speed profiles. Swept convex aircraft footprints cover opposite edges, turning space and geometric junctions even without a shared graph node. The terminal footprint remains occupied after arrival. This is conservative prioritized planning, not a proof of global deadlock freedom or optimal fleet throughput.
2. `Simulation.swift` proposes initial routes and commits executable schedules through the same planner. Main-actor search/validation/commit uses an immutable traffic snapshot; each new commit is visible to later requests. Fixed pushback and stand-access geometry is scheduled without changing the source traces. Held aircraft, crossing requests and aircraft awaiting tugs have no speculative future departure time.
3. Manual holds, crossing approval, tug availability, route/phase changes, graph revisions, actual-position deviations and reset invalidate affected schedules. Dependent plans are checked against actual held positions; independent traffic retains its slots. A movement safety guard remains as a fallback. Existing physical tug recovery and already-overlapping starting configurations retain guarded local separation; other schedules treat their actual positions as occupied until normal scheduled taxi can resume. ATC crossing approval and final runway authority are separate from taxi scheduling.
4. The planner uses a bounded horizon and search budget, with conservative convex footprints and acceleration/deceleration at graph nodes. Full motion calibration, corridor batching, service-dependency recovery, fairness and the reusable airport package remain separate saved proposals. Vehicle dispatch retains its existing aircraft avoidance.
5. Run the focused planner, authority, surface, full turnaround lifecycle and multi-seed completion checks with `python3 scripts/check_ground_traffic.py`. Pass test names to run a subset, for example `python3 scripts/check_ground_traffic.py GroundTrafficPlannerChecks ATCAuthorityChecks`. The helper compiles the shared Swift sources once, preserves source locations, and runs the existing check entry points without editing them.

## Data-driven airport packages (20 November 2026)

1. The app now reads the default airport from `AirTrafficControl/Airports/catalog.json`. Delhi's identity, calibrated image, runways, stands/permissions, paths, local service inventories, approaches, traffic and service profiles live in its versioned package. [AIRPORT_PACKAGES.md](AIRPORT_PACKAGES.md) describes the schema and authoring/verification commands.
2. Live simulation/rendering use per-airport contexts and caches. The Delhi developer compatibility facades and old geographical reference data remain for historical tools; they do not define live simulation geometry. Flight purpose is independent of airframe family, including commercial versus military cargo.
3. The original tracing, runtime graph and background are preserved. New real airports still require an authored image/trace and operational metadata; no additional user tracing was needed for this Delhi migration.

## Calibrated ground-motion model (20 November 2026)

1. `GroundMotionModel` in `GroundTrafficPlanner.swift` is the single source for phase-aware ground cruise speed, acceleration, braking, reaction allowance, turn-rate limit and spatial uncertainty. Taxi, pushback, off-strip landing/line-up and runway-roll profiles use the same units as the fixed airport image. Sprite scale and ground vibration remain visual only.
2. Timed plan legs integrate asymmetric acceleration and braking exactly, including triangular profiles on short segments and cruise on longer segments. The planner applies graph speed limits and a calibrated turn-speed cap; the executor samples those exact legs instead of reconstructing their timing. Unscheduled recovery/runway movement uses the same profile values.
3. The local safety fallback now looks ahead through reaction distance, physical braking distance, uncertainty and half the visible aircraft length. Active landing/takeoff already on its assigned strip remains governed by tower authority and runway-contact rules, so an adjacent off-strip holding aircraft cannot incorrectly stop the runway roll.
4. `GroundTrafficPlannerChecks` verifies endpoint integration, bounded acceleration/braking, model-speed agreement, stopping distance and turn limiting. Authority, surface, full lifecycle and three fleet seeds pass; the final fleet results are 9/9 departures with zero losses at about485s/397s/425s for seeds17/9/42. This calibration is game-world behavior, not certified real-aircraft performance. Continuous velocity through every graph vertex and empirical tuning from physical-device play remain future refinements.

## Operational phases and runway-end data (20 November 2026)

1. Live departures now move through `taxiing → queued → lineup → takeoffRoll → climbing`; arrivals move through `approach → landingRoll → runwayExit → taxiing`. Line-up remains a scheduled ground movement. Runway collision authority begins with the actual takeoff/landing roll rather than while an aircraft is still approaching its line-up pose.
2. Each physical runway strip retains its geometry and reciprocal pavement labels. Its airport package now selects a versioned operating end containing an ID, displayed name, threshold, opposite threshold, hold point, exit point and usable length. Eligibility and route calculations consume that end data; they no longer infer direction or usable distance from gate names or image position.
3. Delhi intentionally enables its existing four operating directions so gameplay and traced access remain unchanged. A reciprocal direction requires an additional authored operating-end record and traced/validated hold, entry and exit geometry; it does not require new phase-engine code.
4. The lifecycle check must observe landing roll, runway exit, line-up and takeoff roll. The full engine suite passes, including the data-only rotated airport and three Delhi fleet seeds: 9/9 departures with zero losses at about669s/508s/583s for seeds17/9/42. The longer times reflect separately scheduled line-up instead of treating it as takeoff roll. Physical-device play and long continuous-traffic behavior remain unverified.

## Airborne and service-vehicle rules (20 November 2026)

1. Inbound, holding and approach speeds are increased to 28 world units/second times the aircraft factor. Speed reduction begins with landing roll, not during approach.
2. Every airborne aircraft outside approach uses the shared 4,500-foot game altitude. Approach aircraft may descend. Airborne pairs entering a 40-world-unit minimum collision vicinity are destroyed, count as two losses and reduce the score by 1,000 points.
3. Service routes no longer remove edges occupied by aircraft, and service vehicles never stop their movement sweep for an aircraft footprint. They may visibly pass through aircraft; this is intentional simplified gameplay.
4. Per the user's request for speed, only `GameplayRuleChecks` and the macOS Release build were run for this revision. The long multi-seed/lifecycle suites, renderer, macOS Debug, iOS build and physical-device play were not rerun.
