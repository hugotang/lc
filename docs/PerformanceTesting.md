# Measuring multitasking and input sync

Open **Performance Monitor** in the Dock layout menu, Multitasking settings or Input Sync settings. Enable **Show Performance Overlay**. It works with one virtual app window and does not require a sync group. Tap the overlay for details, drag it to either edge, and close it to stop measurement. Portrait/landscape positions are remembered independently and stay within the host safe area. Starting a new measurement resets statistics and returns to the app windows.

The overlay is off at launch. While enabled, one foreground timer samples once per second with 150 ms scheduling tolerance; inactive scenes, backgrounding and detaching the host stop it. The guest reads its own counters on the NSXPC service queue. Each peer allows at most one outstanding metrics request, including across overlay close/reopen, so a stalled guest cannot accumulate telemetry work. Monitoring adds its own cost; keep it enabled in both sides of an in-app comparison.

| Reading | Meaning |
| --- | --- |
| Process CPU | Change in cumulative `getrusage(RUSAGE_SELF)` user + system CPU time divided by elapsed monotonic time. 100% is one fully occupied core; values above 100% are valid. |
| Memory footprint | The process's `TASK_VM_INFO.phys_footprint`, in MiB (1,048,576 bytes). The combined number sums process footprints and is not the phone's total used RAM. |
| Combined values | LiveContainer and registered running virtual-app processes, including minimized guests. Missing, stale, warming or restarted processes show `—`. Totals require complete coverage; incomplete CPU intervals are excluded from the average. Process restarts and suspension gaps reset baselines. |
| Average / peaks | From the current measurement, with elapsed-time weighting for complete CPU samples. The covered CPU sample count/duration are shown. Background gaps are not averaged as idle time. |
| Thermal state | iOS's nominal/fair/serious/critical thermal pressure, shown as Normal/Warm/High/Critical. This is not a temperature sensor or proof of throttling at a particular frequency. |
| Sync reply median / p95 | Wall time from the host sending a command until every selected follower acknowledges its input dispatch. Includes XPC scheduling, guest handling and intentional replay timing; does not measure source touch-to-display, rendering, network latency or app-action success. Taps Only includes its intentional 30–120 ms replay hold. Compare within the same mode. |
| Reply sample count | Successful group command replies from the last ten seconds, limited to the newest 600. Percentiles use nearest rank. Low sample counts are explicitly shown; idle sessions eventually display `—`, not zero latency. |
| Queue / coalescing | Pending host input commands (maximum four, plus one in flight), peak pending depth, and replaced unsent movement frames since reset. Coalescing is intentional and never removes a begin/end/cancel. It does not count source-side coalescing. |

This monitor does not include system compositor, GPU, SpringBoard, other applications or ordinary non-multitasking guest launches. It cannot show whole-device watts, temperature in degrees, true guest-rendered FPS, or isolate the sync code's CPU from the rest of an app. A Home Screen/Lock Screen Widget cannot provide a reliable live process monitor because its updates are scheduled by iOS. The foreground overlay suits this use better.

## Repeatable comparison

Keep device/build/app versions, brightness, orientation, reserved areas, content scale, window sizes, charging, Low Power Mode, network and app content fixed. Start each run at a similar thermal state. Allow two minutes for loading and initial caches, then reset measurements and collect 60–120 seconds. Export each run separately. Repeat each condition three times, alternating the order when comparing A/B to reduce the effect of heating over time.

| Windows | Condition | What it helps distinguish |
| --- | --- | --- |
| One | Multitasking, sync off, idle / the intended workload | Host and single guest baseline. A one-window sync group is not possible. |
| Two, then four | Sync off, same idle screens | Extra live-app process and window cost. |
| Two, then four | Sync active, no physical input | Idle sync/session cost, without app actions. A held stationary finger needs no keepalives. |
| Two, then four | Sync active, repeat the same taps/swipes or two-finger gesture | Combined app work plus forwarding cost; inspect reply percentiles/queue and per-process CPU. |
| Two, then four | Sync off, repeat the gesture in only the source | Shows the additional work caused by updating followers. It does not isolate the forwarding implementation from follower app work. |

For the reported Spotify case, use the same downloaded track, playback position range, Canvas/player screen, audio route and foreground state. Compare a single multitasking window with two/four idle or playing instances separately. Network buffering, animated Canvas, charging and brightness can otherwise dominate the result. Avoid changing several settings at once.

**Share CSV Data** exports the latest 300 numeric rows in memory, with metric definitions and build/iOS metadata. It includes counts, host/combined CPU and footprint, thermal/Low Power state, sync mode/active state, reply percentiles and queue statistics. Empty fields mean unavailable, not zero. It does not contain app names, container IDs, account information or input coordinates, and no telemetry is sent automatically. Use the per-process panel to locate an expensive guest.

For ordinary single-app mode comparisons, whole-device energy, GPU/compositor work or actual frame timing, use an external profiler such as Xcode Instruments on a Mac where attachment is available. On-device Battery settings offer longer-term coarse comparisons, not immediate per-window power. No performance improvement or battery saving is claimed until comparable physical-device runs have been collected.

## Device acceptance checks

- Open/close the overlay repeatedly during taps, scrolling and two-finger holds. Sync must continue unchanged. With monitoring off, there must be no periodic metrics calls or performance timer; hold/idle sync must remain free of input keepalives.
- Check one, two and four guests, including a guest outside the sync group and a minimized guest. Host + guest totals require all expected readings. Close/relaunch a guest during measurement; its CPU starts unavailable until two valid samples establish a baseline.
- Stall or suspend one guest. Other readings continue, totals become unavailable, the request stays bounded to one, and resuming the guest does not deliver queued old samples. Closing/reopening monitoring must not bypass the request bound.
- Background, lock, Control Center, scene deactivation and reattachment suspend measurement. Resume must reacquire baselines; the inactive interval must not appear as zero CPU. Closing the overlay freezes the last report and disables sampling.
- Drag both controls in portrait/landscape and rotate mid-drag. Check independent positions, safe areas, VoiceOver placement actions, Dynamic Type, hidden Dock and grid controls. The overlays must not forward their own touches or intercept touches elsewhere.
- Reset between runs, collect more than five minutes, then share and inspect CSV: at most 300 rows, numeric decimal points, correct mode/thermal labels, empty missing fields and no input/app-identifying data.
