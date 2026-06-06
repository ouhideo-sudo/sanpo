---
description: Review Flutter/Dart source control diff for intent, correctness, and design quality
name: review
agent: agent
---

Review the uncommitted changes using the following process.

## Preparation: Collect the Diff

Before evaluating, explicitly collect all relevant changes:

1. Run `git status --short` to identify staged and unstaged files.
2. Run `git diff --cached` to inspect staged changes.
3. Run `git diff` to inspect unstaged changes.
4. Treat both together as the full set of uncommitted work.

## Review Process

1. **Analyze intent first** — Read the entire diff holistically and determine what this change is trying to achieve before evaluating individual pieces.
2. **Verify the intent is satisfied** — Confirm the implementation correctly realizes the analyzed intent.
3. **Check for breakage** — Examine impact on existing logic, state, async flows, and error paths.
4. **Analyze reuse and consolidation** — Identify unnecessary rewrites of similar logic. Flag manual copy-sync risks (duplicated code that must be kept in sync by hand). Evaluate whether the design is extensible.
5. **Check for duplicate functionality** — Before accepting new code, search the codebase for existing functions or classes that serve the same purpose. If a near-equivalent already exists, flag it: the diff should reuse or extend it rather than introduce a parallel implementation. Accumulation of overlapping implementations makes the codebase harder to maintain and test; treat this as at least Medium severity.
6. **Flutter/Dart specific checks** — Verify null safety, async safety (`mounted` checks after `await` in `State`), `setState` misuse, resource lifecycle (`dispose`), and plugin/API key handling.
7. **Propose future improvements** — If anything works today but will become a maintenance hazard, suggest a better design.

## Process Guidelines

- If the response will be long, **return intermediate results first**, then continue with deeper analysis.
- Emit brief progress markers at each step **as plain text outside any `###` section** (e.g., before the final output block). Do NOT place progress text inside `### 変更の意図` or any other output section.

## Output Format

Structure the output using the following labeled sections. Use markdown headings (`###`) for each section header.
The `###` sections must contain **only** the review content described below — no progress markers, no step counters.

### 変更の意図
One or two sentences describing the analyzed intent. Always required. Do not include progress counters or step summaries here.

### 指摘事項
Report problems only; do not comment on improvements or positive aspects. If none, write `なし`.
- Severity: **High / Medium / Low**
- Include file name and line number(s) for each issue (e.g., `lib/main.dart:123`).
- Include design proposals here if any exist.
- **Output all findings inside a single fenced code block.** This is intentional and mandatory — it lets the user copy all findings at once. Use the fence delimiter only at the very start and end of the findings list. Never output findings as plain prose outside the code block. If there are no findings, write `なし` as plain text (no code block needed).

### 判定
- **"✅ commit可"** — no High or Medium issues found; the change is safe to commit as-is.
- **"⚠️ 要修正後commit"** — one or more High or Medium issues must be resolved before committing. List the blocking issue IDs or titles.
- **"🚫 commit不可"** — critical correctness or safety issue found; do not commit until resolved.

Respond in Japanese.