# Copilot Instructions for sanpo

## Project Structure Notes
- Territory mode coverage is implemented in `lib/main.dart` and `lib/services/area_coverage_service.dart`.
- Administrative coverage is represented by `AdministrativeCoverageResult` and `TerritoryCoverageResult`.
- Reverse lookup failures should be surfaced with `TerritoryCoverageException` and shown as UI error text.
- Territory panel administrative names should follow the user's current location with throttled refresh behavior.
- Town coverage should use the same reverse lookup boundary result as the displayed town name to avoid name/coverage mismatches.

## Agent Rules
- When changing territory coverage behavior, update related prompt/instruction files under `.github/`.
- Keep version bump workflow in sync with `.github/prompts/commit.prompt.md`.
- Add or update tests under `test/` when public service contracts are added or changed.
