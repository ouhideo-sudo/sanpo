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
  static const double _minPolygonAreaSqKm = 0.003;

  List<List<LatLng>> extractEnclosedPolygons(List<WalkRoute> routes) {
    final segmentRoutes = routes.where((route) => route.points.length >= 2).toList();
    if (segmentRoutes.isEmpty) {
      return [];
    }

    final ref = segmentRoutes.first.points.first;
    final latStep = _snapThresholdMeters / 111320.0;
    final lngScale = cos(ref.latitude * pi / 180).abs().clamp(0.2, 1.0);
    final lngStep = _snapThresholdMeters / (111320.0 * lngScale);

    // 全ルートの生セグメントを収集する
    final rawSegments = <(LatLng, LatLng)>[];
    for (final route in segmentRoutes) {
      for (var i = 0; i < route.points.length - 1; i++) {
        rawSegments.add((route.points[i], route.points[i + 1]));
      }
    }

    // セグメント同士の交差点でエッジを分割し、真に平面なグラフを構築する
    final splitSegments = _splitAtIntersections(rawSegments);

    final nodeStore = <String, _NodeAccumulator>{};
    final adjacency = <String, Set<String>>{};

    for (final (a, b) in splitSegments) {
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

  /// セグメントリストを受け取り、互いに交差する箇所で分割した新リストを返す。
  /// これにより GPS 軌跡の交差点にノードが生まれ、半エッジ法で囲みが検出できる。
  static List<(LatLng, LatLng)> _splitAtIntersections(
    List<(LatLng, LatLng)> segs,
  ) {
    final n = segs.length;
    if (n < 2) return segs;
    const eps = 1e-6;

    // 各セグメントに交差するパラメータ t を収集する
    final splitTs = List<List<double>>.generate(n, (_) => []);

    for (var i = 0; i < n; i++) {
      final (a1, a2) = segs[i];
      final aMinLat = min(a1.latitude, a2.latitude);
      final aMaxLat = max(a1.latitude, a2.latitude);
      final aMinLng = min(a1.longitude, a2.longitude);
      final aMaxLng = max(a1.longitude, a2.longitude);

      for (var j = i + 1; j < n; j++) {
        final (b1, b2) = segs[j];
        // バウンディングボックスで高速却下
        if (max(b1.latitude, b2.latitude) < aMinLat ||
            min(b1.latitude, b2.latitude) > aMaxLat ||
            max(b1.longitude, b2.longitude) < aMinLng ||
            min(b1.longitude, b2.longitude) > aMaxLng) {
          continue;
        }

        final inter = _intersectParams(a1, a2, b1, b2);
        if (inter != null) {
          // 端点は既に共有ノードとして扱われるので内部交差のみ分割する
          if (inter.$1 > eps && inter.$1 < 1 - eps) splitTs[i].add(inter.$1);
          if (inter.$2 > eps && inter.$2 < 1 - eps) splitTs[j].add(inter.$2);
          continue;
        }

        // 平行で同一直線上に重なる場合（往復・折り返し）も分割点を追加する
        final overlap = _colinearOverlapParams(a1, a2, b1, b2);
        if (overlap == null) continue;

        if (overlap.$1 > eps && overlap.$1 < 1 - eps) splitTs[i].add(overlap.$1);
        if (overlap.$2 > eps && overlap.$2 < 1 - eps) splitTs[i].add(overlap.$2);
        if (overlap.$3 > eps && overlap.$3 < 1 - eps) splitTs[j].add(overlap.$3);
        if (overlap.$4 > eps && overlap.$4 < 1 - eps) splitTs[j].add(overlap.$4);
      }
    }

    final result = <(LatLng, LatLng)>[];
    for (var i = 0; i < n; i++) {
      final (start, end) = segs[i];
      final ts = splitTs[i];
      if (ts.isEmpty) {
        result.add((start, end));
      } else {
        ts.sort();
        final normalizedTs = <double>[];
        for (final t in ts) {
          if (t <= eps || t >= 1 - eps) {
            continue;
          }
          if (normalizedTs.isEmpty || (t - normalizedTs.last).abs() > eps) {
            normalizedTs.add(t);
          }
        }

        if (normalizedTs.isEmpty) {
          result.add((start, end));
          continue;
        }

        var prev = start;
        for (final t in normalizedTs) {
          final pt = LatLng(
            start.latitude + t * (end.latitude - start.latitude),
            start.longitude + t * (end.longitude - start.longitude),
          );
          result.add((prev, pt));
          prev = pt;
        }
        result.add((prev, end));
      }
    }
    return result;
  }

  /// 2セグメントの交差パラメータ (t, s) を返す。t はセグメント1上、s はセグメント2上の位置。
  /// 交差しない（平行 or 範囲外）場合は null を返す。
  static (double, double)? _intersectParams(
    LatLng a1, LatLng a2,
    LatLng b1, LatLng b2,
  ) {
    final dx1 = a2.longitude - a1.longitude;
    final dy1 = a2.latitude - a1.latitude;
    final dx2 = b2.longitude - b1.longitude;
    final dy2 = b2.latitude - b1.latitude;

    final denom = dx1 * dy2 - dy1 * dx2;
    if (denom.abs() < 1e-14) return null; // 平行

    final dx3 = b1.longitude - a1.longitude;
    final dy3 = b1.latitude - a1.latitude;
    final t = (dx3 * dy2 - dy3 * dx2) / denom;
    final s = (dx3 * dy1 - dy3 * dx1) / denom;

    if (t < -1e-6 || t > 1 + 1e-6 || s < -1e-6 || s > 1 + 1e-6) return null;
    return (t, s);
  }

  /// 同一直線上でセグメントが重なる場合の分割パラメータを返す。
  /// 戻り値は (aStart, aEnd, bStart, bEnd)。
  static (double, double, double, double)? _colinearOverlapParams(
    LatLng a1,
    LatLng a2,
    LatLng b1,
    LatLng b2,
  ) {
    const eps = 1e-9;
    final adx = a2.longitude - a1.longitude;
    final ady = a2.latitude - a1.latitude;
    final aLenSq = adx * adx + ady * ady;
    if (aLenSq < eps) return null;

    final cross1 = (b1.longitude - a1.longitude) * ady - (b1.latitude - a1.latitude) * adx;
    final cross2 = (b2.longitude - a1.longitude) * ady - (b2.latitude - a1.latitude) * adx;
    if (cross1.abs() > 1e-7 || cross2.abs() > 1e-7) {
      return null;
    }

    final tB1 = ((b1.longitude - a1.longitude) * adx + (b1.latitude - a1.latitude) * ady) / aLenSq;
    final tB2 = ((b2.longitude - a1.longitude) * adx + (b2.latitude - a1.latitude) * ady) / aLenSq;

    final overlapStart = max(0.0, min(tB1, tB2));
    final overlapEnd = min(1.0, max(tB1, tB2));
    if (overlapEnd - overlapStart <= 1e-6) {
      return null;
    }

    final pStart = LatLng(
      a1.latitude + (a2.latitude - a1.latitude) * overlapStart,
      a1.longitude + (a2.longitude - a1.longitude) * overlapStart,
    );
    final pEnd = LatLng(
      a1.latitude + (a2.latitude - a1.latitude) * overlapEnd,
      a1.longitude + (a2.longitude - a1.longitude) * overlapEnd,
    );

    final bdx = b2.longitude - b1.longitude;
    final bdy = b2.latitude - b1.latitude;
    final bLenSq = bdx * bdx + bdy * bdy;
    if (bLenSq < eps) return null;

    final sStart = ((pStart.longitude - b1.longitude) * bdx + (pStart.latitude - b1.latitude) * bdy) / bLenSq;
    final sEnd = ((pEnd.longitude - b1.longitude) * bdx + (pEnd.latitude - b1.latitude) * bdy) / bLenSq;

    final bStart = min(sStart, sEnd);
    final bEnd = max(sStart, sEnd);
    return (overlapStart, overlapEnd, bStart, bEnd);
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
