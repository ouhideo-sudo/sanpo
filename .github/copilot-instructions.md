# Copilot Instructions for sanpo

## Project Structure Notes
- Territory mode coverage is implemented in `lib/main.dart` and `lib/services/area_coverage_service.dart`.
- Administrative coverage is represented by `AdministrativeCoverageResult` and `TerritoryCoverageResult`.
- Reverse lookup failures should be surfaced with `TerritoryCoverageException` and shown as UI error text.
- Territory panel administrative names should follow the user's current location with throttled refresh behavior.
- Town coverage should use the same reverse lookup boundary result as the displayed town name to avoid name/coverage mismatches.
- Recorded route points drop low-accuracy GPS fixes and "warp" jumps in `_handlePositionUpdate` (`lib/main.dart`); keep those noise filters when touching recording.

## Device Data Restore Subsystem
- On startup, `_restoreBackupArchiveIfPresent` (`lib/main.dart`) restores `restore_backup.tar(.gz)` from the external files directory into `applicationInfo.dataDir` using the `archive` package.
- Path resolution depends on `MethodChannel('sanpo/config')` methods `getAppDataDir` / `getExternalFilesDir` implemented in `android/app/src/main/kotlin/com/sanpo/app/sanpo/MainActivity.kt`.
- Restore is Android-only and hardened: it deletes the archive before processing (bootloop protection), wraps everything in try/catch, skips `cache/` entries, and rejects path-traversal entries (Tar-Slip protection). Preserve these guards.
- `tools/restore_sanpo_backup.ps1` is the helper that stages the archive and drives the restore.

## Agent Rules
- When changing territory coverage behavior, update related prompt/instruction files under `.github/`.
- Keep version bump workflow in sync with `.github/prompts/commit.prompt.md`.
- Add or update tests under `test/` when public service contracts are added or changed.
