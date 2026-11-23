# Gate layout proposal — review only

No game source, active layout or saved tracing was changed. Open `index.html` for the interactive review.

| Layout | Terminal parking positions | Large-capable | Standard-capable | Compact-only | Straight tow corridors checked |
|---|---:|---:|---:|---:|---:|
| Maximum compact parking | 15 | 0 | 0 | 15 | 5/15 |
| Standard passenger layout | 15 | 0 | 11 | 4 | 5/15 |
| Mixed fleet | 15 | 4 | 7 | 4 | 5/15 |
| Large-aircraft priority | 13 | 6 | 5 | 2 | 4/13 |

The mixed-fleet proposal has four central-north positions, seven central-south positions and four at the east terminal. These are fictional game stand IDs, not real Delhi gate numbers. Large positions can also take smaller profiles.

## Checks and limits

- Uses the saved 1,315-node/1,694-edge draft, frozen as routes-snapshot.json. Both original route networks were connected; all16 vehicle types had all vehicle edges available.
- Uses current 0.55ground scale and model profile envelopes: compact19.8×19.8px, standard26.95×23.65px, large36.85×36.3px (length×span).
- Apron and terminal/landscaping geometry traced from the existing image. Candidate positions sampled every2.5px along pier edges. Parking shapes have3px buffer per aircraft (approximately6px between neighboring shapes), plus building and taxiway exclusion checks.
- Integer optimization reached an optimum over the sampled candidate geometry for each reported configuration. This does not establish a global or surveyed airport maximum.
- The outlines use a planning silhouette derived from model-profile dimensions. Actual sprite shape, towing turn, vehicle working positions and moving clearances need final native simulation validation.
- Straight reverse-to-taxi connections were checked separately. Unchecked connections are clearly marked; parking fit alone is not authorization for live use.
- A clear tow path may overlap another aircraft’s maneuver corridor; departures must be sequenced. Full curved pushback has not been validated.
- No remote stands were invented to increase the terminal count.
- Runway intersection takeoff-distance classifications are a separate pending task.

## Files

- index.html: interactive review (four layouts, actual sprites, selectable stands, clearance/taxiway toggles, zoom/pan).
- gate-layout-proposal.json: candidate coordinates, headings, size limits, proposed taxi joins, solver results and limitations. This is not an active routing document.
- preview.png / preview-east.png: native WebKit screenshots.
- routes-snapshot.json: unchanged tracing snapshot for reproducibility.

Route SHA256: `09c9d79c2d50422629b82db4709c9fd0b2b762c2dae006dbdc78ab3e6de461f9`.

## Military apron option — 20 November 2026

User designated the apron south of runway10/28 for fighters and military cargo, with four existing traced aircraft access spurs (nodes667,765,774,663). The preview now offers four fighters or three fighters plus one turboprop cargo transport. The latter uses current model17 (ground25.3×30.25px); fighters use models19/20 within16.5×13.2px. The mixed passenger layout plus either military option totals19proposed positions (15terminal+4military).

Cargo replaces F1; it does not occupy that fighter position simultaneously. Model18 has a sampled parking fit but is not enabled pending access review; largest model16 found no fit in the checked apron geometry. This limited sampled check is not proof no alternative exists. Existing four access nodes are preserved; F3/F4 and cargo require explicit maneuver checks. Footprints were checked against approximate apron/hangar/through-lane geometry and each other; detailed photographic obstacles, actual sprite outlines and moving clearance remain subject to native validation. No operational routing has been activated.

The military dropdown, stand details, layout switching, footprint toggle and zoom were exercised in native WebKit; preview-fighters.png was captured and visually inspected. Game code and route draft remain unchanged.
