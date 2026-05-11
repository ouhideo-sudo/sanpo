import 'dart:convert';
import 'dart:math';

import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

import '../models/walk_route.dart';

class MunicipalityCoverageResult {
  MunicipalityCoverageResult({
    required this.municipalityName,
    required this.coverageRatio,
    required this.boundaryPolygons,
  });

  final String municipalityName;
  final double coverageRatio;
  final List<List<LatLng>> boundaryPolygons;
}

class AreaCoverageService {
  static const double _snapThresholdMeters = 30.0;
  static const double _minPolygonAreaSqKm = 0.03;

  List<List<LatLng>> extractEnclosedPolygons(List<WalkRoute> routes) {
    final segmentRoutes = routes.where((route) => route.points.length >= 2).toList();
    if (segmentRoutes.isEmpty) {
      return [];
    }

    final ref = segmentRoutes.first.points.first;
    final latStep = _snapThresholdMeters / 111320.0;
    final lngScale = cos(ref.latitude * pi / 180).abs().clamp(0.2, 1.0);
    final lngStep = _snapThresholdMeters / (111320.0 * lngScale);

    final nodeStore = <String, _NodeAccumulator>{};
    final adjacency = <String, Set<String>>{};

    for (final route in segmentRoutes) {
      for (var i = 0; i < route.points.length - 1; i++) {
        final a = route.points[i];
        final b = route.points[i + 1];
        final aKey = _snapKey(a, latStep, lngStep);
        final bKey = _snapKey(b, latStep, lngStep);
        if (aKey == bKey) {
          continue;
        }

        nodeStore.putIfAbsent(aKey, () => _NodeAccumulator()).add(a);
        nodeStore.putIfAbsent(bKey, () => _NodeAccumulator()).add(b);

        adjacency.putIfAbsent(aKey, () => <String>{}).add(bKey);
        adjacency.putIfAbsent(bKey, () => <String>{}).add(aKey);
      }
    }

    if (adjacency.isEmpty) {
      return [];
    }

    final nodes = Map<String, LatLng>.fromEntries(
      nodeStore.entries.map((e) => MapEntry(e.key, e.value.center)),
    );

    // 各ノードの隣接ノードを方位角で CCW 順にソートする（プラナー面検出に必要）
    final sortedAdj = <String, List<String>>{};
    for (final u in adjacency.keys) {
      final uPos = nodes[u]!;
      final neighbors = adjacency[u]!.toList();
      neighbors.sort((a, b) {
        final posA = nodes[a]!;
        final posB = nodes[b]!;
        final angleA = atan2(posA.latitude - uPos.latitude, posA.longitude - uPos.longitude);
        final angleB = atan2(posB.latitude - uPos.latitude, posB.longitude - uPos.longitude);
        return angleA.compareTo(angleB);
      });
      sortedAdj[u] = neighbors;
    }

    // 半エッジ法でプラナーグラフの面を追跡する。
    // 有向辺 (u→v) の次の面辺は (v → CCW リスト上で u の一つ前の隣接ノード)。
    // 内部面（有界面）は CCW 向きで符号付き面積が正になる。
    final halfEdgeVisited = <String>{};
    final enclosedPolygons = <List<LatLng>>[];
    final safetyLimit = sortedAdj.length * 4;

    for (final u in sortedAdj.keys) {
      for (final v in sortedAdj[u]!) {
        final startKey = '$u\x00$v';
        if (halfEdgeVisited.contains(startKey)) continue;

        final faceNodes = <LatLng>[];
        var curU = u;
        var curV = v;
        var steps = 0;

        while (steps++ < safetyLimit) {
          final halfKey = '$curU\x00$curV';
          if (halfEdgeVisited.contains(halfKey)) break;
          halfEdgeVisited.add(halfKey);
          faceNodes.add(nodes[curU]!);

          final neighbors = sortedAdj[curV]!;
          final idx = neighbors.indexOf(curU);
          if (idx < 0) break;
          // CCW ソート済みリストで一つ前のインデックス = CW 方向で次のエッジ
          final prevIdx = (idx - 1 + neighbors.length) % neighbors.length;
          curU = curV;
          curV = neighbors[prevIdx];
        }

        if (faceNodes.length < 3) continue;

        // 内部面のみ保持（CCW = 符号付き面積 > 0）。外部無限面は CW で負になる。
        final signedArea = _signedPolygonAreaSqKm(faceNodes);
        if (signedArea <= 0) continue;
        if (signedArea < _minPolygonAreaSqKm) continue;

        enclosedPolygons.add(faceNodes);
      }
    }

    return enclosedPolygons;
  }

