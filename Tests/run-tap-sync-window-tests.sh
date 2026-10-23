#!/bin/bash
set -euo pipefail

# A small UIKit test host avoids building the private-API app for the simulator.
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$RUNNER_TEMP/tap-sync-window-tests"
mkdir -p "$test_root"
sdk_path="$(xcrun --sdk iphonesimulator --show-sdk-path)"
test_frameworks="$(xcode-select -p)/Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks"
test_libraries="$(xcode-select -p)/Platforms/iPhoneSimulator.platform/Developer/usr/lib"
simulator_id="$(xcrun simctl list devices available -j | python3 -c 'import json,sys; data=json.load(sys.stdin); devices=[d for group in data["devices"].values() for d in group if "iPad" in d["name"]]; print(devices[0]["udid"])')"
app="$test_root/TapSyncTests.app"
bundle="$app/PlugIns/TapSyncWindowTests.xctest"
mkdir -p "$bundle"

python3 - "$app" "$bundle" "$test_libraries" <<'PY'
import pathlib, plistlib, sys
app, bundle, libraries = map(pathlib.Path, sys.argv[1:])
plistlib.dump({
    'CFBundleIdentifier': 'com.livecontainer.tests.tap-sync-window',
    'CFBundleExecutable': 'TapSyncTests', 'CFBundleName': 'TapSyncTests',
    'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
    'LSRequiresIPhoneOS': True, 'MinimumOSVersion': '16.0', 'UIDeviceFamily': [1, 2],
    'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': True,
        'UISceneConfigurations': {'UIWindowSceneSessionRoleApplication': [{'UISceneConfigurationName': 'Tests'}]}},
}, (app / 'Info.plist').open('wb'))
plistlib.dump({
    'CFBundleIdentifier': 'com.livecontainer.tests.tap-sync-window.bundle',
    'CFBundleExecutable': 'TapSyncWindowTests', 'CFBundleName': 'TapSyncWindowTests',
    'CFBundlePackageType': 'BNDL', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
}, (bundle / 'Info.plist').open('wb'))
config = {'TapSyncWindowTests': {
    'TestHostPath': str(app), 'TestBundlePath': str(bundle),
    'TestHostBundleIdentifier': 'com.livecontainer.tests.tap-sync-window',
    'ProductModuleName': 'TapSyncWindowTests', 'IsAppHostedTestBundle': True,
    'TestingEnvironmentVariables': {
        'DYLD_INSERT_LIBRARIES': str(libraries / 'libXCTestBundleInject.dylib'),
        'XCInjectBundleInto': '__TESTHOST__/TapSyncTests',
    },
}, '__xctestrun_metadata__': {'FormatVersion': 1}}
plistlib.dump(config, (app.parent / 'TapSyncWindowTests.xctestrun').open('wb'))
PY

xcrun clang -target arm64-apple-ios16.0-simulator -isysroot "$sdk_path" -fobjc-arc -Wall -Wextra -Werror \
    -Wno-unused-parameter -framework UIKit -framework Foundation \
    "$repo_root/Tests/TapSyncWindowTestHost.m" -o "$app/TapSyncTests"
xcrun clang -target arm64-apple-ios16.0-simulator -isysroot "$sdk_path" -fobjc-arc -Wall -Wextra -Werror \
    -fmodules -Wno-nullability-completeness -Wno-unused-parameter -bundle -F "$test_frameworks" -L "$test_libraries" \
    -framework UIKit -framework Foundation -framework CoreGraphics -framework QuartzCore -framework XCTest -lXCTestSwiftSupport \
    -Wl,-rpath,"$test_frameworks" -Wl,-rpath,"$test_libraries" \
    -I "$repo_root/LiveContainer" \
    "$repo_root/TweakLoader/TapSyncWindow.m" "$repo_root/Tests/TapSyncWindowTests.m" \
    "$repo_root/MultitaskSupport/TapSyncCoordinator.m" "$repo_root/MultitaskSupport/TapSyncRecovery.m" \
    "$repo_root/MultitaskSupport/TapSyncSession.m" "$repo_root/MultitaskSupport/TapSyncSelection.m" \
    "$repo_root/MultitaskSupport/WindowWorkspace.m" "$repo_root/Tests/TapSyncCoordinatorTests.m" \
    "$repo_root/TweakLoader/TapSyncClientState.m" "$repo_root/TweakLoader/TapSyncReturnGesture.m" \
    "$repo_root/Tests/TapSyncClientTests.m" \
    "$repo_root/MultitaskSupport/WindowChromeLayout.m" "$repo_root/Tests/WindowChromeLayoutTests.m" \
    "$repo_root/MultitaskSupport/DockRevealControl.m" "$repo_root/Tests/DockRevealControlTests.m" \
    -o "$bundle/TapSyncWindowTests"
codesign --force --sign - "$bundle"
codesign --force --sign - "$app"
# Finish SpringBoard's cold boot before XCTest starts timing UI expectations.
xcrun simctl boot "$simulator_id"
xcrun simctl bootstatus "$simulator_id" -b
xcodebuild test-without-building -xctestrun "$test_root/TapSyncWindowTests.xctestrun" \
    -destination "platform=iOS Simulator,id=$simulator_id" -parallel-testing-enabled NO \
    -resultBundlePath "$test_root/results.xcresult"
