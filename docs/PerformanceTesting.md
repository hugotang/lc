# Measuring multitasking and input sync

Open **Performance Monitor** in the Dock layout menu, Multitasking settings or Input Sync settings. Enable **Show Performance Overlay**. It works with one virtual app window and does not require a sync group. Tap the overlay for details, drag it to either edge, and close it to stop measurement. Portrait/landscape positions are remembered independently and stay within the host safe area. Starting a new measurement resets statistics and returns to the app windows.

The overlay is off at launch. While enabled, one foreground timer samples once per second with 150 ms scheduling tolerance; inactive scenes, backgrounding and detaching the host stop it. The guest reads its own counters on the NSXPC service queue. Each peer allows at most one outstanding metrics request, including across overlay close/reopen, so a stalled guest cannot accumulate telemetry work. Monitoring adds its own cost; keep it enabled in both sides of an in-app comparison.

| Reading | Meaning |
| --- | --- |
| Process CPU | Change in cumulative `getrusage(RUSAGE_SELF)` user + system CPU time divided by elapsed monotonic time. 100% is one fully occupied core; values above 100% are valid. |
| Memory footprint | The process's `TASK_VM_INFO.phys_footprint`, in MiB (1,048,576 bytes). The combined number sums process footprints and is not the phone's total used RAM. |
| Combined values | LiveContainer and registered running virtual-app processes, including minimized guests. Missing, stale, warming or restarted processes show `—`. Totals require complete coverage; incomplete CPU intervals are excluded from the average. Process restarts and suspension gaps reset baselines. |
| Average / peaks | From the current measurement segment, with elapsed-time weighting for complete CPU samples. The segment number, elapsed time and covered CPU sample count/duration are shown. Background gaps are not averaged as idle time. |
| Thermal state | iOS's nominal/fair/serious/critical thermal pressure, shown as Normal/Warm/High/Critical. This is not a temperature sensor or proof of throttling at a particular frequency. |
| Sync reply median / p95 | Wall time from the host sending a command until every selected follower acknowledges its input dispatch. Includes XPC scheduling, guest handling and intentional replay timing; does not measure source touch-to-display, rendering, network latency or app-action success. Taps Only includes its intentional 30–120 ms replay hold. Compare within the same mode. |
| Reply sample count | Successful group command replies from the last ten seconds of the current segment, limited to the newest 600. Percentiles use nearest rank. Low sample counts are explicitly shown; idle sessions eventually display `—`, not zero latency. |
| Queue / coalescing | Pending host input commands (maximum four, plus one in flight), peak pending depth, and replaced unsent movement frames in the current segment. Coalescing is intentional and never removes a begin/end/cancel. It does not count source-side coalescing. |

A new segment starts after a sync mode/group change, sync starting or stopping, a change in the running process identities or window numbering, or foreground sampling resuming. Averages, peaks and reply statistics restart; completed earlier samples remain in the bounded report. A round that straddles a change is discarded and CPU baselines are reacquired. The sync state and thermal/Low Power readings are captured when a round starts, rather than being relabeled with the state at its later publication. Sampling still has approximately one second of display lag.

This monitor does not include system compositor, GPU, SpringBoard, other applications or ordinary non-multitasking guest launches. It cannot show whole-device watts, temperature in degrees, true guest-rendered FPS, or isolate the sync code's CPU from the rest of an app. A Home Screen/Lock Screen Widget cannot provide a reliable live process monitor because its updates are scheduled by iOS. The foreground overlay suits this use better.

## Repeatable comparison

Keep device/build/app versions, brightness, orientation, reserved areas, content scale, window sizes, charging, Low Power Mode, network and app content fixed. Start each run at a similar thermal state. Choose the sync condition first, allow two minutes for loading and initial caches, then start a new measurement and collect 60–120 seconds without changing that condition. Turn monitoring off to freeze the results, open Performance Monitor from the menu, and export before starting another measurement. Repeat each condition three times, alternating the order when comparing A/B to reduce the effect of heating over time. Changes in app content, brightness, charging and other workload settings still require a deliberate new measurement.

| Windows | Condition | What it helps distinguish |
| --- | --- | --- |
| One | Multitasking, sync off, idle / the intended workload | Host and single guest baseline. A one-window sync group is not possible. |
| Two, then four | Sync off, same idle screens | Extra live-app process and window cost. |
| Two, then four | Sync active, no physical input | Idle sync/session cost, without app actions. A held stationary finger needs no keepalives. |
| Two, then four | Sync active, repeat the same taps/swipes or two-finger gesture | Combined app work plus forwarding cost; inspect reply percentiles/queue and per-process CPU. |
| Two, then four | Sync off, repeat the gesture in only the source | Shows the additional work caused by updating followers. It does not isolate the forwarding implementation from follower app work. |

For the reported Spotify case, use the same downloaded track, playback position range, Canvas/player screen, audio route and foreground state. Compare a single multitasking window with two/four idle or playing instances separately. Network buffering, animated Canvas, charging and brightness can otherwise dominate the result. Avoid changing several settings at once.

