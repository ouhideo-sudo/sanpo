import 'package:flutter_test/flutter_test.dart';
import 'package:sanpo/services/area_coverage_service.dart';

void main() {
  test('AdministrativeCoverageResult holds area name and ratio', () {
    final result = AdministrativeCoverageResult(
      areaName: '東京都',
      coverageRatio: 0.42,
    );

    expect(result.areaName, '東京都');
    expect(result.coverageRatio, 0.42);
  });

  test('TerritoryCoverageResult groups three administrative layers', () {
    final prefecture = AdministrativeCoverageResult(
      areaName: '東京都',
      coverageRatio: 0.1,
    );
    final city = AdministrativeCoverageResult(
      areaName: '新宿区',
      coverageRatio: 0.2,
    );
    final town = AdministrativeCoverageResult(
      areaName: '西新宿',
      coverageRatio: 0.3,
    );

    final result = TerritoryCoverageResult(
      prefecture: prefecture,
      city: city,
      town: town,
    );

    expect(result.prefecture.areaName, '東京都');
    expect(result.city.areaName, '新宿区');
    expect(result.town?.areaName, '西新宿');
  });

  test('TerritoryCoverageResult allows null town when boundary is unavailable', () {
    final result = TerritoryCoverageResult(
      prefecture: AdministrativeCoverageResult(areaName: '千葉県', coverageRatio: 0.1),
      city: AdministrativeCoverageResult(areaName: '市川市', coverageRatio: 0.2),
      town: null,
    );

    expect(result.town, isNull);
  });

  test('TerritoryCoverageException keeps message in toString', () {
    final error = TerritoryCoverageException('取得失敗');

    expect(error.message, '取得失敗');
    expect(error.toString(), 'TerritoryCoverageException: 取得失敗');
  });
}
