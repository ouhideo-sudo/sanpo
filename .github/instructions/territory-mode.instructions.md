---
applyTo: "lib/main.dart,lib/services/area_coverage_service.dart,test/**/*.dart"
---

# Territory Mode Instructions

- Treat prefecture, city, and town coverage as separate administrative layers.
- Use `TerritoryCoverageResult` as the UI input contract for territory mode.
- On API or parsing errors, return `TerritoryCoverageException` with user-readable Japanese messages.
- Preserve existing widget/state behavior and only reset coverage state when enclosed polygons are empty.
- Add tests when introducing or changing public models and exceptions.