**Share CSV File** creates an immutable `.csv` attachment only when tapped. Use the system share sheet to save it to Files or share it. The temporary copy is removed when the sheet closes. Live updates do not regenerate the CSV or change an attachment already being shared.

The CSV has a single header row and standard quoting, with no comment preamble. It retains the latest **300 whole sample rounds** (about five minutes of foreground sampling), so a report with multiple processes has more than 300 rows. Filter by `segment` before comparing conditions. Starting a new measurement clears all retained rounds; a segment change preserves them within this limit.

| CSV fields | Meaning |
| --- | --- |
| `schema_version`, `build`, `ios_version`, `logical_cpus` | Report format version 2 and build/device metadata, repeated so ordinary CSV readers can import the file directly. |
| `sample`, `segment`, `elapsed_s`, `segment_elapsed_s` | Sampling-round identity, condition segment, and host sample time relative to the measurement/segment start. Rows with the same sample number belong together. |
| `record_type` | One `combined` row per sample, followed by one `process` row for each expected process, including missing readings. Sync reply/counter fields appear only on the combined row. |
| `process_number`, `window_number`, `role` | Anonymous process number; host is 0 and a relaunched guest receives a new number. Window number is the current/last-known UI index, or 0 when unavailable. Roles are `host`, `source`, `follower` or `other`; selected sync roles remain visible while paused. Combined rows leave the numbers empty. No OS PIDs or container IDs are exported. |
| `cpu_pct`, `footprint_mib`, `cpu_interval_s`, `sample_elapsed_s` | CPU percentage (100% = one core), physical footprint in MiB, covered CPU interval and actual process sample time. Guest samples are asynchronous; use each process's interval to weight its average. The combined interval is the host interval, and combined values require full coverage. |
| `processes`, `cpu_coverage`, `memory_coverage` | Expected process count and counts with valid readings. Empty metric fields mean unavailable/warming/stale, never zero. |
| `thermal_state`, `low_power_mode` | Thermal pressure 0 nominal, 1 fair, 2 serious, 3 critical; Low Power Mode 0 off, 1 on. |
| `sync_mode`, `sync_active`, `followers` | Mode 0 taps, 1 single finger, 2 two fingers; forwarding active 0/1; selected follower count. |
| `response_p50_ms`, `response_p95_ms`, `response_samples` | Reply percentiles/sample count as defined above, captured for that sample's segment. |
| `delivered_commands`, `pending_commands`, `in_flight`, `peak_pending`, `host_coalesced_moves` | Successful command replies, current queued/in-flight work, peak queue and replaced movement frames. Cumulative counts are scoped to the segment. |

The report contains only these fields. It excludes app names, account information, container IDs and input coordinates, and no telemetry is sent automatically. Use the window/process numbers to locate an expensive guest without including the app's identity in the file.

For ordinary single-app mode comparisons, whole-device energy, GPU/compositor work or actual frame timing, use an external profiler such as Xcode Instruments on a Mac where attachment is available. On-device Battery settings offer longer-term coarse comparisons, not immediate per-window power. No performance improvement or battery saving is claimed until comparable physical-device runs have been collected.

## Device acceptance checks

- Open/close the overlay repeatedly during taps, scrolling and two-finger holds. Sync must continue unchanged. With monitoring off, there must be no periodic metrics calls or performance timer; hold/idle sync must remain free of input keepalives.
- Check one, two and four guests, including a guest outside the sync group and a minimized guest. Host + guest totals require all expected readings. Close/relaunch a guest during measurement; its CPU starts unavailable until two valid samples establish a baseline.
- Stall or suspend one guest. Other readings continue, totals become unavailable, the request stays bounded to one, and resuming the guest does not deliver queued old samples. Closing/reopening monitoring must not bypass the request bound.
- Background, lock, Control Center, scene deactivation and reattachment suspend measurement. Resume must reacquire baselines; the inactive interval must not appear as zero CPU. Closing the overlay freezes the last report and disables sampling.
- Drag both controls in portrait/landscape and rotate mid-drag. Check independent positions, safe areas, VoiceOver placement actions, Dynamic Type, hidden Dock and grid controls. The overlays must not forward their own touches or intercept touches elsewhere.
- Change source, remove a follower, switch modes, start/pause sync and open/close/relaunch an unrelated guest while sampling. Each change starts a fresh segment; CPU needs two new valid samples, reply percentiles must not retain the previous mode's values, and earlier completed rows must remain exportable. Changing values such as the live command count must not start a segment.
- Change mode/group during a pending metrics request, then immediately change back. The monotonic sync epoch must still discard the crossed round. Late replies must not enter the new segment.
- Reset between runs, collect more than five minutes, then share and inspect CSV: at most 300 complete sampling rounds, consistent column counts, numeric decimal points, correct segment/mode/thermal labels, empty missing fields and no input/app-identifying data. Relaunch a window and verify its old/new process numbers differ.
- Save the attachment to Files, open it with a standard CSV reader, cancel sharing and share again. Each file must stay fixed after export; the monitor must remain responsive, existing results must survive cancellation, and the temporary export directory must be removed after dismissal. Test iPhone/iPad, portrait/landscape, Dynamic Type and VoiceOver.
