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

Open **Manage Workspaces** to search your saves and inspect their apps, containers
and scales. Swipe left to rename or delete, or right to restore. Touch and hold
a row for **Copy Restore Link** and **Duplicate Workspace**. A duplicate starts
with the saved arrangement and gets its own name and restore link. Creating a
save or a duplicate from this list opens its detail page immediately.

In a workspace's detail page, change **Landscape Layout**, **Reserve Top Area**
or **Reserve Bottom Area** directly. These options save automatically and apply
the next time you restore that workspace. They retain its apps, containers,
order, scales, divider proportions and restore link. Renaming and editing these
options keep the workspace in its existing list position.

To replace an existing workspace's entire arrangement, choose **Update with
Current Windows** in its detail page. This also captures the current multitasking
layout options. Saving as a new workspace creates a separate arrangement.
Replacing the arrangement and deleting a workspace ask for confirmation;
deleting a workspace makes its dedicated shortcut unavailable without deleting
apps or their data.

The detail page's **Home Screen Shortcut** section includes instructions that
you can expand as needed. Successful saves, edits and copies within Manage
Workspaces use a brief message; failures show an alert. Hidden app details follow
the app list's unlock state.

Use the copied link if you have multiple LiveContainer installations.

Restoration reopens the apps with their exact containers, order, scale, grid
proportions, landscape layout and portrait reserved areas, while keeping other
open windows. App-specific state, such as a song's playback position,
is managed by the app itself.

Starting in 3.8.23, restoration reserves the final grid slots while accounts
start and applies each saved content scale before launch. A game using the
experimental window screen-size option therefore starts with its intended
content dimensions instead of the temporary layout for fewer accounts. Failed
launches release their reserved slots at the end. Existing saves need no update
or data conversion.

Your previous single save is automatically imported as **Original Workspace**.
Existing links without a workspace selection continue to restore whichever
workspace was most recently saved or updated:

    livecontainer://workspace-restore

Renaming or editing individual layout options does not change that order.
A dedicated link to a deleted workspace
reports that it is unavailable; it never opens a different workspace instead.

Choose **Landscape Layout → Single Row** in Settings → Multitasking or the
Dock's layout menu to place tiled windows from left to right across the full
height in landscape. Portrait keeps the automatic grid and the same app order.
This also follows rotation after manually arranging a grid with automatic tiling
off. **Automatic Grid** remains the default. Both layouts keep their own divider
proportions. You can edit this choice directly in an existing workspace's detail
page, or capture the current layout with **Update with Current Windows**.
Older snapshots restore Automatic Grid.

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
Save a workspace to have its restore link recall both choices, or edit them
directly in Manage Workspaces. Older snapshots preserve the original
behavior: top reserved, bottom extended.

Locked or hidden apps still require authentication. When a guest is running
in normal mode, the existing app-switch confirmation applies before returning
to LiveContainer. Canceling it does not queue a restore. Successful restores open
the workspace without an extra OK dialog; failures and partial restores show a result.

Workspace restoration requires virtual-window mode on iOS 16 or later.
