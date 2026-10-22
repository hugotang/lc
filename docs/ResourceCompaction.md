# Monster Strike resource compaction prototype

The Japanese Monster Strike app (`jp.co.mixi.monsterstrike`) can store several
gigabytes of downloaded resources in each account's
`Library/Application Support/dl_res`. The two supplied container copies have
753 byte-identical ZIP and Ogg files totaling 3,611,930,899 bytes. Six additional
identical binary files in `at01_23_45` are outside this prototype's allowlist.
`data12.bin` and `data17.bin` differ between accounts; all four Documents files
also differ.

In game settings, open **Compact Duplicate Resources**, select at least two
accounts, close all of their game windows, and choose **Analyze Resources**.
Analysis compares complete SHA-256 contents. It displays the number and size of
matching files; **Compact Matching Resources** then creates APFS clones and
atomically replaces only verified equal target files. The action can be repeated
after every account has finished a game resource update.

Each clone is a separate regular file with its own inode. APFS initially shares
the data blocks; writing or deleting a file in one account does not affect another
account. There is no shared writable directory, symlink or hard link to resources,
and no injected file/network hook. Saves, keychain groups and preferences are not
changed. File permissions, ACLs, extended attributes and modification times are
copied from the target file rather than the source account.

This prototype processes only top-level `data<digits>.bin` files with ZIP or Ogg
signatures, excluding `data12.bin` and `data17.bin` unconditionally. Nonregular
files, hard links, directories and unknown formats are left independent. Each
container and every component of its resource directory must be a normal local
directory. Resources on different devices are never grouped. External/bookmarked
containers are excluded from the UI.

Guests hold nonblocking shared file leases; scanning and applying hold exclusive
leases on every selected container. Kernel release on process exit avoids stale
lock ownership. Every replacement rechecks file identities and content, makes
and verifies a temporary clone beside the destination, preserves target metadata
through a read-only clone descriptor, syncs it, then atomically renames it.
When the filesystem permits `F_LOG2PHYS_EXT`, the complete source/clone extent
maps must match after metadata restoration; a confirmed loss of sharing stops
before replacement. An unavailable extent query is reported separately, not
treated as verified sharing. Cancellation or an error preserves unfinished
files; already completed clones remain valid. An advisory per-container manifest
avoids repeating known unchanged replacements and is not used to skip hashing.

An account still performs its own update checks and downloads. Updates automatically
separate changed file blocks. This avoids concurrent writes to a shared asset file,
but does not download updates once for all accounts. Coordinating downloads requires
further knowledge of the game's resource manifests/version bookkeeping. It is not
part of this prototype.

Displayed matching/processed byte counts describe work, not measured disk space
savings. Analysis now compares complete physical extent maps where permitted,
reports the number and size of files already sharing blocks, and detects data
that has become independent even if its contents were later changed back.
Where those queries are unavailable, version 2 advisory manifests avoid repeating
unchanged replacements. Version 1 manifests from the first prototype are
re-evaluated once; they are not accepted as evidence of retained sharing.

Compaction measures available space with `statfs` before and after replacing
files and closing the old descriptors. Volumes are counted once. The result
shows the signed change independently of processed bytes and persists the last
operation's counts, time and measurements in a small report within each selected
container. Reopening the page with the same selection restores that report.
**Refresh Storage** updates current available space without re-running compaction;
it can expose delayed reclamation. Other apps, purgeable caches and snapshots
can also change these values, so the difference is an observation of the volume,
not a guaranteed saving attributable only to this operation. No system-wide sync
or claimed adjustment of per-account file sizes is used.

The storage management page labels its total **Summed File Sizes**, explains
that APFS clones can still count once per account, shows device available space,
and supports pull-to-refresh and the toolbar refresh button. Files app folder
sizes may also continue to show each clone's full file size. Neither sum is a
reliable measure of unique physical blocks. Four identical supplied accounts
have 2,259 duplicate allowlisted files (753 × 3), about 10.84 GB of processed data;
that figure by itself does not prove the device gained 10.84 GB of free space.

## Verification

`ResourceCompactionTests.m` runs against the actual APFS clone implementation on
macOS CI. It covers equality, differing equal-size data, format/name exclusions,
private saves, clone inode separation, full physical extent sharing after
metadata restoration, writes that later restore the original bytes, available
space measurement without duplicate-volume counting, persisted results and
partial-operation reports, in-place writes, deletes, stale plans,
cancellation, target metadata, manifests, a third account, symlink/hard-link
rejection and cross-process leases. iOS game and protection-class behavior also
require the checks below; passing CI is not game compatibility confirmation.

While the operation is running, progress refreshes four times per second and only
for the duration of the operation. Leaving the page or backgrounding it cancels
the work. Guest leases use the existing suspend-safe lock-file convention; only
the empty lease file is marked, not account resources.

- Record device free space. Stop two accounts, analyze, and compact. Confirm the
  operation remains responsive and reports an understandable result in English,
  Simplified Chinese and Traditional Chinese, including large text and VoiceOver.
  Record verified/unavailable sharing counts, before/after available space and
  the signed change. Reopen the page to confirm the same report and refresh after
  a short idle period. A zero verified count with unavailable queries does not
  establish failure; an unchanged folder size does not establish failure either.
  Re-test first-prototype containers: analysis must verify existing sharing or
  offer a one-time re-compaction when extent queries are unavailable.
- Open both accounts, confirm distinct IDs/saves, play and save independently,
  and repeat with four accounts. `data12.bin`/`data17.bin` and Documents must remain
  unchanged by compaction.
- Cancel during scanning and applying; terminate/relaunch LiveContainer mid-apply.
  All original paths must remain usable and each file must remain complete. Retry
  analysis/compaction, and verify no stale lease blocks launching.
- Attempt to launch a selected container from another LiveContainer or a workspace
  shortcut during analysis/application. It must report that resources are busy.
  Attempts to compact a currently running selected game must be rejected.
- Let one account download a resource update. Other accounts must keep their own
  old files until their own updates finish. Complete all updates, close the games,
  compact again and measure device free space. Do not claim a single download.
- Delete/reset one compacted account, including while another runs; verify the
  other's resources and saves still work. Move a closed app between private/app-group
  storage and repeat analysis. Clones may lose sharing after cross-volume export,
  ordinary copying or ZIP backup; restored containers can be analyzed again.
