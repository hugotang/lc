# Puzzle & Dragons 23.6.0 display investigation

On 2026-11-05, the user clarified the observed behavior of Puzzle & Dragons on an iPad with LiveContainer in landscape: **Automatic + Custom Ratio 11:16 displays correctly in multitasking; explicitly selecting iPad still overflows even with the fixed ratio.** The user separately confirmed that **Use Window Size as Screen Size was already enabled when the overflow occurred**. The earlier analysis incorrectly recorded iPad + 11:16 as successful; that conclusion is withdrawn.

The device-confirmed configuration is **Automatic + 11:16 in virtual multitasking on 3.8.34**. Version 3.8.35 removes Interface Mode and always uses the former Automatic behavior; choose Custom 11:16 and close/reopen all accounts after upgrading. The failing window dimensions, game scene, status-bar geometry, launch sequence, content scale and actual device/trait idioms under Automatic were not captured. This establishes a successful earlier configuration, not that 11:16 is uniquely required or that the upgrade and every game screen, ad and touch path have passed. Ordinary launches are outside the fixed-ratio scope, consistent with the user's report that it works only in multitasking.

## Input and method

The supplied decrypted IPA was inspected with IDA MCP / Hex-Rays, using an existing local IDA database after verifying that its input executable matches the IPA byte-for-byte by SHA-256. Analysis followed the native view, Metal drawable callback, iPad layout selection and touch conversion. No executable bytes, IPA, account data or runtime settings were modified. Detailed decompilation remains in local build artifacts; this document records findings and addresses.

| Identity | Value |
| --- | --- |
| Bundle | `jp.gungho.pad` |
| Version / build | `23.6.0` / `106878` |
| IPA SHA-256 | `ec29184eeb15e2c2a178747b3f15249fa38e454240bb25cc914a6d75a7e4e8e1` |
| Executable SHA-256 | `611c93f5472fceddfa27254b718c6eff1decdc6814cc927e2faa4c7c250a65ec` |
| Preferred image base | `0x100000000` |

Addresses are unslid virtual addresses in this exact build. Objective-C names are recovered symbols; roles assigned to unnamed functions are analysis descriptions.

## Observed layout behavior

The original `Info.plist` declares device families 1 and 2, but both `UISupportedInterfaceOrientations` and `UISupportedInterfaceOrientations~ipad` contain only `UIInterfaceOrientationPortrait`. `UIRequiresFullScreen` is true. Supporting an iPad interface therefore does not establish support for arbitrary landscape-shaped guest windows.

| Address | Observation |
| --- | --- |
| `0x1003AF290` | App launch creates its window using `UIScreen.mainScreen.bounds` and sets the controller's `bRunningInIpad` flag from `UIDevice.userInterfaceIdiom != Phone`. |
| `0x10021DDC4` | `-[ViewController loadView]` creates `IS_MTK_VIEW` from screen bounds. |
| `0x1004D5FF8` | Game initialization copies the cached iPad flag into its display state. It also queries `hw.machine`; the idiom override does not replace all hardware checks. |
| `0x1002211B4` | `-[ViewController mtkView:drawableSizeWillChange:]` stores the supplied drawable width and height, then separately derives a render height from drawable width and screen aspect. It normalizes another dimension pair into short-side/long-side order and recalculates layout. |
| `0x10021F9DC` | The controller's size-transition override refreshes scene orientation/status-bar state and recalculates game layout. Its instructions do not consume the supplied destination CGSize or forward to the superclass. |
| `0x1003A49BC` | `-[IS_MTK_VIEW layoutSubviews]` is empty in this build. This alone does not prove that Metal never resizes; a separate drawable callback exists. |
| `0x1004D5A6C` | Recalculates game display dimensions, with separate phone and iPad branches and a status-bar deduction. |
| `0x1004D5E9C` | Sets an internal iPad layout variant and recalculates dimensions. Calls at `0x100290DAC`, `0x1003F10F4` and `0x1005B64C4` request variant 2. This is a game-internal variant, not LiveContainer's Interface Mode enum. |
| `0x10009681C` / `0x100068FF0` | Viewport fitting and touch conversion use the game's derived dimensions, status-bar offset and iPad layout variant. A rendering-only adjustment could make input inconsistent. |

