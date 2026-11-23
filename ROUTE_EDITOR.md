# Temporary Mac route editor

This is a development tool, compiled only for **macOS Debug**. It is excluded from iOS and all Release builds. The game can later consume the verified JSON as bundled route data; players do not get an editor.

## Open

Run the Mac Debug app and click **Dev routes**, or launch directly:

```sh
open -n build/Build/Products/Debug/AirTrafficControl.app --args --route-editor
```

## Trace

1. Choose **Aircraft taxiways** or **Vehicle roads**. Existing lines are rough guides, not verified pavement; clear the layer if starting fresh.
2. Use **Draw**: click to place nodes and connect consecutive points. Click an existing node to join it. Click an edge to split it into a junction. **Break chain** starts a separate path.
3. Use **Move** to drag a node, **Select** and **D** (or **Delete**) to remove a node/edge, and **Undo/Redo** to correct edits. Lines crossing without a shared node do not create a junction.
4. Pinch or use +/− to zoom up to8×. Two-finger trackpad dragging pans with any tool selected. Choose **Pan** for mouse-drag panning; **Fit** restores the whole airport.
5. In the vehicle layer, choose the preview vehicle. **All vehicles** / **Only this one** set permissions for new edges. Select an existing edge and use **Set permissions on selected edge** to change it.
6. Use **Test route** and click a start node then a destination. The green route and moving dot follow Dijkstra routing for the selected vehicle. Disconnected/prohibited routes fail instead of taking a straight shortcut.
7. Use **Landmark** to reposition gate parking centres, nose points, pushback/taxi joins, runway holds/exits/line-up points, or vehicle parking. Connect each moved point to the traced graph. Parking centre→nose defines the parked aircraft's direction. For aircraft, trace stand→taxi join (pushback), join→holding point, holding point→line-up, rollout→exit, and exit→gate. Vehicle roads need stand access as well as depot access.

## Save and review

**Save draft** preserves edits locally; closing the editor also saves the draft. **Export JSON** creates a portable file using the Mac save dialog. **Import JSON** restores it. **Apply & new shift** activates the draft in the Mac development build and restarts the preview simulation. The former dashed boundary and its tracing/activation restriction have been removed. You can trace any pavement within the image. iOS/Release builds ignore development drafts.

Drafts and development previews live in the Debug app's Application Support/DELControl directory (`draft-routes.json`, `active-routes.json`). They are separate from the repository. Keep an exported JSON copy when sharing or moving between Macs. After visual review, verified data can be packaged as `airport-routes.json` in the game's resources; this has not been done yet because the precise routes still need tracing.

Ground response points are constrained to airport roads. Off-field airborne incidents put crews at an airport access/standby point instead of sending them through the city. Missing connections stop dispatch rather than teleport a vehicle. Explicit traced edges define permitted travel, so check every segment against the photograph.

## Verification

`Tests/RouteEditorChecks.swift`: draw/connect/split, undo/redo/delete, vehicle permissions and shortest paths, JSON round-trip, activation/pin use, no long off-network connectors, and native editor rendering. Compile with `-D DEBUG` on Mac, including RouteGraph.swift and RouteEditorView.swift plus the shared simulation files. `art/route-editor-native-preview.png` is the native control-and-map preview.
