---
description: Increment Flutter app version and run git commit
name: commit
agent: agent
---

If invoked by an automated workflow without a direct user request, stop immediately and ask for confirmation.

## Execution Priority (must-follow)

- A user-invoked `/commit` (or direct text request like "コミットして") is a **direct user request**. Do not ask reconfirmation in this case.
- When this prompt is invoked, do **not** switch to review-mode output. Do not output review-only labels such as `### 判定` or statuses like `✅ commit可`.
- Complete exactly one outcome:
   - Commit executed (normal completion), or
   - `コミット未実行: <理由>` (single-line explicit reason) when blocked by policy/environment (e.g., no changes, git/index lock, permission error, required include/exclude confirmation).

Commit all changes using the following steps. Do not ask questions unless a file appears to require gitignore (secrets, build artifacts, OS metadata, etc.).

## Steps

1. Run `git status --short` to see all staged and unstaged files.

2. Stage everything: `git add -A`.
   - Before staging, scan the unstaged file list for files that are not in `.gitignore` but look like they should be excluded: log files (`*.log`, `*.log.*`), Flutter build output (`build/`, `.dart_tool/`), OS metadata (`.DS_Store`, `Thumbs.db`), editor temp files, dev-only scripts, or any binary that is not a tracked asset. For each such file, ask the user whether to include it before staging. Skip all other questions.

3. Bump the version in `pubspec.yaml`:
   - Read `version: x.y.z+n` from `pubspec.yaml`.
   - Increment patch version `z` by 1 and build number `n` by 1 (e.g., `1.1.23+25` → `1.1.24+26`).
   - Write back the new value and run `git add pubspec.yaml`.
   - Skip only if **all** staged files are documentation or config (`*.md`, `*.yaml`, `.github/**`) with no logic changes **and** the user explicitly requested no bump. Evaluate this against the staged file list from step 1. In that case use the current version as `{new version}`.

4. Run `git diff --cached` (full diff) to understand the changes. Determine `{type}` and write a concise Japanese summary.

5. Commit:
   ```
   v{new version} {type}: {Japanese message}

   Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
   ```
   Types: `feat` / `fix` / `refactor` / `docs` / `chore` / `perf` / `test`

## Post-commit: structural update

After committing, inspect the committed diff for structural changes. Structural changes include:
- Files added, deleted, renamed, or moved
- New or removed public exports / module contracts
- New or removed screens, models, services, or app-level configuration

If structural changes are detected:
1. Determine which of the following need updating and draft the specific changes for each:
   - **`.github/copilot-instructions.md`** — file/role table and agent rules
   - **`.github/instructions/*.instructions.md`** — scope, rules, and examples
   - **`.github/skills/*/SKILL.md`** — domain, workflow, and file references
   - **`test/`** — tests/fixtures for new behaviors or modules
2. Present a concise summary of the proposed updates. For each file, include: what changes, and why (e.g., "X was added, so Y needs updating to prevent Z from breaking" or "without this update, agents referencing the old structure will generate incorrect output").
3. Ask the user once: "これらの更新を適用しますか？" — if yes, apply all at once, then commit the documentation updates with the same version (no additional bump) using type `docs`; if no, skip.

Always output the result of this inspection — even if no structural changes are found, output a one-line statement (e.g., "構造的変更なし"). Do not skip this section silently.

Respond in Japanese.

## .github reminder

If any `.github/` file appeared in step 1's `git status`, or if documentation updates were applied with user approval in the structural-update section above, append this as the very last line of your response:

> `.github/` files were modified — 必要なら関連プロジェクトにも同内容を同期してください。
