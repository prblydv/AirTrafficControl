"""Compile shared Swift once and run the selected ground-traffic regressions."""
from pathlib import Path
import json
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
names = sys.argv[1:] or ["OperationalGraphChecks", "AirportPackageChecks", "GroundTrafficPlannerChecks", "ATCAuthorityChecks", "SurfaceSafetyChecks", "GroundTrafficLifecycleChecks", "GroundTrafficCompletionChecks"]
sources = ["Simulation", "DelhiGroundData", "AirportLayout", "AircraftCatalog", "GroundServices", "GroundTrafficPlanner", "AirportDefinition", "OperationalGraph", "SurfaceLayout", "RouteGraph"]
if any(name in {"AirportRenderingChecks", "CoreRenderingChecks"} for name in names):
    sources.append("AirportScene")
if "RouteEditorChecks" in names:
    sources.append("RouteEditorView")
with tempfile.TemporaryDirectory(prefix="atc-traffic-checks-") as work:
    directory = Path(work)
    paths = [root / "AirTrafficControl" / (name + ".swift") for name in sources]
    for name in names:
        original = root / "Tests" / (name + ".swift")
        copy = directory / original.name
        copy.write_text(original.read_text().replace("@main struct", "struct").replace("#filePath", json.dumps(str(original))))
        paths.append(copy)
    runner = directory / "Run.swift"
    calls = "\n".join(f'print("RUN:{name}"); try {name}.main()' for name in names)
    runner.write_text("import Foundation\n@main struct Checks { @MainActor static func main() throws {\n" + calls + "\n} }\n")
    executable = directory / "checks"
    subprocess.run(["swiftc", "-O", "-D", "DEBUG", "-parse-as-library", *map(str, paths), str(runner), "-o", str(executable)], cwd=root, check=True)
    subprocess.run([str(executable)], cwd=root, check=True)
