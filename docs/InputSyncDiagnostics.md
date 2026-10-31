# Input Sync diagnostics

In Input Sync settings, **Copy Sync Diagnostics** copies a JSON report of the latest interruption and input rejection. The report uses window numbers and roles, excluding account/container IDs, game data, touch coordinates and raw input packets. The copy uses the local clipboard; there is no automatic upload, file logging or periodic diagnostic polling.

The coordinator remembers one interruption, including the status, mode, completed action count, pending queue depth, in-flight delivery sequence, affected windows and windows still owing a reply. The snapshot is taken before coordinator cleanup. A queue-expiry path has already discarded the queue, so its snapshot can show zero pending items. Manual Pause and opening setup retain an existing fault for inspection; changing the group or restoring a workspace clears the old record. Relaunching clears these in-memory diagnostics.

Each guest remembers one input rejection across Stop and Resume. Copy requests that rejection for the interrupted session only; a later session's failure is never substituted. A new rejection replaces the previous one. Closed/relaunched guests or a newer failure can therefore return no matching record. The report identifies these cases instead of guessing. The saved coordinator references are weak and do not prolong the guest connections' lifetime.

| Report field | Meaning |
| --- | --- |
| `lastInterruption.status` | The preserved interruption status key; `currentStatus` can differ after Resume or opening setup. |
| `lastInterruption.affectedWindows` | Window numbers attributed by the existing interruption path, not an arbitrary account. |
| `lastInterruption.hostInputFailure` | A source input or queued packet rejected by the host, if available. |
| `guests[].lastInputFailure` | A guest's input rejection for the interrupted session, if available. |
| `reason` | `inputTooOld`, `sequenceMismatch`, `sequenceExhausted`, `timestampAhead`, `invalidPacket`, `invalidClock` or `unknown`. |
| `stage` | `hostReceive`, `hostQueue`, `hostReturnCapture`, `guestReceive` or `guestDelivery`. The guest receive check runs on its main thread; delivery checks can run later after intentional gesture timing or a run-loop delay. |
| `inputAgeMs` | Original input timestamp to the rejection observation, in milliseconds. Present only when decodable and finite; negative values identify a timestamp ahead of the local monotonic clock. It does not isolate XPC, main-thread scheduling or game handling. |
| `receivedSequence`, `previousSequence`, `expectedSequence` | Packet sequence at rejection. Guest sequences are contiguous delivery numbers after host move coalescing; source/host receive sequences are source numbers. Previous/expected values appear only at receive stages, where they were actually checked. |
| `sequenceCheck`, `phase` | `checked` at receive, `alreadyAccepted` at queue/delivery, or `captureOrder` for the generated first-return capture sequence. Single-finger `phase` is 0 began, 1 moved, 2 ended or 3 cancelled. |
| `observedAtUptime` | Monotonic observation time, not a calendar timestamp. |
| `guestReadStatus`, `guests[].readStatus` | Complete, partial, unavailable, timed-out or no-matching-failure results. Missing data is not proof of healthy input. |

Only rejection paths construct detailed input records. Copying performs one on-demand read per selected guest and returns after at most three seconds with the available results. Each real peer allows one outstanding diagnostics request; its gate stays set until the actual response or disconnect, so repeated copies cannot accumulate requests behind a stalled game. Late replies cannot alter the already-returned report or a replacement request. Diagnostic reads do not prepare, resume or replay input.

The input-age limit remains **750 ms**, acknowledgment timeout **3 seconds**, and start preparation **5 seconds**. This feature does not retry rejected input or change automatic recovery. The existing combined `lc.tapSync.expiredInput` message remains; the JSON gives the more specific reason.

## Device evidence and validation

On 2026-10-26, with LiveContainer **3.8.28**, iPad Pro M1 / iOS **27.0.1** and Japanese Monster Strike four-account **Single Finger** sync, the user reported an early workspace-restore pause attributed to window 3 with `lc.tapSync.expiredInput`, after 14 completed forwarded actions. Rapid source tapping after all four games loaded was normal. Follower → source recovery, landscape → portrait → landscape recovery, and manual Pause/Resume with the group/mode preserved also passed. USB confirmed the four LiveProcess guests; scoped system logs showed rotation-related UI status text consistent with those observations, but supplied no command ages or sequences. The loading-delay hypothesis is plausible; actual age expiry versus sequence rejection remains unconfirmed for that incident.

On 2026-10-26, the user reproduced rapid source tapping during game startup/server loading in **3.8.29** and supplied the complete on-demand report. Source was window 4; followers were windows 1–3. Window 1 rejected delivery sequence 24's **ended** phase at `guestReceive`: `reason: inputTooOld`, `inputAgeMs: 1711.5049583371729`, `ageLimitMs: 750`. Its previous sequence was 23 and both received and expected sequence were 24, establishing age expiry rather than a sequence mismatch for this incident. The host attributed the pause and its sole outstanding reply to window 1, with one queued packet and 11 completed group actions. All participants were connected and diagnostic reads completed. The other windows' `noMatchingFailure` results do not prove they performed the same game action.

The measurement covers input timestamp to the guest's main-thread receive check; it does not isolate host queuing, XPC scheduling or game/main-loop work. The user's startup/network-loading context is consistent with delayed input handling but does not establish a network failure or CPU bottleneck. This reproduction confirms the diagnostic path and the existing expired-input protection, not the full input-mode/device acceptance checklist.

The user accepts waiting for all games to finish loading instead of changing sync behavior. Keep 750 ms freshness and cancellation on expiry. If already paused, align the screens and explicitly Resume after loading; enabling source-return, first-return and rotation recovery does not automatically recover an expired-input pause. No timeout increase, retry of the rejected release or automatic resume is added. The earlier 3.8.28 window-3 incident remains without packet details and is not retrospectively classified by this new window-1 report.

Controlled tests cover age/sequence/malformed-clock classification, host queue rejection, retained guest records and session matching, report privacy, resumed-session isolation, concurrent reads, timeout and late-reply handling. The 3.8.29 runtime passed Release/Foundation, 141 UIKit and 13 Dock UI checks in both push and PR CI; those tests do not load Monster Strike. The new report validates one physical-device rejection/read path. The three recovery checks and loaded-game rapid-tap comparison were previously confirmed in 3.8.28, and broader modes, first-return settings and sustained-play acceptance remain separate.
