---
applyTo: "lib/main.dart,lib/services/area_coverage_service.dart,test/**/*.dart"
---

# Territory Mode Instructions

- Treat prefecture, city, and town coverage as separate administrative layers.
- Use `TerritoryCoverageResult` as the UI input contract for territory mode.
- `estimateTerritoryCoverage` returns a non-null `TerritoryCoverageResult`; empty-polygon handling and refresh gating live in the caller (`_refreshTerritoryCoverageForCurrentPosition`), not in the service.
- `TerritoryCoverageResult.town` is nullable but normally non-null: `_estimateTownCoverage` returns real chome coverage when a boundary is found, otherwise a ~500m mesh fallback ("〇〇周辺"). It is null only before the first computation or on an unexpected upper-level error, and the UI hides the town row while it is null.
- `AdministrativeCoverageResult.coverageRatio` is non-null (0.0–1.0); a missing area is expressed by a null `town`, not a null ratio.
- Territory coverage refresh follows the current location and is throttled by time and distance; only bypass the throttle with `force: true`.
- On API or parsing errors, throw `TerritoryCoverageException` with user-readable Japanese messages; route all Nominatim GET/decoding through `_getNominatimJson` so non-JSON 200 responses become `TerritoryCoverageException` (never a raw `FormatException`) and the town layer can fall back to the mesh instead of failing the whole panel.
- Preserve existing widget/state behavior and only reset coverage state when enclosed polygons are empty.
- Add tests when introducing or changing public models and exceptions.
