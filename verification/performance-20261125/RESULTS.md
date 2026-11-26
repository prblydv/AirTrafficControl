# Performance refactor — 25 November 2026

1. Scope: improve frame pacing and reduce unnecessary CPU/GPU work while preserving simulation rules, traffic volume, aircraft artwork, collision precision and routing choices. Baseline is the exact dirty working tree copied to `/tmp/atc-performance-baseline.e4Rlv1` before this refactor, rather than an older Git commit. Source hashes are in `source-provenance.json`.

2. Changes: SpriteKit retains its 60 Hz display clock while the SwiftUI dashboard publishes progress at 10 Hz and immediately on commands/events. Pausing draws the final frame and then stops the native display loop; input wakes it. Mac trackpad magnification now goes directly through the native view, including while paused. Aircraft and vehicle node references are cached; towing/incident status uses per-frame sets instead of nested task/aircraft scans. Invisible finished aircraft nodes and finished flame actions are released/stopped without deleting simulation history.

3. Routing: retain the same shortest-path algorithm, candidate order, costs, footprint checks and floating-point arithmetic. Cache immutable landing-exit and departure-hold geometry per airport; precompute it on a serial utility queue. Current traffic decisions remain on the simulation thread, with identical synchronous fallback if a cached result is unavailable. Geometry caches are bounded (128 exit keys, 256 departure keys). Traffic footprints are calculated once per search, and nearest-edge selection calculates each distance once. This removes redundant work without reducing search quality or changing game rules.

4. Gameplay parity: a seeded continuous-traffic 600-second replay at 60 ticks/second records aircraft positions/headings/routes/phases, ground vehicles, service tasks, traffic sequence, runway state and incidents every 10 simulated seconds. The cumulative SHA-256 matches the original exactly: `60e018833fcb834c5225e9e937dd860f8676f767ef4cbb7d9c43d09c90e4fac9`. Both finish with 22 aircraft, 57 vehicles, 92 service tasks and one incident. This is evidence for the tested workload, not a proof over every possible player action.

5. Regression checks: 17 of the 20 selected existing checks pass, covering packages/independent airports, full arrival-service-departure lifecycle, local following, congestion alternatives, continuous arrivals, direct northern exits, tug selection/recovery, runway footprint accidents, hold clearance, stand allocation/relocation and rendering. Three checks also fail on the untouched baseline: GroundTrafficPlannerChecks (final background clearance case), GroundTrafficCompletionChecks (DEL602 and DEL305 mutually blocked at pushback, 7/9 departures), and BlockedLandingExitChecks (no alternate exit selected in its fixture). Baseline logs and `checks.json` are retained. These existing gameplay failures were not changed during a behavior-preserving performance refactor. Additional final LiveRenderingChecks cover initial rendering, pause/resume and native pinch zoom both paused and running; physical trackpad/iOS device play is not claimed.

6. Memory: Apple's `leaks --atExit` with malloc stack logging reports **0 leaks / 0 leaked bytes** after the 600-second simulation workload; see `leaks-simulation.log`. Precomputed geometry intentionally retains more memory than the original on-demand version. Resident memory fluctuates with asset paging and system pressure, so a resident-size increase alone is not evidence of a leak. This check does not establish leak freedom for every UI lifecycle or indefinitely growing gameplay history.

7. Measurement method: optimized arm64 harness, actual SwiftUI/SpriteKit window, same seed/clearance driver, 90 simulated seconds of preparation, then active play and five seconds paused. The harness rejects runs that do not render or advance simulation. CPU percentage is process CPU time divided by wall time, relative to one core; it is **not battery watts or Activity Monitor's Energy Impact**. Frame callbacks are measured through SKViewDelegate. A first paused-view implementation produced zero frames and was rejected (`optimized-window-first.json`); those numbers are not used as an improvement. An intermediate run had a 633 ms isolated stall; it is retained in `final-window.json`, not hidden. A subsequent run, partly under sampling/build load, measured 59.49 FPS, 20.06% CPU and a 66.66 ms maximum interval (`final-window-repeat.json`). Clean final results are recorded separately in `clean-window.json`.

8. Reproduce after building the Release app's bundled assets: `python3 scripts/check_performance.py --mode simulation --seconds 600 --output /tmp/atc-replay.json --compare verification/performance-20261125/baseline-simulation.json`; `python3 scripts/check_performance.py --mode window --duration 30 --output /tmp/atc-window.json`; `python3 scripts/check_performance.py --mode checks --output /tmp/atc-checks.json` (the three baseline failures above remain). Harness compilation is cached by source content. Build the normal Mac app with `xcodebuild -quiet -project AirTrafficControl.xcodeproj -scheme AirTrafficControl -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/AirTrafficControlOptimized ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build`.

9. Final measurements on this M1 Air/8 GB/macOS 27.0.1, with no compiler or sampler running during the clean window run:

   | Metric | Before | Optimized |
   |---|---:|---:|
   | Active process CPU | 53.04% | 25.31% |
   | Render callbacks per second | 57.42 | 59.76 |
   | 99th percentile frame interval | 33.33 ms | 17.67 ms |
   | Longest frame interval | 533.32 ms | 66.35 ms |
   | Paused process CPU | 32.29% | 0.022% |
   | Paused render callbacks in five seconds | 300 | 0 |
   | 600-second headless replay wall time | 37.95 s | 12.53 s |
   | 99th percentile simulation tick | 1.127 ms | 0.613 ms |
   | Longest headless simulation tick | 641.99 ms | 139.29 ms |

   Active CPU fell 52.3%; the deterministic replay runs about 3.0× faster. Original window sample is 45 seconds; clean final sample is 30 seconds. Both use the same preparation/driver, but these are short local measurements with normal OS variability, not a battery rundown or a guarantee of hitch-free play. Six final intervals exceeded 25 ms, so occasional stalls remain. Final active resident memory was 82.3–86.8 MiB, versus roughly 43–48 MiB originally; precomputed geometry trades bounded retained memory for lower repeated CPU work. See raw JSON for all samples.

10. Final macOS arm64 Release and iOS Simulator arm64 Release builds pass. Final native zoom/render/pause/resume check and deterministic replay pass. The rebuilt normal Mac app was reopened from `/tmp/AirTrafficControlOptimized/Build/Products/Release/AirTrafficControl.app`; profiling processes have exited. No C rewrite, traffic reduction, asset downscaling, new dependency, remote publishing or graph/game-rule alteration was required.
