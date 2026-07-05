# Territory Coverage Skill

## Domain
Flutter territory mode coverage calculation and display.

## Workflow
1. Read `lib/main.dart` territory panel rendering and state fields.
2. Read `lib/services/area_coverage_service.dart` for administrative coverage resolution.
3. Check the current-location-following refresh and its time/distance throttling in `_refreshTerritoryCoverageForCurrentPosition`.
4. Check town-layer resolution: chome name via high-zoom reverse lookup, boundary via forward search (skipped when the city name is empty), and the ~500m JIS mesh fallback ("〇〇周辺") when no boundary exists. Also verify Japanese chome numeral normalization and GeoJSON `Feature`/`FeatureCollection`/`GeometryCollection` parsing.
5. Verify error propagation using `TerritoryCoverageException`.
6. Ensure tests in `test/` cover new public contracts.

## Key Files
- `lib/main.dart`
- `lib/services/area_coverage_service.dart`
- `test/area_coverage_service_models_test.dart`
