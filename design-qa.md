# Design QA — Clipboard image previews, toggleable Buffer toolbar, and theme families

## Current Acceptance Contract

- Buffer opens collapsed as one compact row: 44pt for ordinary/source-only/target-only and 78pt for live source-plus-target.
- The only leading input/plugin icon toggles a 33pt top toolbar plus a 1pt divider. Expanded heights are 78pt and 112pt.
- Empty toolbar chrome, status, spacing, and flexible spacer drag the window. Controls remain interactive; the body/background do not drag, and there is no dedicated 24pt right-side strip.
- Toolbar state is session-local and resets collapsed on hide or secure/session protection.
- Clipboard image records and image-bearing files show bounded asynchronous previews, real source-application icons, and are discoverable through image aliases. History and previews remain local with no cloud sync.

## Findings

- [Blocked] The source screenshots cannot be opened as an image artifact in this workspace.
  - Location: the two Buffer screenshots attached to the user's request.
  - Evidence: the screenshots are visible in the conversation, but this runtime exposes neither a filesystem path nor an image handle that can be placed in the same comparison input as the rendered implementation.
  - Impact: a valid source-versus-implementation fidelity comparison cannot be completed. Separate visual inspection is not a substitute for the required combined comparison.
  - Fix: reattach or save the two source screenshots as local files, then compose each source and matching implementation state into one comparison image at equal logical size.

The implementation-only evidence below predates the current toggleable-toolbar revision. It remains useful as historical Clipboard/theme evidence, but it is not a current Buffer fidelity pass. Fresh collapsed, expanded, and collapsed-again renders are required after implementation.

## Comparison Target

- Source visual truth path: unavailable — two user-provided conversation attachments, with no filesystem path exposed to this runtime.
- Implementation screenshots:
  - `.build/design-qa-current-20260830/buffer-collapsed.png`
  - `.build/design-qa-current-20260830/buffer-expanded.png`
  - `.build/design-qa-current-20260830/buffer-live-collapsed.png`
  - `.build/design-qa-current-20260830/buffer-live-expanded.png`
  - `.build/design-qa-current-20260830/clipboard-image-preview.png`
  - `/tmp/rimebuffer-design-qa.zEhGCP/buffer-classic.png`
  - `/tmp/rimebuffer-design-qa.zEhGCP/buffer-rasta.png`
  - `/tmp/rimebuffer-design-qa.zEhGCP/buffer-rasta-translation-v2.png`
  - `/tmp/rimebuffer-design-qa.zEhGCP/clipboard-rasta-v2.png`
  - `/tmp/rimebuffer-design-qa.zEhGCP/settings/core-appearance--theme.png`
  - `/tmp/rimebuffer-installed-buffer.png`
  - `/tmp/rimebuffer-installed-clipboard.png`
- Historical state (superseded for Buffer toolbar/geometry comparison):
  - Classic Buffer, ordinary collapsed one-row state.
  - Rasta Buffer, ordinary collapsed one-row state.
  - Rasta Buffer, completed collapsed live source-plus-target translation state with Copy available.
  - Rasta Clipboard History with a real image thumbnail and real Safari source icons.
  - Appearance settings with Classic colorways and the selected Rasta theme.
  - Installed Release bundle in the current Classic colorway: completed translation Buffer and Clipboard History.

## Viewport and Density

| Artifact | Logical size | Pixel dimensions | Density |
| --- | ---: | ---: | ---: |
| Buffer ordinary, collapsed | 760 × 44 pt | 1520 × 88 px | 2× |
| Buffer ordinary, expanded | 760 × 78 pt | 1520 × 156 px | 2× |
| Buffer live source+target, collapsed | 760 × 78 pt | 1520 × 156 px | 2× |
| Buffer live source+target, expanded | 760 × 112 pt | 1520 × 224 px | 2× |
| Rasta Clipboard History | 940 × 224 pt | 1880 × 448 px | 2× |
| Appearance settings | 980 × 680 pt | 1960 × 1360 px | 2× |
| Installed Release Buffer | 760 × 78 pt | 1520 × 156 px | 2× |
| Installed Release Clipboard | 940 × 224 pt | 1880 × 448 px | 2× |
| Source attachments | unavailable | unavailable | unavailable |

The implementation renders are internally normalized at native macOS 2× density. Source normalization could not be performed because the source files are unavailable.

## Full-view Comparison Evidence

A valid combined full-view comparison was not possible. Current implementation-only inspection confirms:

- Fresh AppKit renders verify the 44pt ordinary and 78pt live collapsed states, the 33pt toolbar + 1pt divider, and their 78/112pt expanded states. The expanded toolbar spans the top edge, and the body ends at the primary action without the retired right-side strip.
- The real toolbar hit-test probe verifies actionable controls keep first-click ownership while static status, spacing, flexible spacer, and empty chrome resolve to the window-drag surface. Hide/protection reset and collapsed-again geometry are covered by `buffer-window-smoke`.
- Only one leading input-control icon remains; the generated target has a separate explicit Copy action and the existing Send action.
- Rasta renders red, yellow, and green simultaneously in the workbench chrome.
- Clipboard cards show actual image content and source application icons without changing the horizontal timeline density.
- Appearance settings present Classic as one family with three colorways and Rasta as a separate theme.
- The installed Release evidence reproduced the then-current collapsed Buffer, Copy action, real Clipboard image, and Safari icons. It must not be treated as proof of the later toggleable-toolbar behavior until a new install/runtime pass is captured.

