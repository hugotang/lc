# Monster Strike 33.0.0 text input investigation

The user reported that Text Only sync in LiveContainer 3.8.40 pauses at preparation in Monster Strike's search field, including after opening the field in every account and returning to the source. **The 3.8.42 device report still failed after removing the simultaneous-focus requirement; reopening the affected account moved the failure to another window. Version 3.8.43 adds a bridge for the verified Monster Strike native edit-box implementation. Successful physical-device search replay remains unverified.**

The supplied executable is the same Japanese Monster Strike 33.0.0 / 33.0.0.1 analyzed in [MonsterStrikeWindowSizing.md](MonsterStrikeWindowSizing.md), SHA-256 `63a241f6b0e9073bf7c1dc267a5ce8f5d4729c8d139287abd36c4fd9f22e9042`, Mach-O UUID `0FB091E2-191B-384B-A64A-492E9980070A`. IDA analysis on 2026-11-10 examined two input paths. Addresses are unslid and specific to this build. No game executable, account data or save was changed. Binary and decompilation artifacts remain local and are not committed.

| Address | Observed behavior |
| --- | --- |
| `0x100098380` | `EditBoxImplIOS initWithFrame:editBox:` creates `CustomUITextField`, assigns the edit-box delegate and an editing-changed control target, and initially hides the field. |
| `0x1006413C0` | The native edit-box opening wrapper updates placement, hides the engine-rendered labels, unhides the native field, then calls `openKeyboard`. |
| `0x1010F6168` | `openKeyboard` adds that field under the shared EAGLView and calls `becomeFirstResponder`. The scene startup makes EAGLView the root controller view. This path does not place the field outside the current root-view scan. |
| `0x101265A50` | The native field's change validator checks the resulting text length. It does not replace UIKit edits with a separate custom insertion path. |
| `0x100EE3C14` | The editing-changed target forwards the current text to engine callbacks. Existing adapter replay already delivers editing-changed events. |
| `0x100729D44`, `0x100CC30E0` | `textFieldDidEndEditing:` calls implementation vtable slot `+208`, which refreshes the text/placeholder engine labels only when the native field is hidden. This path does not resign focus, set the native text, normalize it or emit end/return callbacks. |
| `0x100C81928`, `0x1012D9170` | `textFieldShouldEndEditing:` changes editing state, calls the `+208` refresh, emits end/return callbacks, then calls slot `+216`. The latter hides the native field, normalizes its text and restores the engine labels. |
| `0x1006422C4` | `closeKeyboard` resigns and removes the native field. |
| `0x102695D80`, `0x10269A254`, `0x10269A2C0`, `0x10269A3A4` | A second path makes EAGLView itself the responder and forwards insertion, deletion and committed composition into the engine IME dispatcher. |
| `0x10269A304`, `0x10269A320`, `0x10269A32C` | That raw EAGLView path does not expose a usable text snapshot/selection/replacement implementation: selection is an empty base range, text lookup returns an empty string, and range replacement does nothing. It cannot use the standard-field adapter unchanged. |

The implementation vtable starts at `0x10339DC20`, not `0x10339DC28`. This corrects the earlier offset interpretation: `+208` is the narrow label refresh and `+216` is the hide/normalization path. A search box that remains visually displayed can therefore be an engine-rendered label while its native `UITextField` is hidden or removed. Static analysis and the reports support this explanation, but do not reveal the exact native field state in each account on the user's device. The raw EAGLView responder path remains unsupported.

## Device result and follower fix

On 2026-11-10 the user supplied a complete 3.8.41 report from iPadOS 27.0.1. Source was window 4. Followers 1 and 2 recorded `noFocusedInput` at `guestPrepare` (uptimes 18313.783145 and 18313.783921); the host stopped at 18313.784083 with zero forwarded actions. Follower 3 and the source had no matching failure. The source was not prepared after follower preparation failed, so its empty diagnostic is not evidence of successful source readiness. The user confirmed the search fields stayed visible while keyboard focus moved between accounts.