  Future<MunicipalityCoverageResult?> estimateMunicipalityCoverage({
    required LatLng reference,
    required List<List<LatLng>> coveredPolygons,
  }) async {
    if (coveredPolygons.isEmpty) {
      return null;
    }

    final uri = Uri.parse(
      'https://nominatim.openstreetmap.org/reverse'
      '?format=jsonv2'
      '&lat=${reference.latitude}'
      '&lon=${reference.longitude}'
      '&zoom=10'
      '&addressdetails=1'
      '&polygon_geojson=1',
    );

    final response = await http.get(
      uri,
      headers: const {
        'User-Agent': 'sanpo-app/1.0 (route-coverage-feature)',
        'Accept': 'application/json',
      },
    ).timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      return null;
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final boundary = _parseBoundaryPolygons(json['geojson']);
    if (boundary.isEmpty) {
      return null;
    }

    final name = _extractMunicipalityName(json);
    final ratio = _estimateCoverageRatio(
      boundaryPolygons: boundary,
      coveredPolygons: coveredPolygons,
    );

    return MunicipalityCoverageResult(
      municipalityName: name,
      coverageRatio: ratio,
      boundaryPolygons: boundary,
    );
  }

  static String _extractMunicipalityName(Map<String, dynamic> json) {
    final address = (json['address'] as Map<String, dynamic>?) ?? const {};
    return (address['city'] as String?) ??
        (address['town'] as String?) ??
        (address['village'] as String?) ??
        (address['municipality'] as String?) ??
        (address['county'] as String?) ??
        (json['name'] as String?) ??
        '自治体';
  }

  static List<List<LatLng>> _parseBoundaryPolygons(dynamic geojson) {
    if (geojson is! Map<String, dynamic>) {
      return [];
    }

    final type = geojson['type'] as String?;
    final coordinates = geojson['coordinates'];

    if (type == 'Polygon' && coordinates is List && coordinates.isNotEmpty) {
      return [_toLatLngList(coordinates.first)];
    }

    if (type == 'MultiPolygon' && coordinates is List) {
      final polygons = <List<LatLng>>[];
      for (final polygon in coordinates) {
        if (polygon is List && polygon.isNotEmpty) {
          polygons.add(_toLatLngList(polygon.first));
        }
      }
      return polygons.where((poly) => poly.length >= 3).toList();
    }

    return [];
  }

  static List<LatLng> _toLatLngList(dynamic ring) {
    if (ring is! List) {
      return [];
    }

    final points = <LatLng>[];
    for (final pair in ring) {
      if (pair is List && pair.length >= 2) {
        final lon = (pair[0] as num).toDouble();
        final lat = (pair[1] as num).toDouble();
        points.add(LatLng(lat, lon));
      }
    }
    return points;
  }