### The Metal dimension calculation

The arithmetic at `0x1002211E8`–`0x1002211F8` was checked against ARM64 instructions, not only decompiler types. With supplied drawable size `(Dw, Dh)` and queried screen size `(Sw, Sh)`, the callback derives:

```text
derivedHeight = Dw × Sh / Sw
render dimensions = (Dw, derivedHeight)
layout dimensions = (min(Dw, derivedHeight), max(Dw, derivedHeight))
```

`Dh` is stored earlier by `SetDrawableSize:`, but it is not used in this later height calculation. If the compatibility screen and drawable have matching proportions, the derived height agrees with the drawable height. A landscape shape still becomes a portrait-ordered pair in the game layout state. If screen and drawable proportions differ during a transition, the independently derived height can also differ from the real output surface.

This is a concrete route to inconsistent geometry in a hosted game designed around portrait dimensions. It may help explain why a fixed portrait ratio helps under Automatic, but it does not establish why forced iPad still fails at the same ratio. The exact failing runtime values and clipping point have not been measured. The iPad host's orientation does not by itself establish whether a particular grid slot was landscape-shaped.

### The iPad canvas and 11:16

The iPad branch uses a 640×960 base canvas for internal variants 0/1. Variant 2 uses derived dimensions bounded below by width 680 and height 960, with even-number rounding. Ignoring rounding and after the game's own status-bar deduction, let `W` and `H` be its usable portrait dimensions:

```text
if 960 × W / H >= 680:
    canvas = (960 × W / H, 960)
else:
    canvas = (680, 680 × H / W)
```

Both branches preserve the usable aspect ratio rather than defining one universal iPad ratio. The branch boundary is 680:960 = 17:24. At 11:16 with zero status-bar deduction, this path gives approximately 680×990 after even rounding. This calculation illustrates the recovered branch; it is not a measurement of the user's active canvas. Status-bar deductions and game state can alter it.

No exact 11:16 requirement was established in the inspected layout path. Its observed success should be retained as a per-game configuration, without automatically applying it to other iPad apps or replacing it with 17:24 solely because that is a code boundary.

## Implications for LiveContainer

The 3.8.34 options separated device idiom from actual content geometry. A fixed portrait ratio keeps the guest view and compatibility-screen proportions coherent while the host rotates; the scene orientation remains the host's orientation. Both options were scoped to injected virtual multitasking guests. Version 3.8.35 retains only the ratio, still restricted to that path, including a single virtual window. Ordinary launches and native windows continue to use their normal geometry.

In 3.8.34, Automatic installed no idiom override. Forced iPad changed both `UIDevice.userInterfaceIdiom` and the `UITraitCollection.userInterfaceIdiom` getter throughout the guest process, including framework calls and previously created trait collections. Size classes, scale, the trait collection's underlying stored values and other system configuration were not coherently replaced. Forcing iPad could therefore change behavior even on physical iPad hardware. The game's cached idiom branch is one possible difference, and framework trait interpretation is another. The report establishes a compatibility failure of that override, not which of these paths caused it.

The former Interface Mode tests verified launch gating and overridden getter results while preserving size classes/scale. They did not establish consistency with the rest of UIKit's trait machinery or correct layout in this game. There was no demonstrated benefit from Interface Mode for this report. Version 3.8.35 removes its UI, preference consumers, runtime hooks and synchronization gate. Old saved mode values are ignored while ratios remain intact. Regression coverage verifies that upgrade behavior and adds 11:16 to the existing ratio-fitting checks.

No additional runtime hook or executable patch is justified by this report alone. In particular, changing only the drawable callback, forcing an internal variant or repeatedly invoking the layout helper would not establish that cached game controls and touch conversion have been rebuilt correctly.

For device acceptance of 3.8.35, retain Custom 11:16, content scale and screen-size compatibility, close all accounts and relaunch in the same workspace and game screen. Compare against the working 3.8.34 Automatic baseline. If overflow remains, capture Copy Window Geometry, including actual device/trait idioms, initial size, guest bounds, screen bounds and Metal drawable. Full gameplay, touch, advertising and rotation checks are still separate from the reported display success.
