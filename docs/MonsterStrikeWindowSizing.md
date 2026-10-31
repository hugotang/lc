# Monster Strike 33.0.0 window sizing investigation

Monster Strike initializes a separate internal game canvas and composites it into its current window. The resize path examined in its iOS executable updates the output surface while retaining the internal canvas and design dimensions. This explains why a resized window and Metal drawable can still show proportions inherited from launch. No complete, repeatable game relayout entry point was identified in the examined path.

**3.8.25 is the device-confirmed baseline for the affected ad fix. It is not a fix for startup-dependent game proportions.** The user first reported the orientation-history difference in 3.8.25; 3.8.26, 3.8.27 and 3.8.28 also failed that game check. The later host-geometry and callback tests pass their controlled fixtures, but those results do not establish that this game rebuilds its layout.

## Input and method

The user supplied the decrypted iOS IPA on 2026-10-26. Analysis used an extracted copy with licensed IDA 9.4 / Hex-Rays ARM64 and ida-domain 0.5.1. No game executable, original IPA, account container or save was patched. The executable and database remain local build artifacts; this document contains the investigation summary, not a redistributed binary or decompilation.

| Identity | Value |
| --- | --- |
| Bundle | `jp.co.mixi.monsterstrike` |
| Version / build | `33.0.0` / `33.0.0.1` |
| IPA SHA-256 | `276c2e4b431d1c611e68e9e275cc51703b0422e3d5dc4005ac8a8f33d2b6bbec` |
| Main executable SHA-256 | `63a241f6b0e9073bf7c1dc267a5ce8f5d4729c8d139287abd36c4fd9f22e9042` |
| Preferred image base | `0x100000000` |

Addresses below are unslid virtual addresses in this exact executable. Objective-C method names are recovered names. Descriptions of unnamed C++ functions are analyst interpretations. Runtime ASLR, a different app build or an engine update changes their applicability.

## What the device established

The user measured landscape launch → portrait rotation in LiveContainer 3.8.27, at 100% content scale, and confirmed that the visible game proportions remained incorrect.

| Measurement | Landscape launch | After portrait rotation |
| --- | ---: | ---: |
| Physical host window, pt | 1194 × 834 | 834 × 1194 |
| Host content / expected logical size, pt | 297 × 834 | 416 × 596 |
| Guest scene, game window, root view and Metal layer bounds, pt | 297 × 834 | 416 × 596 |
| Metal drawable, px | 594 × 1668 | 832 × 1192 |
| Published compatibility screen, pt | 297 × 834 | 416 × 596 |
| Guest scene orientation | 3 | 1 |

Host request/reply snapshots agreed. The optional hosting submission selector was unavailable, with zero explicit submissions, but UIKit's original path delivered the resize. `initialLogicalSize` retaining 297 × 834 records launch history and is expected. These measurements establish output geometry; they do not measure the private game framebuffer or design resolution.

The user also reported 3.8.28 failing the same game-proportion check. No updated root-callback diagnostic was supplied for that version. Receipt of its scoped callback hook is therefore not established by the device report.

## Startup creates the game canvas

The main executable contains cocos2d `CCEGLView` RTTI, an `EAGLView` Objective-C view, and a bgfx renderer using a Metal layer. This is evidence from the supplied iOS build.

| Address | Observed role |
| --- | --- |
| `0x1006AF5FC` | `-[AppController handleSceneWillConnect:connectionOptions:]` creates the window/root/render view, then calls the game startup routine. |
| `0x102695DB8` | A C++ guarded singleton constructs `CCEGLView` once through `0x102695C50`. The constructor reads `EAGLView.getWidth` / `getHeight` into separate frame and design-size fields. |
| `0x10115CF9C` | Reads `UIScreen.mainScreen.nativeBounds` as a startup size source. LiveContainer's enabled compatibility option can supply local dimensions here. |
| `0x100241A7C` | An optional foldable-safe-area size source, conditional on hinge availability. Its execution on the reported iPad is not established. |
| `0x10116342C` | Normalizes a portrait game render size from the startup dimensions, initializes bgfx, enables DynamicScreen compositing, and supplies the original output size separately. |
| `0x10269BDAC` | Initializes logical game and output dimensions. An already initialized renderer returns early. |
| `0x10000FE14` | The game's application-start virtual method sets cocos design resolution and UI margins, then performs substantial scene/resource/application initialization. |

