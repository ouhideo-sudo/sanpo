import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:sanpo/models/walk_route.dart';
import 'package:sanpo/services/area_coverage_service.dart';

WalkRoute _route(List<LatLng> pts) => WalkRoute(
      id: 'r',
      startTime: DateTime(2020),
      endTime: DateTime(2020),
      points: pts,
      distanceKm: 0,
      durationMinutes: 0,
    );

void main() {
  final service = AreaCoverageService();

  // 約222m四方の格子（_minPolygonAreaSqKm=0.0008 km² を十分上回る）。
  const lat0 = 35.680, lat1 = 35.682;
  const lng0 = 139.760, lng1 = 139.7625, lng2 = 139.765;

  test('single loop yields exactly one enclosed polygon', () {
    final loop = [
      const LatLng(lat0, lng0),
      const LatLng(lat1, lng0),
      const LatLng(lat1, lng1),
      const LatLng(lat0, lng1),
      const LatLng(lat0, lng0),
    ];
    final polys = service.extractEnclosedPolygons([_route(loop)]);
    expect(polys.length, 1);
  });

  test('two adjacent cells fill both and exclude the outer boundary', () {
    // 外周の長方形 + 中央の縦仕切りで2マスの格子を作る。
    final outer = [
      const LatLng(lat0, lng0),
      const LatLng(lat0, lng2),
      const LatLng(lat1, lng2),
      const LatLng(lat1, lng0),
      const LatLng(lat0, lng0),
    ];
    final divider = [const LatLng(lat0, lng1), const LatLng(lat1, lng1)];
    final polys = service.extractEnclosedPolygons([_route(outer), _route(divider)]);
    // 外周(最大面)は除外され、内部の2マスだけが塗られる。
    expect(polys.length, 2);
  });
}