## Installed Functional Evidence

- The final Release bundle was installed with `RB_KEEP_USERDB=1`; the selected input source is `com.isaac.inputmethod.RimeBuffer.Hans`, the bundle passes strict deep code-sign verification, and one live ETInput server remains after audit commands exit.
- A real AppKit RTF + plain-text pasteboard item was captured by the installed process after fixing macOS's unreadable synthesized `public.utf16-external-plain-text` projection. The aggregate audit moved from 2,548 to 2,549 local payload items. The exact artificial QA row was then removed, the prior clipboard archive was restored without printing its content, and SQLite integrity returned `ok` at 2,548 items.
- Lossless rich activation reached the OS permission boundary, but the final TextEdit insertion could not be executed: macOS displayed the system-level “Allow RIMES to enable RIMES?” prompt. This run did not approve or deny that setting on the user's behalf. Therefore installed real-host rich insertion remains a manual acceptance check; smoke/build evidence alone is not represented as proof of final host insertion.

## Focused Region Comparison Evidence

A valid source-aligned focused comparison was not possible for the same blocker. The following implementation regions were inspected at original 2× pixels:

- Current Buffer leading input icon in both toggle states, target Copy action, Send action, 1px border, 33pt toolbar, 1pt divider, draggable empty toolbar chrome, interactive controls, and absence of a right-side strip.
- Clipboard image crop, 16 pt source icon, selected-card border, title wrapping, and right-edge horizontal overflow.
- Theme cards, grouping labels, selected-state outline, typography hierarchy, and footer status.

## Required Fidelity Surfaces

- Fonts and typography: native system and monospaced system faces render sharply at 2×; hierarchy and wrapping are coherent in the inspected states. Source fidelity remains unverified.
- Spacing and layout rhythm: historical 44/78pt collapsed Buffer and 940 × 224pt Clipboard renders were stable. Current QA must verify all four Buffer heights—44/78pt collapsed and 78/112pt expanded—without overlap or persistent-control clipping.
- Colors and tokens: Classic colorways and the independent Rasta semantic palette render with adequate contrast; red/yellow/green appear together in the Rasta Buffer. Source fidelity remains unverified.
- Image quality and assets: the Clipboard thumbnail uses a real raster asset with bounded downsampling, and the source app uses the real Safari icon rather than a placeholder or hand-drawn substitute.
- Copy and content: labels are coherent and the inspected state does not leak request prose into static product copy; dynamic clipboard card content is fixture data.
- Icons and interaction states: visible controls use SF Symbols or real application icons; selected, disabled, and available states are visually distinguishable. Keyboard behavior is covered by smoke tests, but source visual fidelity remains unverified.

## Comparison History

1. Initial implementation render:
   - Finding: the completed derived Buffer preview did not expose the new Copy action, and the Clipboard preview used placeholder source icons.
   - Fix: added a ready translation snapshot to the Buffer preview seam; seeded the Clipboard preview with a real image archive and Safari bundle identifier.
   - Post-fix evidence: `buffer-rasta-translation-v2.png` and `clipboard-rasta-v2.png` show the Copy action, real thumbnail, and real source icons.
2. Final source-aligned pass:
   - Blocked before comparison because the source screenshots are not available as openable image artifacts.
3. Current toolbar revision:
   - Required evidence: collapsed → expanded → collapsed-again native renders; ordinary and live heights; empty-toolbar drag hit testing; interactive controls; no right strip; hide/protection reset. Earlier toolbarless screenshots are historical only.

## Implementation Checklist

- [x] Inspect all implementation screenshots at original resolution.
- [x] Verify the five required fidelity surfaces in implementation-only evidence.
- [x] Fix missing Copy and real-icon evidence in the render fixtures.
- [x] Render and inspect current Buffer collapsed, expanded, and collapsed-again states at 2×.
- [x] Verify 33pt toolbar + 1pt divider, 44/78 and 78/112 geometry, drag/control hit regions, no right strip, and reset on hide/protection.
- [x] Verify Clipboard image records and image-bearing files asynchronously preview, real source App icons render, and image aliases find them without network access.
- [ ] Obtain local source screenshot files.
- [ ] Normalize source and implementation to the same logical size and density.
- [ ] Build combined full-view and focused-region comparisons and rerun fidelity QA.

## Follow-up Polish

- [P3] After the source files are available, validate the input-icon toolbar toggle, toolbar edge/divider/spacing/hover states, drag cursor, control pointer states, and collapsed reset against a captured live state.

implementation result: passed; source-aligned comparison remains blocked
