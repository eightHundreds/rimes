# Mailbox and candidate strip design QA

## Comparison target

- Mailbox source of truth: the user's 2026-08-26 annotated CLI-style Mailbox screenshots. The required deltas are: every thread row is a compact single line, the composer is the fixed final terminal line, the separate field chrome and Send button are absent, and Return submits.
- Candidate-strip source of truth: the user's annotated screenshot retiring the `0 + tray` slot. The strip must contain only numbered candidates `1`–`9` and the trailing Settings gear.
- Installed Mailbox render: `/Users/isaac/Documents/05-dev/apps/rime-buffer/.build/design-qa-installed-populated-20260826-1719/core-buffer--mailbox.png`.
- Live installed candidate capture: `/Users/isaac/Documents/05-dev/apps/rime-buffer/.build/design-qa-current/installed-candidate.jpeg`.
- Installed candidate-settings render: `/Users/isaac/Documents/05-dev/apps/rime-buffer/.build/design-qa-installed-populated-20260826-1719/core-appearance--size.png`.

The Mailbox render was produced by the executable inside the newly installed `~/Library/Input Methods/ETInput.app`, using an isolated synthetic Mailbox fixture. The candidate capture came from the running installed IMK process during a real host composition. Reference and implementation were compared by their annotated regions and interaction state because the supplied source screenshots and native Settings render use different saved window sizes.

## Mailbox fidelity

- Thread index: selected and unselected rows share the same `40 pt` single-line layout. Only sequence, source and optional `NEW` state remain; every preview/summary line is gone.
- Transcript: time, source, marker and body keep the established terminal columns. Plain, Markdown, JSON and preformatted bodies use the same row grid; dedicated formatting smoke coverage verifies Markdown attributes and pretty-printed JSON.
- Composer: it remains fixed below the transcript and contains only `>` for AI continuation or `#` for a local-only note plus an unbordered single-line editor. There is no Send button, bezel, background or focus frame; Return invokes the same validated submission action.
- Semantics: `>` starts a real continuation against Codex CLI, Claude Code or OpenAI-compatible connectors. `#` creates a private local note for one-way HTTP/MCP-like sources and never implies a response channel.
- Streaming: Plain, Markdown and JSON provider snapshots update one stable in-memory `[live]` row in place as raw text. Durable transcript rows retain object identity, user scroll is not stolen, and incomplete structured output is never presented as a valid final document. Only the validated terminal result is persisted in the selected format, marked unread and allowed to trigger the completion toast.
- Format continuity: each AI generation freezes its expected format in the local thread record. A failed first attempt therefore keeps JSON/Markdown on retry, including after a process restart.
- Capacity: starting a generation atomically reserves both the user turn and terminal assistant slot. A concurrent note or inbound append cannot consume the reserved completion slot.

## Candidate-strip fidelity

- The live installed capture shows candidate buttons followed directly by the Settings gear; no `0`, tray icon, divider, tooltip or accessibility action remains.
- The installed Settings preview independently shows the full `1`–`9` strip followed by the gear.
- Compact `1`–`9` selection still routes through librime; expanded `1`–`9` remains locally owned by the matrix. Unmodified `0` is no longer consumed by candidate chrome and passes to librime/current input routing.

## Interaction and installation evidence

- `⌘⇧M` remains an exclusive registered `openMailbox` hotkey in the newly started installed process. Its visibility rule is a true show/close toggle, covered by `mailbox-window-smoke`.
- `mailbox-toast-smoke` verifies streaming progress creates neither receipt nor toast, while a completed unread message creates the Mailbox notification path.
- Installed executable UUID matches the release build: `51D352EC-981E-3DF1-8002-E3249A9BD0E2`.
- The installed bundle passed deep strict code-signature verification; exactly one `ETInput` process and one matching input-method bundle were present.
- TIS verification passed for installed, enabled mode and selected `com.isaac.inputmethod.RimeBuffer.Hans`.
- The installed binary passed `ai-text-smoke`, `ai-text-mailbox-smoke`, `mailbox-store-smoke`, `mailbox-window-smoke`, `mailbox-toast-smoke`, `buffer-window-smoke`, `matrix-smoke`, `candidate-metrics-smoke`, and `settings-routing-smoke`.
- Source validation passed the Homebrew Swift debug build, DesignSystem typecheck, 36 interaction tests, and `git diff --check`.

## Findings

- No release-blocking mismatch remains for the requested Mailbox simplification, format support, terminal-only notification rule, safe streaming preview, or candidate `0` retirement.
- The visual QA did not issue a paid/live provider request. Provider event ordering, in-place stream updates, final persistence and notification gating were exercised with deterministic native smokes; the installed surface and real candidate strip were checked separately.

final result: passed
