#!/bin/bash
set -euo pipefail

# Xcode supplies the UI test runner; the test app uses the production recognizer
# and ordinary SwiftUI controls so touches traverse the actual gesture arena.
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$RUNNER_TEMP/dock-gesture-ui-tests${LC_TEST_RUN_SUFFIX:-}"
project="$test_root/DockGestures.xcodeproj"
mkdir -p "$project/xcshareddata/xcschemes"

python3 - "$repo_root" "$test_root" <<'PY'
from pathlib import Path
import plistlib
import sys

repo, root = map(Path, sys.argv[1:])
project = root / 'DockGestures.xcodeproj'
(root / 'DockGestures-Bridging-Header.h').write_text(
    f'#import "{repo}/Tests/DockGestureDiagnostics.h"\n')
plistlib.dump({
    'CFBundleExecutable': '$(EXECUTABLE_NAME)',
    'CFBundleIdentifier': '$(PRODUCT_BUNDLE_IDENTIFIER)',
    'CFBundleName': '$(PRODUCT_NAME)',
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': '1.0', 'CFBundleVersion': '1',
    'LSRequiresIPhoneOS': True,
    'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': True,
        'UISceneConfigurations': {'UIWindowSceneSessionRoleApplication': [
            {'UISceneConfigurationName': 'DockGestures'}]}},
    'UILaunchScreen': {},
}, (root / 'HostInfo.plist').open('wb'))

sources = [
    ('H1', 'Tests/DockGestureTestHost.swift', 'sourcecode.swift'),
    ('H2', 'MultitaskSupport/DockRevealControl.m', 'sourcecode.c.objc'),
    ('H3', 'MultitaskSupport/MultitaskDockLayout.swift', 'sourcecode.swift'),
    ('H4', 'Tests/DockGestureDiagnostics.m', 'sourcecode.c.objc'),
    ('T1', 'Tests/DockGestureUITests.m', 'sourcecode.c.objc'),
]
# Explicit IDs keep the generated project small and stable in CI diagnostics.
names = ['project', 'mainGroup', 'productsGroup', 'hostProduct', 'testProduct',
         'hostTarget', 'testTarget', 'hostSources', 'testSources', 'projectConfigList',
         'hostConfigList', 'testConfigList', 'projectDebug', 'hostDebug', 'testDebug',
         'dependency', 'proxy'] + [name for source, _, _ in sources for name in (source, source + 'Build')]
ids = {name: f'{index:024X}' for index, name in enumerate(names, 1)}
objects = []
def obj(name, body):
    objects.append(f'{ids[name]} = {{ {body} }};')
for name, path, kind in sources:
    obj(name, f'isa = PBXFileReference; lastKnownFileType = {kind}; path = "{repo / path}"; sourceTree = "<absolute>";')
    obj(name + 'Build', f'isa = PBXBuildFile; fileRef = {ids[name]};')
