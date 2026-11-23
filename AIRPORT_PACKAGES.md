# Airport packages

1. The running game loads its airport from `AirTrafficControl/Airports/catalog.json`. Add a package folder to its `airports` list and set `defaultAirportID` to choose the startup airport. Rebuild the app to include changed resources. No airport-specific Swift branch is needed. Delhi remains the shipped default; `Tests/Fixtures/Airports/testfield` is a fictional development fixture, not a second real airport release.

2. A package contains `airport.json`, its referenced route JSON, and a background image. Paths must stay inside that package. Schema version 1 uses calibrated image pixels with the origin at the top left; all operational positions are already registered to the image. `image.calibration` optionally records the reference-image affine transform and provenance. The image's decoded dimensions must match the definition and route document.

3. Each runway record describes a physical strip and contains `operatingEnds` plus `preferredEndID`. An operating end supplies its stable ID, displayed runway name, threshold, opposite threshold, holding point, exit point and usable length. The preferred end is the direction enabled by the current airport package. Author and validate another end before enabling reciprocal operations; do not obtain operational direction from gate names or image coordinates.

4. `airport.json` contains:
   - `schemaVersion` and `version`: schema compatibility and airport data revision.
   - `identity`: stable ID, airport code, city/name, and player-facing title/subtitle.
   - `image`: relative image file, dimensions, coordinate system and optional calibration/legacy asset name.
   - `routesFile`: relative path to the authored/compiled aircraft and service graph.
   - `runways`: contiguous integer IDs, both end labels, image-space endpoints, length in metres, width, hold/exit points, holding direction and displayed-range calibration.
   - `stands`: stable IDs, names, parking/nose/port poses, dimensional capacity, flight purpose, authored access, tug bay, permitted departure runway IDs and whether departure needs a tug.
   - `serviceBases`: identities, explicit connection/entry points, access lanes and individual vehicle bays with unique IDs, roles, headings and home positions. Non-tug bay IDs reserve 0–9999; stand tugs use 10000 plus the stand index.
   - `approaches`: IDs, initial positions, fixes and altitudes.
   - `traffic`: initial flight specifications and model pools, allowed stand IDs, purposes/approach references, continuous model/purpose pairs, peer-airport labels, spawn points, callsign sequence, arrival intervals and airborne limit.
   - `serviceProfiles`: required native service-role IDs for passenger, commercial cargo, military fighter and military cargo flights.
   - `rules`: shared airport operating dimensions and approach/turn settings.

5. Aircraft family describes the physical model. Flight/stand purpose is independently one of `passenger`, `commercialCargo`, `militaryFighter` or `militaryCargo`. Model 17, for example, can serve a commercial cargo stand when its flight purpose is commercial cargo; it is not forced onto the military apron because its family is transport. Stand dimensions and runway performance still apply. Departure runway permissions come from stand data, never a gate-name prefix or its screen x-coordinate. After turnaround, origin/destination labels become the package's home airport and a configured peer.

6. Simulation geometry, road caches, source graphs and revision tokens belong to each simulation. Loading another package cannot replace an existing simulation's airport. Rendering reads the same package's image, dimensions, runway ends and stands. The `SurfaceLayout` and `ServiceRoads` static facades remain only for historical Delhi developer tools/checks; live game code uses instance contexts.

7. The loader rejects unknown schemas, inconsistent identities/image dimensions, invalid geometry, duplicate IDs, unknown model/stand/runway/approach references, missing service inventory/access connections, invalid service dependencies, missing images and resource paths escaping the package. This is package validation, not the full typed-topology/turn-width compiler proposed in point 3. The original runway filtering and route algorithms remain otherwise unchanged.

8. Delhi was migrated from the verified running geometry. Its package `routes.json` and `background.png` are exact copies of the existing runtime graph and user image. The saved developer draft and original assets are not changed. Pre-package Delhi graphs without `airportID` retain compatibility; new packages must identify their graph using `airportID`. Debug drafts for other airports are stored in separate airport-ID folders so they do not overwrite the original Delhi draft. The temporary trace editor takes its dimensions, pins and background from the selected package; full guided airport authoring remains point 11.

9. Existing geometry scripts now write package data instead of Swift coordinates:
   - `scripts/build_operational_layout.py` remains the Delhi-specific approved-layout preparation tool. It derives operational stand access, writes the Delhi package's stands/routes and maintains the historical root graph mirror. Run it only when intentionally rebuilding a changed approved trace/layout.
   - `python3 scripts/prepare_playable_routes.py <package-folder>` derives runway pins from that package's runway geometry. It never reads Delhi's old Swift image warp or edits the saved source draft. Review pin choices and validate the resulting package before shipping.
   - Neither preparation script was run against the user's tracing during this migration. New airport tracing needs its own operational labels/permissions, not only unlabelled line strokes.

10. Verification commands:
   - `python3 scripts/check_ground_traffic.py` — package portability/validation plus planner, authority, surface, lifecycle and three-seed fleet checks.
   - `python3 scripts/check_ground_traffic.py AirportRenderingChecks` — independent backgrounds, dimensions, runway labels and stands in two renderer instances.
   - Mac/iOS builds use the existing commands in `PROTOTYPE.md`. The package folder is registered once as an Xcode folder resource; adding another catalogued airport does not need source-file registration.
