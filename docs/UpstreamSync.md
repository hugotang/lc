# Upstream sync — 3.8.39

Merged `LiveContainer/LiveContainer` main through `9d6ea09b05afa2c8fc537c372795a294db631311`, checked on 2026-11-09. This includes all four upstream commits since `9108ae6`: the browser/help refresh, background continued-processing identifier fix, build configuration update, and helper-process support.

The fork keeps its working GitHub-hosted macOS/Xcode 26.2 build configuration. Upstream's `xcode-27` runner label is specific to its build environment. Upstream browser APIs have iOS availability checks; the release build verifies compatibility with the retained toolchain.

Custom location, compact joystick, live shortcut switching, fixed aspect ratios, audio options, workspaces, Dock and Input Sync remain present. The version is 3.8.39 rather than upstream's 3.8.13 so this installation upgrades monotonically.

Replacing an installed guest now snapshots its ratio/audio/location preferences before removing the old bundle. It restores those values to the incoming bundle before constructing its settings model. Location revision, favorites and shortcut preference stay together; absent choices remain absent, and signing/patch metadata comes from the new bundle. A regression test verifies preservation and property-list round trips.

Helper Process Support is upstream's opt-in support for guest JIT helpers and RAM donors in ordinary launches. It is not enabled in LiveProcess multitasking guests. Helpers are patched before signing when enabled, using a separate patch revision so already-installed apps are prepared on their next launch. A pending-sign flag survives failures so a valid main-executable signature cannot skip retrying the changed helpers. Disabled support leaves unused extensions alone, avoiding launch failures from encrypted extensions in otherwise usable apps. Real-device helper/XPC behavior still requires validation with an app that uses such an extension.

The new background processing option retains upstream's scope and defaults. Device checks should include a helper-enabled app, background processing, browser navigation/downloads, an IPA replacement retaining Custom 11:16 and location settings, and existing multi-account game flows.