The normalization routine chooses the short side and the long/short ratio. It clamps the ratio between `1.6453 + extraVerticalAllowance / 640` and `max(that minimum, 2.1656)`, caps the short side at 2160 pixels, and rounds a normalized portrait render size. The extra allowance is conditional; the examined implementation uses a cached iPad idiom check and a status-bar-related pixel height calculation. Its exact value on the user's device was not recorded.

The application-start method derives a 640-wide design size from those normalized dimensions, caps the calculated height at 1386, and uses a separate branch below 1136 involving 640 × 1053 and 640 × 1136. It also retains game UI margin state derived at startup. Relevant constants, branches and virtual setter calls were checked against ARM64 disassembly because the large startup decompilation reported a stack-value warning. No exact private framebuffer dimensions are inferred from the user's output diagnostics.

The two reported output shapes have long/short ratios of about 2.808 and 1.433. They can therefore enter different startup normalization/design branches. Giving them consistent host dimensions does not make their initialized game canvases identical.

## Rotation changes the output

`-[RootViewController viewWillTransitionToSize:withTransitionCoordinator:]` at `0x10036A7B0` calls super and schedules a transition completion. It contains no direct screen-size query or game design-resolution recalculation. The completion at `0x1005D0E44` applies the destination view frame, requests layout, and adjusts supplementary UI through `0x100665810`.

`-[EAGLView layoutSubviews]` at `0x1026992BC` updates the Metal layer and pixel surface size. With a ready renderer and DynamicScreen compositing enabled, it queues an output resize through `0x1026A1C04`, then updates safe areas and occlusion regions. It does not call the examined cocos frame/design setters.

At the next frame, `0x10269C798` consumes that resize. Its composite branch writes output width/height at renderer offsets `+19130` / `+19132` and recalculates composition through `0x1026A17B8`; it does not update logical game dimensions at `+70` / `+72`. The non-composite branch does update those logical dimensions, but startup explicitly enables the composite path. These distinct stores and branches were confirmed in disassembly.

The composition calculation fits, crops or centers the retained game canvas in the output using safe areas and occlusion regions. It does not rebuild the game's design layout. The examined deferred-layout method only requests the same layout again.

This path makes the user's observation consistent with the executable: the receiving window and drawable change, while the internal game canvas can remain based on launch. Supplying destination `UIScreen` dimensions inside the existing root callback, as in 3.8.28, does not address a path that does not read them there.

## Scope and recommendation

The frame/design setters are C++ virtual entries, so absence of direct call xrefs cannot exclude every indirect caller. The analysis did not execute or instrument Monster Strike, measure its private framebuffer, or test all scene-specific layouts. It supports retained startup canvas/design state in the examined resize path, rather than proving that every possible game path is immutable.

Calling the whole startup method again would also repeat scene, resource and application initialization. Changing only a framebuffer size or projection would not establish that existing UI nodes, margins and touch conversion were rebuilt consistently. No safe general-purpose relayout API was found, so this investigation adds no game-offset patch, automatic restart, forced portrait startup or fixed portrait canvas.

For the reported four-account setup, the user-confirmed practical flow is to close the accounts, restore while the iPad is in portrait, then rotate to landscape. The user found that result more correct; it is a launch procedure, not automatic orientation recalculation. With the currently supported flow, choosing a different startup calculation requires relaunching the accounts, and may interrupt gameplay.

3.8.25 can be used as the previously accepted ad baseline. Reverting to it does not eliminate the orientation-history issue and is not required by this investigation. Later host scale consistency, on-demand diagnostics and the independently reproduced WebKit late-viewport notification fix have separate purposes; a blanket rollback would discard them without solving this game's retained canvas. Dynamic game relayout remains unaccepted. Any future game-specific adaptation needs a complete relayout path and device checks of UI, rendering and input after both rotation directions.

See [screen compatibility behavior](WindowScreenCompatibility.md) and [recorded device checks](../Tests/MultitaskManualChecks.md).
