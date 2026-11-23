# Supplied aircraft atlas and game import

1. Source: `/Users/pablo/Downloads/Delhi Airport Overhead Aircraft Atlas.png`, copied unchanged to `source-atlas.png`. It contains 20 nose-up overhead aircraft, in five columns and four rows. The supplied image has no aircraft-type labels; the game uses descriptive family/livery names rather than asserting exact manufacturer variants.

2. Artwork preparation: the built-in image_gen tool was used to clean outside-aircraft fringe while preserving the designs and order, with a transparent background. Exact prompt: [cleanup-prompt.txt](cleanup-prompt.txt). Result: `cleaned-atlas.png`. No API key or CLI image-generation path was used. The user's original remains unchanged.

3. Import: `scripts/import_aircraft_atlas.py` measures connected silhouettes using alpha >32 and crops each aircraft, retaining its original pixel colours and alpha. This threshold measures bounds; it does not cut away pale fuselages or repaint the aircraft. `import-manifest.json` records the 20 source rectangles and dimensions. Preparation uses Pillow/NumPy only; the app has no Python dependency.

4. Game assets: `AirTrafficControl/Assets.xcassets/Aircraft-01.imageset` through `Aircraft-20.imageset`. The selected-aircraft preview, airport models and inbound strip use these same textures. Nose-up source sprites are rotated to match the aircraft heading. Texture aspect ratios are preserved; profile length/span caps distinguish large and small aircraft.

5. Randomisation: `AircraftCatalog.swift` contains family names, sizes, relative movement speeds and traffic weights. Passenger narrowbody jets have weight12 each, long-haul jets5, regional jets3, regional turboprop4, transports/fast jets1. These are gameplay weights, not measured Delhi traffic data. Each shift samples six distinct atlas designs without replacement. Normal restarts continue the random stream; an explicit seed supports repeatable checks. The six-flight scenario and disruption timing remain the same.

6. Verification: all20 assets loaded with alpha; seeded replay, fresh restarts, passenger weighting and all20 reachable designs passed. Scene checks verify that restarts replace textures and do not duplicate aircraft nodes. Thirty randomized fleets completed the closure/emergency scenario without diversions using a valid sequence. Mac and iOS Simulator builds passed. `in-game-preview.png` is a rendered scene from the verified assets. Physical iPhone gameplay remains untested.