obj('hostProduct', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = DockGestureTestHost.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj('testProduct', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = DockGestureUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
obj('productsGroup', f'isa = PBXGroup; name = Products; children = ({ids["hostProduct"]}, {ids["testProduct"]}); sourceTree = "<group>";')
obj('mainGroup', 'isa = PBXGroup; children = (' + ', '.join(ids[name] for name, _, _ in sources) + f', {ids["productsGroup"]}); sourceTree = "<group>";')
obj('hostSources', 'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (' + ', '.join(ids[name + 'Build'] for name, _, _ in sources if name.startswith('H')) + '); runOnlyForDeploymentPostprocessing = 0;')
obj('testSources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({ids["T1Build"]}); runOnlyForDeploymentPostprocessing = 0;')
obj('proxy', f'isa = PBXContainerItemProxy; containerPortal = {ids["project"]}; proxyType = 1; remoteGlobalIDString = {ids["hostTarget"]}; remoteInfo = DockGestureTestHost;')
obj('dependency', f'isa = PBXTargetDependency; target = {ids["hostTarget"]}; targetProxy = {ids["proxy"]};')
obj('hostTarget', f'isa = PBXNativeTarget; buildConfigurationList = {ids["hostConfigList"]}; buildPhases = ({ids["hostSources"]}); buildRules = (); dependencies = (); name = DockGestureTestHost; productName = DockGestureTestHost; productReference = {ids["hostProduct"]}; productType = "com.apple.product-type.application";')
obj('testTarget', f'isa = PBXNativeTarget; buildConfigurationList = {ids["testConfigList"]}; buildPhases = ({ids["testSources"]}); buildRules = (); dependencies = ({ids["dependency"]}); name = DockGestureUITests; productName = DockGestureUITests; productReference = {ids["testProduct"]}; productType = "com.apple.product-type.bundle.ui-testing";')
settings = {
    'projectDebug': 'CLANG_ENABLE_MODULES = YES; CLANG_ENABLE_OBJC_ARC = YES; SDKROOT = iphonesimulator; IPHONEOS_DEPLOYMENT_TARGET = 16.0; SWIFT_VERSION = 5.0; CODE_SIGNING_ALLOWED = NO; TARGETED_DEVICE_FAMILY = "1,2"; ONLY_ACTIVE_ARCH = YES; GCC_TREAT_WARNINGS_AS_ERRORS = YES; SWIFT_TREAT_WARNINGS_AS_ERRORS = YES;',
    'hostDebug': f'PRODUCT_NAME = "$(TARGET_NAME)"; PRODUCT_BUNDLE_IDENTIFIER = "com.livecontainer.tests.dock-gestures"; INFOPLIST_FILE = "{root / "HostInfo.plist"}"; SWIFT_OBJC_BRIDGING_HEADER = "{root / "DockGestures-Bridging-Header.h"}"; SWIFT_OPTIMIZATION_LEVEL = "-Onone"; SWIFT_INSTALL_OBJC_HEADER = NO; OTHER_LDFLAGS = "-framework SwiftUI -framework UIKit -framework WebKit";',
    'testDebug': 'PRODUCT_NAME = "$(TARGET_NAME)"; PRODUCT_BUNDLE_IDENTIFIER = "com.livecontainer.tests.dock-gestures.ui"; GENERATE_INFOPLIST_FILE = YES; TEST_TARGET_NAME = DockGestureTestHost; OTHER_LDFLAGS = "-framework XCTest";',
}
for name, values in settings.items():
    obj(name, f'isa = XCBuildConfiguration; name = Debug; buildSettings = {{ {values} }};')
for name, config in [('projectConfigList', 'projectDebug'), ('hostConfigList', 'hostDebug'), ('testConfigList', 'testDebug')]:
    obj(name, f'isa = XCConfigurationList; buildConfigurations = ({ids[config]}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;')
obj('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2620; TargetAttributes = {{ {ids["testTarget"]} = {{ TestTargetID = {ids["hostTarget"]}; }}; }}; }}; buildConfigurationList = {ids["projectConfigList"]}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {ids["mainGroup"]}; productRefGroup = {ids["productsGroup"]}; projectDirPath = ""; projectRoot = ""; targets = ({ids["hostTarget"]}, {ids["testTarget"]});')
(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(objects) + f'\n}}; rootObject = {ids["project"]}; }}\n')
def ref(target, product):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ids[target]}" BuildableName="{product}" BlueprintName="{product.split(".")[0]}" ReferencedContainer="container:DockGestures.xcodeproj"/>'
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2620" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{ref('hostTarget', 'DockGestureTestHost.app')}</BuildActionEntry>
<BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{ref('testTarget', 'DockGestureUITests.xctest')}</BuildActionEntry>
</BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ref('testTarget', 'DockGestureUITests.xctest')}</TestableReference></Testables></TestAction>
</Scheme>'''
(project / 'xcshareddata/xcschemes/DockGestures.xcscheme').write_text(scheme)
PY

simulator_id="$(xcrun simctl list devices available -j | python3 -c 'import json,sys; data=json.load(sys.stdin); devices=[d for group in data["devices"].values() for d in group if sys.argv[1] in d["name"]]; print(devices[0]["udid"])' "${LC_TEST_DEVICE_FAMILY:-iPad}")"
xcodebuild build-for-testing -project "$project" -scheme DockGestures -configuration Debug \
    -destination "platform=iOS Simulator,id=$simulator_id" -parallel-testing-enabled NO \
    -derivedDataPath "$test_root/DerivedData"
simulator_state="$(xcrun simctl list devices available -j | python3 -c 'import json,sys; data=json.load(sys.stdin); print(next(d["state"] for group in data["devices"].values() for d in group if d["udid"]==sys.argv[1]))' "$simulator_id")"
if [ "$simulator_state" != "Booted" ]; then xcrun simctl boot "$simulator_id"; fi
xcrun simctl bootstatus "$simulator_id" -b
set --
if [ -n "${LC_TEST_ONLY:-}" ]; then set -- "-only-testing:$LC_TEST_ONLY"; fi
xcodebuild test-without-building -project "$project" -scheme DockGestures -configuration Debug \
    -destination "platform=iOS Simulator,id=$simulator_id" -parallel-testing-enabled NO \
    -derivedDataPath "$test_root/DerivedData" -resultBundlePath "$test_root/results.xcresult" "$@"
