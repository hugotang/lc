# Issue fixes following upstream sync

Version **3.8.47** addresses upstream issues #1741, #1573, #1195 and #729 on top of `3f503ab`.

## Native window termination (#1741)

Terminated native windows have a **Restart App** button. **Skip Terminated Screen** and **Restart App Automatically After Termination** are available in both multitasking modes. Native recovery reuses its system window while going through the existing signing, selected-container and JIT launch flow. Recovery waits until the scene is active. A failed startup or a guest that exits within two seconds retains its error/retry screen. Automatic retries stop after three attempts within one minute; a deliberate manual retry resets that allowance.

Native sessions own their launch callbacks and attempt identities. An old callback cannot complete a newer attempt. Manual close cancels pending recovery, including a restart waiting for signing or main-queue launch. Closing guests retain their container reservation until cleanup; cleanup only removes the matching extension request. Native recovery requests are serialized and wait up to 30 seconds for an existing app launch/signing operation.

The host process being killed loses these in-memory sessions. Restored system windows then return to the main app; this change does not persist or silently relaunch guests after a full host restart.

## App filters (#1573)

The app list's sort menu also selects **All Apps**, **Shared Apps** or **Private Apps**, with a separate **Requires JIT** toggle. Filters compose with the existing name/bundle-ID search and preserve sorting. The JIT condition includes 32-bit apps, matching the launch path. Choices persist in shared preferences. Locked hidden-app placeholders are not filtered by private metadata; unlocked apps use the same predicates as the main list.

## Legacy window enumeration (#1195)

Only LiveProcess guests receive the `UIApplication.windows` compatibility hook. A nonempty original array is preserved. Empty main-thread results may fall back to windows from one unambiguous application scene on the main screen, preferring a foreground scene. Foreign, external-display, unattached and auxiliary-level windows are excluded; the visible key window comes first and results are deduplicated. Ambiguous scenes, background-thread queries and recursive UIKit reads retain the original result. No window is fabricated.

This addresses the reported empty legacy enumeration path. It does not establish that every affected enterprise app is fixed without checking that app on a device.

## Fullscreen status bar (#729)

**Hide Status Bar in Multitask Full Screen** is an optional, initially disabled setting for virtual windows. The main SwiftUI host hides its status bar only for its own active scene when the front visible guest is running, maximized and the Dock is collapsed. Restoring controls, minimizing, entering PiP, terminating the guest or bringing a smaller window to the front restores the normal policy. Native windows retain their own status-bar handling. This is a user-selected fullscreen policy, not automatic forwarding of each guest's status-bar preference.

## Validation

`NativeWindowStateTests.swift` exercises stale completions, one-shot startup completion, failed/short launches, close suppression, retry limits and replacement-request cleanup. The existing build workflow compiles and runs it on macOS. `GuestWindowsTests.m` is wired into the existing iPad simulator suite and exercises foreground/background enumeration, preservation of original results, scene ambiguity, external scenes, auxiliary windows, ordering and deduplication.

Source commit `2ffed3de100a2d54286ab7f645bb120746192cc3` passed [macOS CI 45567521384](https://github.com/hugotang/lc/actions/runs/45567521384) on the first attempt with Xcode 26.2. All 18 command-line test steps passed, including native recovery, helper v2 transport, signing/preferences and workspace checks. The Release archive and both IPA variants succeeded. All **226 simulator test executions** passed: input/window tests (190 iPad, including five new legacy-window cases, plus seven iPhone), Dock gestures (14 iPad plus one iPhone) and custom location (seven per device). Nightly release was skipped.

Both downloaded IPAs identify version **3.8.47** and source `2ffed3d`. Package verification passed ZIP CRC, source/version markers, main/LiveProcess/shared-framework executables, OpenSSL 3.6.5000, Music Haptics declarations and absence of test artifacts. The SideStore variant also passed embedded SideStoreSupport/SideStoreApp and app-group checks. English, Simplified Chinese and Traditional Chinese strings were checked inside the compiled package. The local Windows checks covered source parsing, localization JSON, workflow YAML, shell syntax and diff whitespace. The build still emits existing helper-fixture warnings; it is not a warning-free build.

These results cover compilation, fixtures and package identity. Native PluginKit/scene lifecycle, the reported enterprise app and fullscreen status-bar behavior have **not** been verified on a device. The delivered IPA remains bound to `2ffed3d`; a later documentation-only commit does not change its tested source.

Before accepting the changes on a device:

- Native windows: kill a guest in the background, return and use Restart App; repeat with each recovery toggle combination. Test signing/JIT failure, rapid crashes, two accounts recovering together, and closing while signing or waiting for JIT. A closed window must stay closed; another account's callback must not complete its request. Repeat after a full host-process restart.
- Filters: combine each storage choice with Requires JIT and name/bundle-ID searches; toggle JIT or move an app between storage locations, then return to the list. Test 32-bit apps, no matches, persistence and locked/unlocked hidden apps.
- Legacy windows: compare `UIApplication.windows` and `UIWindowScene.windows` in a minimal legacy guest before/background/after activation. Test the affected enterprise app if available, native/virtual windows, another normal guest and an external display. The original nonempty array must remain unchanged.
- Status bar: enable the option, maximize and collapse Dock; then expand Dock, minimize, enter/exit PiP, terminate, rotate, background/foreground and focus a smaller window. Check the settings UI, native windows, sheets and guest touch coordinates. The default-disabled option must retain existing behavior.
