# Monster Strike 33.0.0 text input investigation

The user reported that Text Only sync in LiveContainer 3.8.40 pauses at preparation in Monster Strike's search field, including after opening the field in every account and returning to the source. The previous generic message does not identify the rejected condition. **3.8.41 adds per-window readiness reasons and diagnostics; it is not a confirmed fix for the search field.**

The supplied executable is the same Japanese Monster Strike 33.0.0 / 33.0.0.1 analyzed in [MonsterStrikeWindowSizing.md](MonsterStrikeWindowSizing.md), SHA-256 `63a241f6b0e9073bf7c1dc267a5ce8f5d4729c8d139287abd36c4fd9f22e9042`. IDA analysis on 2026-11-10 examined two input paths. Addresses are unslid and specific to this build. No game executable, account data or save was changed. Binary and decompilation artifacts remain local.

| Address | Observed behavior |
| --- | --- |
| `0x100098380` | `EditBoxImplIOS initWithFrame:editBox:` creates `CustomUITextField`, assigns the edit-box delegate and an editing-changed control target, and initially hides the field. |
| `0x1006413C0` | The native edit-box opening wrapper updates placement, hides the engine-rendered labels, unhides the native field, then calls `openKeyboard`. |
| `0x1010F6168` | `openKeyboard` adds that field under the shared EAGLView and calls `becomeFirstResponder`. The scene startup makes EAGLView the root controller view. This path does not place the field outside the current root-view scan. |
| `0x101265A50` | The native field's change validator checks the resulting text length. It does not replace UIKit edits with a separate custom insertion path. |
| `0x100EE3C14` | The editing-changed target forwards the current text to engine callbacks. Existing adapter replay already delivers editing-changed events. |
| `0x1006422C4`, `0x1012D9170` | Closing resigns/removes the native field; an engine end-edit path hides it and restores engine-rendered labels. |
| `0x102695D80`, `0x10269A254`, `0x10269A2C0`, `0x10269A3A4` | A second path makes EAGLView itself the responder and forwards insertion, deletion and committed composition into the engine IME dispatcher. |
| `0x10269A304`, `0x10269A320`, `0x10269A32C` | That raw EAGLView path does not expose a usable text snapshot/selection/replacement implementation: selection is an empty base range, text lookup returns an empty string, and range replacement does nothing. It cannot use the standard-field adapter unchanged. |

Static evidence shows that the native edit-box path should be class-compatible and visible while open, and that the game also contains an incompatible raw engine path. It does not establish which path the reported search screen uses, the active responder in each hosted account at Resume, or whether switching accounts closes the earlier edit box. UIKit focus arbitration on the user's device remains an unmeasured factor.

The next device result should retain the full per-window reason or Copy Sync Diagnostics report from one failed attempt on 3.8.41. That result distinguishes no focus, unsupported responder, visibility, composition, selection and security before selecting a compatibility change. Current code intentionally retains its exact field/text matching, app delegate validation and manual Resume behavior.
