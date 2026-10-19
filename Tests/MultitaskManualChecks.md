# Device checks for multitasking changes

The standalone tests cover geometry, ordering, workspace serialization, localization selection and symbol-cache validation. AVKit transitions and private guest-scene APIs also need these checks on an iPhone and iPad; a successful archive does not exercise them.

- Terminate a maximized app with the Dock collapsed, with the window bar at the top and bottom. Check that close, minimize and restore remain usable, then rotate and maximize again. Repeat with grid bars hidden and with “Skip Terminated Screen” enabled.
- With automatic tiling both on and off, open and dismiss a docked keyboard in windows near the bottom of the screen. Verify text remains visible and the original geometry and custom grid proportions return. Repeat after rotation, minimize/restore, changing the keyboard preference, and with a floating or hardware keyboard.
- Enter PiP with a software keyboard open. Check that the PiP window uses the full screen and the keyboard remains dismissed after returning. Repeat with a hardware keyboard to check retained focus. Switch PiP between two apps quickly, stop during startup, close the guest, and exercise an AVKit startup failure; no window should remain hidden or frozen.
- Save a workspace with several apps and two containers of the same app. Change their order and scale, restart LiveContainer, and restore from Settings. Check both orientations' saved divider proportions and that unrelated running windows remain open.
- Restore when a saved app or container has been deleted, a saved window is terminated/minimized/in PiP, one app fails to launch, or an app has switched to classic mode. Check partial results, no duplicate windows and no launch into another container. Verify locked/hidden apps require authentication and canceling authentication launches nothing.
- Check that sources with positive IPA sizes show a localized size before downloading; missing/zero sizes remain omitted.

Issue #1654 still needs the affected iPad's LiveProcess crash report and reproduction on its reported iPadOS build.
