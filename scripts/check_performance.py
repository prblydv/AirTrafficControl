"""Reproducible optimized headless/window performance and state-parity harness."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import sys

project = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument("--root", type=Path, default=project)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--mode", choices=["simulation", "window", "checks"], default="simulation")
parser.add_argument("--compare", type=Path)
parser.add_argument("--check", help="Run one compiled regression instead of the full set")
parser.add_argument("--seconds", default="600")
parser.add_argument("--duration", default="30")
args = parser.parse_args()
names = ["Simulation", "DelhiGroundData", "AirportLayout", "AircraftCatalog", "GroundServices", "GroundTrafficPlanner", "AirportDefinition", "OperationalGraph", "SurfaceLayout", "RouteGraph", "AirportScene", "ContentView", "RouteEditorView"]
sources = [args.root / "AirTrafficControl" / (name + ".swift") for name in names]
sources.append(project / "Tests/PerformanceHarness.swift")
checks = ["OperationalGraphChecks", "AirportPackageChecks", "GroundTrafficPlannerChecks", "GroundTrafficLifecycleChecks", "GroundTrafficCompletionChecks", "ArrivalAndClimbChecks", "BlockedLandingExitChecks", "CongestionRoutingChecks", "ContinuousArrivalChecks", "CrowdedTowRecoveryChecks", "DepartureHoldClearanceChecks", "DirectNorthLandingExitChecks", "LandingExitSelectionChecks", "LocalTrafficFollowingChecks", "PlayerTugRerouteChecks", "RunwayFootprintCollisionChecks", "StandAllocationAndRelocationChecks", "AirportRenderingChecks", "CoreRenderingChecks", "LiveRenderingChecks"] if args.root.resolve() == project else []
digest = hashlib.sha256(b"atc-perf-v1")
digest.update(Path(__file__).read_bytes())
for path in sources:
    digest.update(str(path).encode()); digest.update(path.read_bytes())
for name in checks:
    digest.update((project / "Tests" / (name + ".swift")).read_bytes())
directory = Path(tempfile.gettempdir()) / ("atc-performance-" + digest.hexdigest()[:16])
app = directory / "PerformanceHarness.app"
executable = app / "Contents/MacOS/AirTrafficControl"
resources = app / "Contents/Resources"
marker = directory / "compiled"
if not marker.exists():
    executable.parent.mkdir(parents=True, exist_ok=True)
    resources.mkdir(parents=True, exist_ok=True)
    assets = Path("/tmp/AirTrafficControlOptimized/Build/Products/Release/AirTrafficControl.app/Contents/Resources/Assets.car")
    shutil.copy2(assets, resources / "Assets.car")
    shutil.copytree(args.root / "AirTrafficControl/Airports", resources / "Airports", dirs_exist_ok=True)
    with (app / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump({"CFBundleIdentifier": "com.prototype.delcontrol.performance", "CFBundleExecutable": "AirTrafficControl", "CFBundleName": "PerformanceHarness", "CFBundlePackageType": "APPL", "NSHighResolutionCapable": True}, stream)
    developer = subprocess.check_output(["xcode-select", "-p"], text=True).strip()
    plugins = Path(developer) / "Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
    generated = []
    flags = []
    if checks:
        flags = ["-D", "ATC_REGRESSION"]
        for name in checks:
            original = project / "Tests" / (name + ".swift")
            copy = directory / original.name
            copy.write_text(original.read_text().replace("@main struct", "struct").replace("#filePath", json.dumps(str(original))))
            generated.append(copy)
        runner = directory / "Regressions.swift"
        calls = "\n".join(f'if filter == "{name}" {{ print("RUN:{name}"); try {name}.main() }}' for name in checks)
        runner.write_text('import Foundation\nextension PerformanceHarness { @MainActor static func regressionChecks() throws {\nlet filter=ProcessInfo.processInfo.environment["ATC_CHECK_FILTER"] ?? ""\n' + calls + "\n} }\n")
        generated.append(runner)
    subprocess.run(["swiftc", "-O", "-D", "DEBUG", *flags, "-parse-as-library", "-plugin-path", str(plugins), *map(str, sources), *map(str, generated), "-o", str(executable)], check=True, cwd=args.root)
    marker.write_text(digest.hexdigest())
args.output.parent.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, ATC_PERF_MODE=args.mode, ATC_PERF_SECONDS=args.seconds, ATC_PERF_DURATION=args.duration, ATC_PERF_OUTPUT=str(args.output.resolve()))
if args.mode == "checks":
    results = {}
    for name in ([args.check] if args.check else checks):
        if name not in checks:
            raise SystemExit("Unknown check: " + str(name))
        result = subprocess.run([str(executable)], env=dict(env, ATC_CHECK_FILTER=name), cwd=args.root)
        results[name] = result.returncode == 0
    args.output.write_text(json.dumps(results, indent=2) + "\n")
    print("REGRESSIONS:", json.dumps(results, sort_keys=True))
    if not all(results.values()):
        raise SystemExit("Regression failures: " + ", ".join(k for k, v in results.items() if not v))
else:
    subprocess.run([str(executable)], env=env, check=True, cwd=args.root)
if args.compare:
    baseline = json.loads(args.compare.read_text())
    result = json.loads(args.output.read_text())
    if result.get("state_sha256") != baseline.get("state_sha256"):
        raise SystemExit("REGRESSION: deterministic simulation state differs from baseline")
    print("PASS: deterministic simulation state exactly matches baseline")
