# Restore a workspace from the Home Screen

1. Arrange your apps in virtual-window mode and save the workspace in
   Settings → Multitasking → Workspace, or from the Dock's layout menu.
2. Tap **Copy Restore Link** in the same place.
3. In Apple's Shortcuts app, create a shortcut with a **URL** action, paste
   the link, then add **Open URLs**.
4. Use **Add to Home Screen** to choose the shortcut's name and icon.

The existing LiveContainer **Launch App** shortcut action also accepts the
restore link. It opens the requested LiveContainer installation and does not
return a workspace completion result to Shortcuts.

For the main installation the link is:

    livecontainer://workspace-restore

Use the copied link if you have multiple LiveContainer installations.

The link always restores the most recently saved workspace. Saving again
updates what the same Home Screen shortcut restores. It restores the apps,
their exact containers, order, scale, grid proportions and landscape layout, while keeping
other open windows. App-specific state, such as a song's playback position,
is managed by the app itself.

Choose **Landscape Layout → Single Row** in Settings → Multitasking or the
Dock's layout menu to place tiled windows from left to right across the full
height in landscape. Portrait keeps the automatic grid and the same app order.
This also follows rotation after manually arranging a grid with automatic tiling
off. **Automatic Grid** remains the default. Both layouts keep their own divider
proportions. Save the workspace again after changing this choice so the existing
Home Screen shortcut restores it. Older workspaces restore Automatic Grid.

Locked or hidden apps still require authentication. When a guest is running
in normal mode, the existing app-switch confirmation applies before returning
to LiveContainer. Canceling it does not queue a restore. Successful shortcut
restores need no extra confirmation; failures and partial restores show a result.

Workspace restoration requires virtual-window mode on iOS 16 or later.