  static double _estimateCoverageRatio({
    required List<List<LatLng>> boundaryPolygons,
    required List<List<LatLng>> coveredPolygons,
  }) {
    final bounds = _boundsOf(boundaryPolygons.expand((e) => e).toList());
    if (bounds == null) {
      return 0;
    }

    const steps = 90;
    var insideCount = 0;
    var coveredCount = 0;

    final latSpan = bounds.maxLat - bounds.minLat;
    final lngSpan = bounds.maxLng - bounds.minLng;
    if (latSpan <= 0 || lngSpan <= 0) {
      return 0;
    }

    for (var i = 0; i < steps; i++) {
      final lat = bounds.minLat + latSpan * ((i + 0.5) / steps);
      for (var j = 0; j < steps; j++) {
        final lng = bounds.minLng + lngSpan * ((j + 0.5) / steps);
        final point = LatLng(lat, lng);

        final inBoundary = boundaryPolygons.any((polygon) => _pointInPolygon(point, polygon));
        if (!inBoundary) {
          continue;
        }

        insideCount++;
        final inCovered = coveredPolygons.any((polygon) => _pointInPolygon(point, polygon));
        if (inCovered) {
          coveredCount++;
        }
      }
    }

    if (insideCount == 0) {
      return 0;
    }
    return coveredCount / insideCount;
  }

  static bool _pointInPolygon(LatLng point, List<LatLng> polygon) {
    if (polygon.length < 3) {
      return false;
    }

    var inside = false;
    for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final xi = polygon[i].longitude;
      final yi = polygon[i].latitude;
      final xj = polygon[j].longitude;
      final yj = polygon[j].latitude;

      final intersects = ((yi > point.latitude) != (yj > point.latitude)) &&
          (point.longitude <
              (xj - xi) * (point.latitude - yi) / ((yj - yi).abs().clamp(1e-12, double.infinity)) + xi);
      if (intersects) {
        inside = !inside;
      }
    }

    return inside;
  }

  static _Bounds? _boundsOf(List<LatLng> points) {
    if (points.isEmpty) {
      return null;
    }

    var minLat = points.first.latitude;
    var maxLat = points.first.latitude;
    var minLng = points.first.longitude;
    var maxLng = points.first.longitude;

    for (final point in points.skip(1)) {
      minLat = min(minLat, point.latitude);
      maxLat = max(maxLat, point.latitude);
      minLng = min(minLng, point.longitude);
      maxLng = max(maxLng, point.longitude);
    }

    return _Bounds(minLat: minLat, maxLat: maxLat, minLng: minLng, maxLng: maxLng);
  }

  // 符号付き面積（Shoelace 公式）。CCW = 正（内部面）、CW = 負（外部無限面）。
  static double _signedPolygonAreaSqKm(List<LatLng> polygon) {
    if (polygon.length < 3) {
      return 0;
    }

    final centerLat = polygon.map((p) => p.latitude).reduce((a, b) => a + b) / polygon.length;
    const latScale = 111.32;
    final lngScale = 111.32 * cos(centerLat * pi / 180);

    var area = 0.0;
    for (var i = 0; i < polygon.length; i++) {
      final current = polygon[i];
      final next = polygon[(i + 1) % polygon.length];
      final x1 = current.longitude * lngScale;
      final y1 = current.latitude * latScale;
      final x2 = next.longitude * lngScale;
      final y2 = next.latitude * latScale;
      area += (x1 * y2) - (x2 * y1);
    }

    return area * 0.5;
  }

  static String _snapKey(LatLng point, double latStep, double lngStep) {
    final latBucket = (point.latitude / latStep).round();
    final lngBucket = (point.longitude / lngStep).round();
    return '$latBucket:$lngBucket';
  }
}

class _NodeAccumulator {
  double _latSum = 0;
  double _lngSum = 0;
  int _count = 0;

  void add(LatLng point) {
    _latSum += point.latitude;
    _lngSum += point.longitude;
    _count++;
  }

  LatLng get center => LatLng(_latSum / _count, _lngSum / _count);
}

class _Bounds {
  _Bounds({
    required this.minLat,
    required this.maxLat,
    required this.minLng,
    required this.maxLng,
  });

  final double minLat;
  final double maxLat;
  final double minLng;
  final double maxLng;
}