The 3.8.42 adapter keeps the source focused-only but allows a follower without a focused responder to bind one visible, editable, nonsecure UITextField/UITextView. A new ambiguity, different responder, removal or visibility/structure change rejects replay. The packet still must match the bound field and preceding text before any mutation. Unfocused targets use public range replacement and app callbacks without taking focus or requiring/restoring a caret.

The user's 3.8.42 report again had source window 4 and followers 1-3 on iPadOS 27.0.1. Follower 1 recorded `noFocusedInput` at `guestPrepare` (uptime 19489.518704958333); the host stopped at 19489.519363625001 with zero forwarded actions. Other windows returned `noMatchingFailure`, which does not establish successful readiness or replay. After the user reopened only window 1's search field and returned to source 4, the pause moved to another window. In 3.8.42, `noFocusedInput` can also mean that no eligible visible passive standard field was found. These observations show that manually revisiting the accounts did not solve readiness; they do not measure a specific UIKit focus-transfer mechanism.

## Scoped native-field bridge (3.8.43)

The bridge weakly remembers the native field the user actually begins editing, including before Resume. Remembering a field does not capture or transmit its text. The bridge requires the verified executable UUID, exact `CustomUITextField`/`EditBoxImplIOS` class identities and the expected Objective-C method implementations. Other game builds and arbitrary hidden controls do not qualify.

For an eligible follower, the remembered native field can remain a target after it becomes hidden or detached. The bridge does not unhide it, reattach it, acquire keyboard focus or suppress the game's normal end-edit callbacks. The source still requires its focused field. Safe, bounded memory reads verify the original field/owner/implementation/node relationships and require the node's visible, running ancestor chain to reach the game's current scene, with no pending scene change. Each parent must still contain its child exactly once. The engine child-index path supplies a shared logical field signature for source and followers even when their UIKit attachment differs.

| Runtime relationship | Verified layout or implementation |
| --- | --- |
| Objective-C owner | Field at `+8`, engine implementation at `+16`; `textField` getter `0x10117C83C`, `editBox` getter `0x101645490`. |
| Engine implementation | Vtable `0x10339DC20`; node at `+16`, text/placeholder labels at `+24`/`+32`, Objective-C owner at `+64`. |
| Edit-box node | Implementation back-reference at `+536`; children at `+192`, parent at `+200`, running flag at `+264`, visible flag at `+268`. |
| Node getter checks | Visible `0x10266E5DC`, children `0x10266E52C`, parent `0x10266E75C`, running `0x10266E754`. |
| Child array | `CCArray` vtable `0x1035300E0`; data pointer at `+24`; data contains 32-bit count/capacity at `+0`/`+4` and an entry-array pointer at `+8`. |
| Current scene | Director singleton pointer at `0x104B9C608`, expected vtable `0x10352FEC8`; current scene at `+176`, pending scene at `+184`. |

Replay retains the existing freshness, sequence, preceding-text, composition and security checks, with game ownership and graph validation before and after callbacks. After an accepted edit, the verified `textFieldDidEndEditing:` method refreshes the hidden field's engine labels through the narrow `+208` implementation. Calling this exact method does not call `textFieldShouldEndEditing:` or synthesize Return/submission. A detached field's recorded geometry must also remain valid; a remembered field alone is never sufficient to authorize replay.

The implementation destructor releases its Objective-C owner without clearing the owner's raw implementation pointer. The bridge therefore keeps weak identities and rechecks both ownership directions after game callbacks; a retained Objective-C object alone is not evidence that its engine implementation still exists. A new local touch in the guest or hardware-key input while the remembered field is unfocused clears that target. A new begin-editing event can record the field again, and preparation can revalidate the currently focused eligible field; ordinary source typing does not clear its binding. Lifecycle loss and disconnection discard tracking. Stopping a sync session releases its replay adapter; the separate tracker may retain only its weak identity and structural metadata until invalidated, with no queued input or saved text.

Physical-device acceptance still requires source typing, deletion and committed Japanese/Chinese input across all four search fields, visible game-label updates and an uninterrupted source keyboard. Repeat after account switches, then verify that closing/changing a search screen, local follower input, Stop, backgrounding and reconnection cannot replay into an old field. Simulator fixtures and package builds cannot establish that Monster Strike's search screen behaves correctly on the device.
