# Territory Coverage Skill

## Domain
Flutter territory mode coverage calculation and display.

## Workflow
1. Read `lib/main.dart` territory panel rendering and state fields.
2. Read `lib/services/area_coverage_service.dart` for administrative coverage resolution.
3. Check the current-location-following refresh and its time/distance throttling in `_refreshTerritoryCoverageForCurrentPosition`.
4. Check reverse-geocoding accuracy handling (Japanese chome numeral normalization, GeoJSON `Feature`/`FeatureCollection`/`GeometryCollection` parsing, town zoom fallback).
5. Verify error propagation using `TerritoryCoverageException`.
6. Ensure tests in `test/` cover new public contracts.

## Key Files
- `lib/main.dart`
- `lib/services/area_coverage_service.dart`
- `test/area_coverage_service_models_test.dart`
