"""Regenerate the self-contained Xcode project; Python standard library only."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parent
def uid(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def quoted(value):
    return json.dumps(value)

objects = {}
def add(name, value):
    objects[uid(name)] = value
    return uid(name)
sources = sorted((ROOT / "GMSchedule").glob("*.swift"))
tests = sorted((ROOT / "GMScheduleTests").glob("*.swift"))
for path in sources + tests:
    key = str(path.relative_to(ROOT)).replace("\\", "/")
    add(key, '{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ' + quoted(path.name) + '; sourceTree = "<group>"; }')
    add(key + "Build", '{isa = PBXBuildFile; fileRef = ' + uid(key) + '; }')
add("Assets", '{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; }')
add("AssetsBuild", '{isa = PBXBuildFile; fileRef = ' + uid("Assets") + '; }')
add("AppProduct", '{isa = PBXFileReference; explicitFileType = wrapper.application; path = GMSchedule.app; sourceTree = BUILT_PRODUCTS_DIR; }')
add("TestProduct", '{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = GMScheduleTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }')
add("SoupBuild", '{isa = PBXBuildFile; productRef = ' + uid("SoupProduct") + '; }')
add("SoupProduct", '{isa = XCSwiftPackageProductDependency; package = ' + uid("SoupPackage") + '; productName = SwiftSoup; }')
add("SoupPackage", '{isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/scinfu/SwiftSoup.git"; requirement = {kind = exactVersion; version = 2.13.5; }; }')
for name, paths, extras in [("AppGroup", sources, [uid("Assets")]), ("TestGroup", tests, [])]:
    children = [uid(str(p.relative_to(ROOT)).replace("\\", "/")) for p in paths] + extras
    add(name, '{isa = PBXGroup; children = (' + ','.join(children) + '); path = ' + ("GMSchedule" if name == "AppGroup" else "GMScheduleTests") + '; sourceTree = "<group>"; }')
add("ProductsGroup", '{isa = PBXGroup; name = Products; children = (' + uid("AppProduct") + ',' + uid("TestProduct") + '); sourceTree = "<group>"; }')
add("RootGroup", '{isa = PBXGroup; children = (' + ','.join(uid(n) for n in ["AppGroup", "TestGroup", "ProductsGroup"]) + '); sourceTree = "<group>"; }')
for name, paths in [("AppSources", sources), ("TestSources", tests)]:
    add(name, '{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (' + ','.join(uid(str(p.relative_to(ROOT)).replace("\\", "/") + "Build") for p in paths) + '); runOnlyForDeploymentPostprocessing = 0; }')
for name, isa, files in [("AppResources", "PBXResourcesBuildPhase", ["AssetsBuild"]), ("AppFrameworks", "PBXFrameworksBuildPhase", ["SoupBuild"]), ("TestResources", "PBXResourcesBuildPhase", []), ("TestFrameworks", "PBXFrameworksBuildPhase", [])]:
    add(name, '{isa = ' + isa + '; buildActionMask = 2147483647; files = (' + ','.join(uid(n) for n in files) + '); runOnlyForDeploymentPostprocessing = 0; }')
add("Proxy", '{isa = PBXContainerItemProxy; containerPortal = ' + uid("Project") + '; proxyType = 1; remoteGlobalIDString = ' + uid("AppTarget") + '; remoteInfo = GMSchedule; }')
add("Dependency", '{isa = PBXTargetDependency; target = ' + uid("AppTarget") + '; targetProxy = ' + uid("Proxy") + '; }')
for name, product, phases, dependency, package in [("App", "AppProduct", ["AppSources", "AppFrameworks", "AppResources"], [], ["SoupProduct"]), ("Test", "TestProduct", ["TestSources", "TestFrameworks", "TestResources"], ["Dependency"], [])]:
    add(name + "Target", '{isa = PBXNativeTarget; buildConfigurationList = ' + uid(name + "ConfigList") + '; buildPhases = (' + ','.join(uid(n) for n in phases) + '); buildRules = (); dependencies = (' + ','.join(uid(n) for n in dependency) + '); name = ' + ("GMSchedule" if name == "App" else "GMScheduleTests") + '; packageProductDependencies = (' + ','.join(uid(n) for n in package) + '); productName = ' + ("GMSchedule" if name == "App" else "GMScheduleTests") + '; productReference = ' + uid(product) + '; productType = ' + quoted("com.apple.product-type.application" if name == "App" else "com.apple.product-type.bundle.unit-test") + '; }')
for target in ["Project", "App", "Test"]:
    for configuration in ["Debug", "Release"]:
        settings = {"SWIFT_VERSION": "5.0", "IPHONEOS_DEPLOYMENT_TARGET": "15.0", "SDKROOT": "iphoneos", "CLANG_ENABLE_MODULES": "YES", "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if configuration == "Debug" else "-O", "DEBUG_INFORMATION_FORMAT": "dwarf" if configuration == "Debug" else "dwarf-with-dsym"}
        if configuration == "Debug": settings.update({"ENABLE_TESTABILITY": "YES", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG"})
        if target != "Project":
            settings.update({"TARGETED_DEVICE_FAMILY": "1,2", "CODE_SIGN_STYLE": "Automatic", "PRODUCT_NAME": "$(TARGET_NAME)", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "SUPPORTS_MACCATALYST": "NO"})
        if target == "App":
            settings.update({"PRODUCT_BUNDLE_IDENTIFIER": "cn.gdgm.schedule.gdgmSchedule", "INFOPLIST_FILE": "GMSchedule/Info.plist", "MARKETING_VERSION": "3.0.0", "CURRENT_PROJECT_VERSION": "20", "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks"})
        if target == "Test":
            settings.update({"PRODUCT_BUNDLE_IDENTIFIER": "cn.gdgm.schedule.gdgmSchedule.tests", "GENERATE_INFOPLIST_FILE": "YES", "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/GMSchedule.app/GMSchedule", "BUNDLE_LOADER": "$(TEST_HOST)"})
        add(target + configuration, '{isa = XCBuildConfiguration; buildSettings = {' + ' '.join(f'{k} = {quoted(v)};' for k, v in settings.items()) + '}; name = ' + configuration + '; }')
    add(target + "ConfigList", '{isa = XCConfigurationList; buildConfigurations = (' + uid(target + "Debug") + ',' + uid(target + "Release") + '); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }')
add("Project", '{isa = PBXProject; attributes = {BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1600; }; buildConfigurationList = ' + uid("ProjectConfigList") + '; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh_CN; hasScannedForEncodings = 0; knownRegions = (zh_CN,en,Base); mainGroup = ' + uid("RootGroup") + '; productRefGroup = ' + uid("ProductsGroup") + '; projectDirPath = ""; projectRoot = ""; packageReferences = (' + uid("SoupPackage") + '); targets = (' + uid("AppTarget") + ',' + uid("TestTarget") + '); }')
project = ROOT / "GMSchedule.xcodeproj"
project.mkdir(exist_ok=True)
(project / "project.pbxproj").write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(f'{key} = {value};' for key, value in objects.items()) + '\n}; rootObject = ' + uid("Project") + '; }\n', encoding="utf-8")
schemes = project / "xcshareddata" / "xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
app_ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("AppTarget")}" BuildableName="GMSchedule.app" BlueprintName="GMSchedule" ReferencedContainer="container:GMSchedule.xcodeproj"/>'
test_ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("TestTarget")}" BuildableName="GMScheduleTests.xctest" BlueprintName="GMScheduleTests" ReferencedContainer="container:GMSchedule.xcodeproj"/>'
(schemes / "GMSchedule.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app_ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{test_ref}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>
''', encoding="utf-8")
print(f"Generated {project} ({len(sources)} app files, {len(tests)} test files)")
