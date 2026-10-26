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

The **3.8.29** diagnostic addition provides the missing rejection details for the next reproduction. Controlled tests cover age/sequence/malformed-clock classification, host queue rejection, retained guest records and session matching, report privacy, resumed-session isolation, concurrent reads, timeout and late-reply handling. They do not reproduce Monster Strike load or establish a physical-device diagnosis. After installing the new build, close/reopen the guests, reproduce the early-loading pause, and copy its report before changing the group or provoking another rejection. Repeat the three recovery checks and a loaded-game rapid-tap comparison.
