# Native ground services

Source: user's `/Users/pablo/Downloads/Airport Ground Services Sprite Atlas.png` (1254×1254). `source-atlas.png` preserves the original. `scripts/import_ground_services.py` crops the existing transparent components into 16 native asset image sets without generative editing; `import-manifest.json` records crops. Slots are ordered left-to-right, top-to-bottom.

| Slot | Role | Native effect |
|---|---|---|
| 01 | Patrol | Parks at northern base; responds and completes incident cordon |
| 02 | Fire engine | Responds and extinguishes incident flames |
| 03 | Ambulance | Responds and completes rescue |
| 04 | Follow-me | Meets landed aircraft and escorts it to stand |
| 05 | Fuel tanker | Waits for passenger handling, increases aircraft fuel |
| 06 | Catering | Uses ground power and completes catering work |
| 07 | Passenger bus | Waits for stairs, completes passenger handling |
| 08 | Pushback tug | Travels, couples, tows pushback, releases and returns |
| 09 | Baggage tractor | Tows cart and waits for baggage work |
| 10 | Baggage cart | Coupled trailer; waits for loader work and returns behind tractor |
| 11 | Belt loader | Waits for cart, completes baggage handling |
| 12 | Passenger stairs | Deploys and stays through bus/catering work |
| 13 | Water truck | Waits for passengers, completes water replenishment |
| 14 | Lavatory truck | Waits for passengers, completes sanitation work |
| 15 | Ground power | Connects power, stays through turnaround, disconnects |
| 16 | Sweeper | Final stand work; incident debris clearance waits for patrol/fire/rescue |

`GroundServices.swift` owns all task queues, dependencies, movement and effects. `AirportScene.swift` displays their actual positions. Arrival turnaround starts automatically after escort; parked departures can request services. Passenger, transport and fighter families require different service sets. Emergency jobs take priority when vehicles become available. Runways reopen only on the player's instruction after emergency work finishes.

The fleet has24units:15non-tug roles and9local pushback tugs. All ready vehicles park at the northern service apron; one tug is stationed at each of the nine terminal stands. Tiny simulation-timed beacons use normalized roof positions from the supplied sprite crops.

`RoadGraph` uses weighted bidirectional edges and Dijkstra shortest paths. Queries project the start/end onto road edges, including a direct connection when both are on the same edge; the resulting route adds explicit terminal/incident access legs. Terminal stand spurs prevent return paths through adjacent parking positions. Tugs under tow and active escorts use the assigned aircraft’s taxi path. Movement sweeps the next segment against unrelated ground-aircraft footprints, waits while blocked, and resumes once clear. Assigned aircraft are exempt so service units can work underneath, and SpriteKit draws vehicles beneath aircraft.

Roads are authored game lanes and task access spurs, not a surveyed airport road network. Work durations and vehicle speeds are accelerated. This is a functional game prototype, not an operational training model. Engine behavior awaits the user's specification.

Gate lifecycle: passenger unloading14–24s → boarding20–32s → fuel25–40s, with baggage and other service dependencies. After work, a12–30s gate dwell plus crew clearance enables a bobbing READY arrow and a new player-issued departure. Model/work timings are seeded; these are game seconds. Assigned crews work beneath the half-size ground aircraft. All live movement uses fixed image coordinates; historical geographic warping no longer moves aircraft.
