"""Regenerate the dependency-free, shared iOS/macOS Xcode project."""
from pathlib import Path
root = Path(__file__).resolve().parent.parent
project = root / 'AirTrafficControl.xcodeproj'
project.mkdir(exist_ok=True)
files = ['AirTrafficControlApp.swift', 'Simulation.swift', 'AirportScene.swift', 'ContentView.swift', 'DelhiGroundData.swift', 'AirportLayout.swift', 'AircraftCatalog.swift', 'GroundServices.swift', 'GroundTrafficPlanner.swift', 'AirportDefinition.swift', 'OperationalGraph.swift', 'SurfaceLayout.swift', 'RouteGraph.swift', 'RouteEditorView.swift']
refs = '\n'.join(f'F{i:023d} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};' for i, name in enumerate(files, 1))
build = '\n'.join(f'B{i:023d} = {{isa = PBXBuildFile; fileRef = F{i:023d}; }};' for i in range(1, len(files) + 1))
children = ', '.join(f'F{i:023d}' for i in range(1, len(files) + 1))
sources = ', '.join(f'B{i:023d}' for i in range(1, len(files) + 1))
(project / 'project.pbxproj').write_text('''// !$*UTF8*$!
{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {
''' + refs + '\n' + build + '''
F00000000000000000000097 = {isa = PBXFileReference; lastKnownFileType = folder; path = Airports; sourceTree = "<group>"; };
B00000000000000000000097 = {isa = PBXBuildFile; fileRef = F00000000000000000000097; };
F00000000000000000000098 = {isa = PBXFileReference; lastKnownFileType = text.json; path = airport-routes.json; sourceTree = "<group>"; };
B00000000000000000000098 = {isa = PBXBuildFile; fileRef = F00000000000000000000098; };
F00000000000000000000099 = {isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; };
B00000000000000000000099 = {isa = PBXBuildFile; fileRef = F00000000000000000000099; };

A00000000000000000000001 = {isa = PBXProject; attributes = {LastUpgradeCheck = 2700; }; buildConfigurationList = A00000000000000000000002; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en, Base); mainGroup = A00000000000000000000003; productRefGroup = A00000000000000000000005; projectDirPath = ""; projectRoot = ""; targets = (A00000000000000000000006); };
A00000000000000000000002 = {isa = XCConfigurationList; buildConfigurations = (A00000000000000000000010, A00000000000000000000011); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
A00000000000000000000003 = {isa = PBXGroup; children = (A00000000000000000000004, A00000000000000000000005); sourceTree = "<group>"; };
A00000000000000000000004 = {isa = PBXGroup; children = (''' + children + ''', F00000000000000000000097, F00000000000000000000098, F00000000000000000000099); path = AirTrafficControl; sourceTree = "<group>"; };
A00000000000000000000005 = {isa = PBXGroup; children = (A00000000000000000000007); name = Products; sourceTree = "<group>"; };
A00000000000000000000006 = {isa = PBXNativeTarget; buildConfigurationList = A00000000000000000000008; buildPhases = (A00000000000000000000009, A00000000000000000000012, A00000000000000000000013); buildRules = (); dependencies = (); name = AirTrafficControl; productName = AirTrafficControl; productReference = A00000000000000000000007; productType = "com.apple.product-type.application"; };
A00000000000000000000007 = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = AirTrafficControl.app; sourceTree = BUILT_PRODUCTS_DIR; };
A00000000000000000000008 = {isa = XCConfigurationList; buildConfigurations = (A00000000000000000000014, A00000000000000000000015); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
A00000000000000000000009 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (''' + sources + '''); runOnlyForDeploymentPostprocessing = 0; };
A00000000000000000000012 = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
A00000000000000000000013 = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (B00000000000000000000097, B00000000000000000000098, B00000000000000000000099); runOnlyForDeploymentPostprocessing = 0; };
'''+ '\n'.join(f'''A000000000000000000000{n} = {{isa = XCBuildConfiguration; name = {name}; buildSettings = {{CLANG_ENABLE_MODULES = YES; SWIFT_VERSION = 5.0; SWIFT_STRICT_CONCURRENCY = complete; MACOSX_DEPLOYMENT_TARGET = 14.0; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SDKROOT = auto; {extra} }}; }};''' for n, name, extra in [('10','Debug','SWIFT_OPTIMIZATION_LEVEL = "-Onone"; DEBUG_INFORMATION_FORMAT = dwarf; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;'), ('11','Release','SWIFT_COMPILATION_MODE = wholemodule;')]) + '\n' + '\n'.join(f'''A000000000000000000000{n} = {{isa = XCBuildConfiguration; name = {name}; buildSettings = {{PRODUCT_BUNDLE_IDENTIFIER = com.prototype.delcontrol; PRODUCT_NAME = "$(TARGET_NAME)"; GENERATE_INFOPLIST_FILE = YES; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx"; TARGETED_DEVICE_FAMILY = "1,2"; CODE_SIGN_STYLE = Automatic; ENABLE_APP_SANDBOX = YES; ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES; "CODE_SIGN_ENTITLEMENTS[sdk=macosx*]" = AirTrafficControl/{'AirTrafficControl.debug.entitlements' if name == 'Debug' else 'AirTrafficControl.entitlements'}; ENABLE_HARDENED_RUNTIME = YES; INFOPLIST_KEY_CFBundleDisplayName = "DEL Control"; INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.simulation-games"; INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES; INFOPLIST_KEY_UILaunchScreen_Generation = YES; INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight UIInterfaceOrientationPortrait"; INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown"; MARKETING_VERSION = 0.1.0; CURRENT_PROJECT_VERSION = 1; }}; }};''' for n, name in [('14','Debug'), ('15','Release')]) + '''
}; rootObject = A00000000000000000000001; }
''')
schemes = project / 'xcshareddata/xcschemes'
schemes.mkdir(parents=True, exist_ok=True)
(schemes / 'AirTrafficControl.xcscheme').write_text('''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A00000000000000000000006" BuildableName="AirTrafficControl.app" BlueprintName="AirTrafficControl" ReferencedContainer="container:AirTrafficControl.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A00000000000000000000006" BuildableName="AirTrafficControl.app" BlueprintName="AirTrafficControl" ReferencedContainer="container:AirTrafficControl.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A00000000000000000000006" BuildableName="AirTrafficControl.app" BlueprintName="AirTrafficControl" ReferencedContainer="container:AirTrafficControl.xcodeproj"/></BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print('Created AirTrafficControl.xcodeproj')
