"""Register runway pins using package data; never edit the user's saved draft."""
from pathlib import Path
import json, math, sys
root = Path(__file__).resolve().parent.parent
folder = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "AirTrafficControl/Airports/delhi"
definition_path = folder / "airport.json"
airport = json.loads(definition_path.read_text())
path = folder / airport["routesFile"]
graph = json.loads(path.read_text())
graph["pins"] = [pin for pin in graph["pins"] if not pin["id"].startswith(("rollout-", "exit-", "hold-", "lineup-"))]
points = [node["point"] for node in graph["nodes"] if node["layer"] == "Aircraft taxiways"]
for runway in airport["runways"]:
    a, b = runway["start"], runway["end"]
    dx, dy = b["x"] - a["x"], b["y"] - a["y"]
    length = math.hypot(dx, dy)
    def point(t, side=0):
        return (a["x"] + dx*t - dy/length*side, a["y"] + dy*t + dx/length*side)
    for name, target in [("rollout", point(.74)), ("exit", point(.82, 28)), ("hold", point(.04, 24)), ("lineup", point(.06))]:
        candidates = points
        if name in ("exit", "hold"):
            candidates = [p for p in points if 19 < abs((p["x"]-a["x"])*dy - (p["y"]-a["y"])*dx)/length < 65]
        if not candidates:
            raise ValueError(f"No traced {name} candidate for runway {runway['id']}")
        near = min(candidates, key=lambda p: math.dist((p["x"], p["y"]), target))
        graph["pins"].append({"id": f"{name}-{runway['id']}", "point": near})
        if name in ("hold", "exit"):
            runway[name] = near
path.write_text(json.dumps(graph, separators=(",", ":")))
definition_path.write_text(json.dumps(airport, indent=2) + "\n")
# Historical Delhi tools read this mirror; new airports use their own package.
if airport["identity"]["id"] == "delhi":
    (root / "AirTrafficControl/airport-routes.json").write_bytes(path.read_bytes())
print("Registered runway access pins in", folder)
