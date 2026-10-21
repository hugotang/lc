# Restore a workspace from the Home Screen

1. Arrange your apps in virtual-window mode. In Settings → Multitasking →
   Saved Workspaces, or the Dock's layout menu, choose **Save as New Workspace**
   and give the arrangement a name.
2. Tap **Copy Restore Link** and choose the workspace.
3. In Apple's Shortcuts app, create a shortcut with a **URL** action, paste
   the link, then add **Open URLs**.
4. Use **Add to Home Screen** to choose the shortcut's name and icon.

The existing LiveContainer **Launch App** shortcut action also accepts the
restore link. It opens the requested LiveContainer installation and does not
return a workspace completion result to Shortcuts.

Each copied link restores that specific workspace. You can add separate Home
Screen shortcuts for games, music or other app combinations. Renaming a workspace
keeps its link working.

To change an existing shortcut's arrangement, open **Manage Workspaces**, select
the workspace and choose **Update with Current Windows**. Saving as a new workspace
creates a separate arrangement. Updates and deletion ask for confirmation;
deleting a workspace makes its dedicated shortcut unavailable without deleting
apps or their data.

Use the copied link if you have multiple LiveContainer installations.

Restoration reopens the apps with their exact containers, order, scale, grid
proportions, landscape layout and portrait reserved areas, while keeping other
open windows. App-specific state, such as a song's playback position,
is managed by the app itself.

Your previous single save is automatically imported as **Original Workspace**.
Existing links without a workspace selection continue to restore whichever
workspace was most recently saved or updated:

    livecontainer://workspace-restore

Renaming does not change that order. A dedicated link to a deleted workspace
reports that it is unavailable; it never opens a different workspace instead.

Choose **Landscape Layout → Single Row** in Settings → Multitasking or the
Dock's layout menu to place tiled windows from left to right across the full
height in landscape. Portrait keeps the automatic grid and the same app order.
This also follows rotation after manually arranging a grid with automatic tiling
off. **Automatic Grid** remains the default. Both layouts keep their own divider
proportions. Update the saved workspace after changing this choice so its existing
Home Screen shortcut restores it. Older snapshots restore Automatic Grid.

In **Portrait Reserved Areas**, independently choose **Reserve Top Area** and
**Reserve Bottom Area** in Settings → Multitasking or the Dock's layout menu.
By default, the top is reserved for the status bar and Dynamic Island, while
content extends behind the home indicator. Turn off the top option to extend
content upward, or turn on the bottom option to leave space below the grid.
App controls still receive their safe-area insets; each app decides how to use
them. These options do not hide the status bar or remove system gestures.

The choices apply to portrait grids, including manually arranged grids with
automatic tiling off. Landscape keeps its existing top/side exclusions and
bottom-edge coverage. Floating and maximized windows keep their own placement.
Save or update a workspace to have its restore link recall both choices.
Manage Workspaces shows each saved choice. Older snapshots preserve the original
behavior: top reserved, bottom extended.

Locked or hidden apps still require authentication. When a guest is running
in normal mode, the existing app-switch confirmation applies before returning
to LiveContainer. Canceling it does not queue a restore. Successful shortcut
restores need no extra confirmation; failures and partial restores show a result.

Workspace restoration requires virtual-window mode on iOS 16 or later.
