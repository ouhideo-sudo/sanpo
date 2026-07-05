import 'dart:async';
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

class AdministrativeCoverageResult {
  AdministrativeCoverageResult({
    required this.areaName,
    required this.coverageRatio,
  });

  final String areaName;

  /// 踏破率(0.0〜1.0)。
  final double coverageRatio;
}

class TerritoryCoverageResult {
  TerritoryCoverageResult({
    required this.prefecture,
    required this.city,
    required this.town,
  });

  final AdministrativeCoverageResult prefecture;
  final AdministrativeCoverageResult city;

  /// 町(丁目)層。丁目境界があれば丁目、無ければ約500mメッシュ(「〇〇周辺」)で
  /// 必ず算出するため通常は非null。null になるのは初回計算前と、上位で予期しない
  /// エラーが起きたときのみ。UI では null の間だけ行を出さない。
  final AdministrativeCoverageResult? town;
}

class TerritoryCoverageException implements Exception {
  TerritoryCoverageException(this.message);

  final String message;

  @override
  String toString() => 'TerritoryCoverageException: $message';
}

class _AdministrativeBoundaryResult {
  _AdministrativeBoundaryResult({
    required this.areaName,
    required this.boundaryPolygons,
  });

  final String areaName;
  final List<List<LatLng>> boundaryPolygons;
}

class _CoverageLayerResult {
  _CoverageLayerResult({
    required this.areaName,
    required this.coverageRatio,
    required this.boundaryPolygons,
  });

  final String areaName;
  final double coverageRatio;
  final List<List<LatLng>> boundaryPolygons;
}

class AreaCoverageService {
  static const double _snapThresholdMeters = 20.0;
  static const double _gapCloseMeters = 18.0;
  // 20mスナップだと正当な面でも ~150m² 程度まで小さくなり得る。下限を大きく取ると
  // 囲まれた小区画が塗り残される(白い斑点/穴)ため、数値的な退化面だけを除く小さな値にする。
  static const double _minPolygonAreaSqKm = 0.0001;
  final Map<int, _AdministrativeBoundaryResult> _administrativeBoundaryCache = {};
  // 丁目境界の forward search 結果キャッシュ('市区名/丁目名' -> ポリゴン)。
  // 空リストは「境界が存在しないと確認済み」を表す。
  final Map<String, List<List<LatLng>>> _townBoundaryCache = {};

  List<List<LatLng>> extractEnclosedPolygons(List<WalkRoute> routes) {
    final segmentRoutes = routes.where((route) => route.points.length >= 2).toList();
    if (segmentRoutes.isEmpty) {
      return [];
    }

    final allSegmentPoints = segmentRoutes.expand((route) => route.points);
    final avgLatitude =
        allSegmentPoints.map((point) => point.latitude).reduce((a, b) => a + b) /
        segmentRoutes.fold<int>(0, (sum, route) => sum + route.points.length);
    final latStep = _snapThresholdMeters / 111320.0;
    final lngScale = cos(avgLatitude * pi / 180).abs().clamp(0.2, 1.0);
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

    _bridgeNearbyDanglingNodes(nodes, adjacency);

    // 各ノードの隣接ノードを方位角で CCW 順にソートする（プラナー面検出に必要）
    final sortedAdj = <String, List<String>>{};
    final orderedNodeKeys = adjacency.keys.toList()..sort();
    for (final u in orderedNodeKeys) {
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

    // 連結成分を求める（union-find）。成分ごとに外周(非有界面)を1つだけ除外するため。
    final parent = <String, String>{};
    String findRoot(String x) {
      parent.putIfAbsent(x, () => x);
      var root = x;
      while (parent[root] != root) {
        root = parent[root]!;
      }
      var cur = x;
      while (parent[cur] != root) {
        final next = parent[cur]!;
        parent[cur] = root;
        cur = next;
      }
      return root;
    }

    void union(String a, String b) {
      final ra = findRoot(a);
      final rb = findRoot(b);
      if (ra != rb) parent[ra] = rb;
    }

    for (final entry in adjacency.entries) {
      for (final neighbor in entry.value) {
        union(entry.key, neighbor);
      }
    }

    // 半エッジ法でプラナーグラフの全ての面を追跡する。
    // 有向辺 (u→v) の次の面辺は (v → CCW リスト上で u の一つ前の隣接ノード)。
    final halfEdgeVisited = <String>{};
    final faces = <({List<LatLng> nodes, double absArea, String comp})>[];
    final safetyLimit = sortedAdj.length * 8;

    for (final u in orderedNodeKeys) {
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
        faces.add((
          nodes: faceNodes,
          absArea: _signedPolygonAreaSqKm(faceNodes).abs(),
          comp: findRoot(u),
        ));
      }
    }

    // 各連結成分で面積最大の面＝外周(非有界面)。これを成分ごとに1つだけ除外し、
    // 残る内部面(＝ルートに囲まれた領域)をすべて採用する。固定の面積上限を使わない
    // ため、大きな囲みも塗り残されない。単純な1周ループは内・外で同形の面が2つできるが、
    // 外周を1つ外せば残り1つがその領域を正しく塗る。
    final maxAreaByComp = <String, double>{};
    for (final face in faces) {
      if (face.absArea > (maxAreaByComp[face.comp] ?? -1)) {
        maxAreaByComp[face.comp] = face.absArea;
      }
    }

    final outerRemovedComps = <String>{};
    final enclosedPolygons = <List<LatLng>>[];
    for (final face in faces) {
      if (!outerRemovedComps.contains(face.comp) &&
          face.absArea >= maxAreaByComp[face.comp]! - 1e-9) {
        outerRemovedComps.add(face.comp);
        continue;
      }
      if (face.absArea < _minPolygonAreaSqKm) continue;
      enclosedPolygons.add(face.nodes);
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

    final coverage = await _estimateCoverageLayer(
      reference: reference,
      coveredPolygons: coveredPolygons,
      zoom: 10,
      areaLabel: '自治体',
      sampleSteps: 90,
      nameResolver: _extractCityName,
    );

    return MunicipalityCoverageResult(
      municipalityName: coverage.areaName,
      coverageRatio: coverage.coverageRatio,
      boundaryPolygons: coverage.boundaryPolygons,
    );
  }

  Future<TerritoryCoverageResult> estimateTerritoryCoverage({
    required LatLng reference,
    required List<List<LatLng>> coveredPolygons,
  }) async {
    final prefecture = await _estimateCoverageLayer(
      reference: reference,
      coveredPolygons: coveredPolygons,
      zoom: 5,
      areaLabel: '都道府県',
      sampleSteps: 90,
      nameResolver: (address, json) => _extractPrefectureName(address, json),
    );

    final city = await _estimateCoverageLayer(
      reference: reference,
      coveredPolygons: coveredPolygons,
      zoom: 10,
      areaLabel: '市区',
      sampleSteps: 120,
      nameResolver: (address, json) => _extractCityName(address, json),
    );

    // 町(丁目)層は _estimateTownCoverage 内でエラーをメッシュにフォールバックする
    // ため通常は非nullを返す。ここでの catch は万一の想定外例外に対する保険で、
    // 町層が失敗しても都道府県・市区の表示を維持するためのもの。
    AdministrativeCoverageResult? town;
    try {
      town = await _estimateTownCoverage(
        reference: reference,
        coveredPolygons: coveredPolygons,
        sampleSteps: 240,
      );
    } on TerritoryCoverageException {
      town = null;
    }

    return TerritoryCoverageResult(
      prefecture: AdministrativeCoverageResult(
        areaName: prefecture.areaName,
        coverageRatio: prefecture.coverageRatio,
      ),
      city: AdministrativeCoverageResult(
        areaName: city.areaName,
        coverageRatio: city.coverageRatio,
      ),
      town: town,
    );
  }

  /// 町(丁目)の踏破率を推定する。
  ///
  /// 逆ジオコーディングは高ズームでも「最も近い建物・道路」を返すだけで丁目の
  /// 行政境界を返さないため、丁目名を取得したうえで forward search し、
  /// 行政境界(boundary)のポリゴンを取得する。境界がOSMに無い地域(例: 市川市
  /// 大洲三丁目 はポイントのみ)や解決に失敗した場合は、約500mの標準地域メッシュ
  /// にフォールバックして必ず踏破率を返す。
  Future<AdministrativeCoverageResult?> _estimateTownCoverage({
    required LatLng reference,
    required List<List<LatLng>> coveredPolygons,
    required int sampleSteps,
  }) async {
    String? townName;
    try {
      final resolved = await _resolveTownAddress(reference: reference);
      if (resolved != null) {
        townName = _normalizeChomeNumerals(resolved.rawTownName);
        final boundary = await _resolveTownBoundary(
          rawTownName: resolved.rawTownName,
          cityName: resolved.cityName,
        );
        if (boundary != null && boundary.isNotEmpty) {
          final ratio = _estimateCoverageRatio(
            boundaryPolygons: boundary,
            coveredPolygons: coveredPolygons,
            steps: sampleSteps,
          );
          return AdministrativeCoverageResult(
            areaName: townName,
            coverageRatio: ratio,
          );
        }
      }
    } on TerritoryCoverageException {
      // 丁目名・境界の解決に失敗してもメッシュにフォールバックする。
    }

    // フォールバック: 約500m四方の標準地域メッシュを対象エリアとする。
    final meshRatio = _estimateCoverageRatio(
      boundaryPolygons: [_standardMeshCell(reference)],
      coveredPolygons: coveredPolygons,
      steps: sampleSteps,
    );
    return AdministrativeCoverageResult(
      areaName: townName == null ? '現在地周辺' : '$townName周辺',
      coverageRatio: meshRatio,
    );
  }

  /// 地域メッシュ(JIS X 0410)の4次メッシュ相当(約500m四方)のセルを返す。
  /// 丁目境界が無い地域で踏破率の対象エリアとして使う。全国共通のグリッドに
  /// スナップするため、同じ場所では常に同じセルになる。
  static List<LatLng> _standardMeshCell(LatLng point) {
    const latStep = 1.0 / 240.0; // 緯度15秒 ≒ 約460m
    const lonStep = 1.0 / 160.0; // 経度22.5秒 ≒ 約570m(北緯35度付近)
    final latMin = (point.latitude / latStep).floorToDouble() * latStep;
    final lonMin = (point.longitude / lonStep).floorToDouble() * lonStep;
    final latMax = latMin + latStep;
    final lonMax = lonMin + lonStep;
    return [
      LatLng(latMin, lonMin),
      LatLng(latMin, lonMax),
      LatLng(latMax, lonMax),
      LatLng(latMax, lonMin),
    ];
  }

  Future<_CoverageLayerResult> _estimateCoverageLayer({
    required LatLng reference,
    required List<List<LatLng>> coveredPolygons,
    required int zoom,
    required String areaLabel,
    required int sampleSteps,
    required String Function(Map<String, dynamic> address, Map<String, dynamic> json)
        nameResolver,
  }) async {
    final boundaryResult = await _resolveAdministrativeBoundary(
      reference: reference,
      zoom: zoom,
      areaLabel: areaLabel,
      nameResolver: nameResolver,
    );
    final ratio = _estimateCoverageRatio(
      boundaryPolygons: boundaryResult.boundaryPolygons,
      coveredPolygons: coveredPolygons,
      steps: sampleSteps,
    );

    return _CoverageLayerResult(
      areaName: boundaryResult.areaName,
      coverageRatio: ratio,
      boundaryPolygons: boundaryResult.boundaryPolygons,
    );
  }

  Future<_AdministrativeBoundaryResult> _resolveAdministrativeBoundary({
    required LatLng reference,
    required int zoom,
    required String areaLabel,
    required String Function(Map<String, dynamic> address, Map<String, dynamic> json)
        nameResolver,
  }) async {
    final cached = _administrativeBoundaryCache[zoom];
    if (cached != null && _isPointInAnyPolygon(reference, cached.boundaryPolygons)) {
      return cached;
    }

    final json = await _reverseLookup(reference: reference, zoom: zoom);

    final boundary = _parseBoundaryPolygons(json['geojson']);
    if (boundary.isEmpty) {
      throw TerritoryCoverageException('$areaLabel の境界ポリゴンを取得できませんでした。');
    }

    final address = (json['address'] as Map<String, dynamic>?) ?? const {};
    final name = nameResolver(address, json);
    if (name.isEmpty) {
      throw TerritoryCoverageException('$areaLabel の名称を解決できませんでした。');
    }

    final result = _AdministrativeBoundaryResult(
      areaName: name,
      boundaryPolygons: boundary,
    );
    _administrativeBoundaryCache[zoom] = result;
    return result;
  }

  Future<Map<String, dynamic>> _reverseLookup({
    required LatLng reference,
    required int zoom,
  }) async {
    final uri = Uri.parse(
      'https://nominatim.openstreetmap.org/reverse'
      '?format=jsonv2'
      '&lat=${reference.latitude}'
      '&lon=${reference.longitude}'
      '&zoom=$zoom'
      '&addressdetails=1'
      '&polygon_geojson=1',
    );

    final json = await _getNominatimJson(uri, context: 'zoom=$zoom');
    if (json is! Map<String, dynamic>) {
      throw TerritoryCoverageException('Nominatim の応答形式が不正です (zoom=$zoom)。');
    }
    return json;
  }

  /// 丁目名(neighbourhood)と市区名を高ズームの逆ジオコーディングで解決する。
  /// zoom 18 で neighbourhood が空なら 16 にフォールバックする。
  Future<({String rawTownName, String cityName})?> _resolveTownAddress({
    required LatLng reference,
  }) async {
    for (final zoom in const [18, 16]) {
      final json = await _reverseLookup(reference: reference, zoom: zoom);
      final address = (json['address'] as Map<String, dynamic>?) ?? const {};
      final raw = _extractRawTownName(address, json);
      if (raw != null && raw.isNotEmpty) {
        return (rawTownName: raw, cityName: _extractCityName(address, json));
      }
    }
    return null;
  }

  /// 丁目名で forward search し、行政境界(boundary)のポリゴンを取得する。
  /// 見つからない場合(丁目がポイントのみの地域など)は null。
  Future<List<List<LatLng>>?> _resolveTownBoundary({
    required String rawTownName,
    required String cityName,
  }) async {
    // 市区名が無いと「本町」「旭町」等の全国頻出名で別自治体・国外の境界を拾い、
    // もっともらしい誤った踏破率になるため、検索せずメッシュへフォールバックさせる。
    if (cityName.isEmpty) {
      return null;
    }

    final cacheKey = '$cityName/$rawTownName';
    final cached = _townBoundaryCache[cacheKey];
    if (cached != null) {
      return cached.isEmpty ? null : cached;
    }

    final query = '$rawTownName, $cityName';
    final uri = Uri.parse(
      'https://nominatim.openstreetmap.org/search'
      '?format=jsonv2'
      '&q=${Uri.encodeQueryComponent(query)}'
      '&addressdetails=1'
      '&polygon_geojson=1'
      '&limit=5',
    );

    final decoded = await _getNominatimJson(uri, context: 'town=$rawTownName');
    if (decoded is List) {
      for (final item in decoded) {
        if (item is! Map<String, dynamic>) continue;
        if (item['category'] != 'boundary') continue;
        final polygons = _parseBoundaryPolygons(item['geojson']);
        if (polygons.isNotEmpty) {
          _townBoundaryCache[cacheKey] = polygons;
          return polygons;
        }
      }
    }
    _townBoundaryCache[cacheKey] = const [];
    return null;
  }

  /// Nominatim へ GET し、JSON をデコードして返す。通信・HTTP・パースの
  /// いずれの失敗も TerritoryCoverageException に統一する(非JSONの200応答で
  /// FormatException が上位に漏れて全踏破率がエラー化するのを防ぐ)。
  Future<dynamic> _getNominatimJson(Uri uri, {required String context}) async {
    http.Response response;
    try {
      response = await http.get(
        uri,
        headers: const {
          'User-Agent': 'sanpo-app/1.0 (route-coverage-feature)',
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw TerritoryCoverageException('通信がタイムアウトしました ($context)。');
    } catch (_) {
      throw TerritoryCoverageException('Nominatim への通信に失敗しました ($context)。');
    }

    if (response.statusCode != 200) {
      throw TerritoryCoverageException(
        'Nominatim へのリクエストが失敗しました (HTTP ${response.statusCode}, $context)。',
      );
    }

    try {
      return jsonDecode(response.body);
    } on FormatException {
      throw TerritoryCoverageException('Nominatim の応答を解析できませんでした ($context)。');
    }
  }

  static bool _isPointInAnyPolygon(LatLng point, List<List<LatLng>> polygons) {
    return polygons.any((polygon) => _pointInPolygon(point, polygon));
  }

  static String _extractPrefectureName(
    Map<String, dynamic> address,
    Map<String, dynamic> json,
  ) {
    return (address['state'] as String?) ??
        (address['province'] as String?) ??
        (address['region'] as String?) ??
        (json['name'] as String?) ??
        '';
  }

  static String _extractCityName(
    Map<String, dynamic> address,
    Map<String, dynamic> json,
  ) {
    return (address['city'] as String?) ??
        (address['city_district'] as String?) ??
        (address['municipality'] as String?) ??
        (address['county'] as String?) ??
        (address['town'] as String?) ??
        (address['village'] as String?) ??
        (json['name'] as String?) ??
          '';
  }

  /// 丁目名の生の値(漢数字のまま。forward search のクエリに使う)を抽出する。
  /// 表示用に算用数字へ正規化する場合は呼び出し側で [_normalizeChomeNumerals] を通す。
  static String? _extractRawTownName(
    Map<String, dynamic> address,
    Map<String, dynamic> json,
  ) {
    final cityName = _extractCityName(address, json);
    final candidates = <String?>[
      address['neighbourhood'] as String?,
      address['city_block'] as String?,
      address['block'] as String?,
      address['residential'] as String?,
      json['name'] as String?,
      address['quarter'] as String?,
      address['suburb'] as String?,
      address['district'] as String?,
      address['borough'] as String?,
      address['allotments'] as String?,
      address['hamlet'] as String?,
      address['town'] as String?,
      address['village'] as String?,
      address['city_district'] as String?,
    ];

    for (final candidate in candidates) {
      final value = candidate?.trim();
      if (value == null || value.isEmpty) {
        continue;
      }
      if (value == cityName) {
        continue;
      }
      return value;
    }

    return null;
  }

  static String _normalizeChomeNumerals(String input) {
    final pattern = RegExp(r'([〇零一二三四五六七八九十]+)丁目');
    return input.replaceAllMapped(pattern, (match) {
      final japaneseNumber = match.group(1)!;
      final parsed = _parseJapaneseNumber(japaneseNumber);
      if (parsed == null) {
        return match.group(0)!;
      }
      return '$parsed丁目';
    });
  }

  static int? _parseJapaneseNumber(String value) {
    if (value.isEmpty) {
      return null;
    }

    final digits = <String, int>{
      '〇': 0,
      '零': 0,
      '一': 1,
      '二': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
    };

    if (!value.contains('十')) {
      final parsed = value.split('').map((c) => digits[c]).toList();
      if (parsed.any((n) => n == null)) {
        return null;
      }
      return parsed.cast<int>().fold<int>(0, (acc, n) => acc * 10 + n);
    }

    final parts = value.split('十');
    if (parts.length != 2) {
      return null;
    }

    final tensPart = parts[0];
    final onesPart = parts[1];

    int tens;
    if (tensPart.isEmpty) {
      tens = 1;
    } else {
      final digit = digits[tensPart];
      if (digit == null || digit == 0) {
        return null;
      }
      tens = digit;
    }

    var ones = 0;
    if (onesPart.isNotEmpty) {
      final digit = digits[onesPart];
      if (digit == null) {
        return null;
      }
      ones = digit;
    }

    return tens * 10 + ones;
  }

  static List<List<LatLng>> _parseBoundaryPolygons(dynamic geojson) {
    if (geojson is! Map<String, dynamic>) {
      return [];
    }

    final type = geojson['type'] as String?;
    final coordinates = geojson['coordinates'];

    if (type == 'Feature') {
      return _parseBoundaryPolygons(geojson['geometry']);
    }

    if (type == 'FeatureCollection') {
      final features = geojson['features'];
      if (features is! List) {
        return [];
      }
      final polygons = <List<LatLng>>[];
      for (final feature in features) {
        polygons.addAll(_parseBoundaryPolygons(feature));
      }
      return polygons;
    }

    if (type == 'GeometryCollection') {
      final geometries = geojson['geometries'];
      if (geometries is! List) {
        return [];
      }
      final polygons = <List<LatLng>>[];
      for (final geometry in geometries) {
        polygons.addAll(_parseBoundaryPolygons(geometry));
      }
      return polygons;
    }

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
    int steps = 90,
  }) {
    final bounds = _boundsOf(boundaryPolygons.expand((e) => e).toList());
    if (bounds == null) {
      return 0;
    }

    steps = steps.clamp(60, 360);
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

  /// 切れ目になりやすい次数1ノード同士を近接距離でブリッジし、
  /// GPSゆらぎによる微小ギャップを閉じる。
  static void _bridgeNearbyDanglingNodes(
    Map<String, LatLng> nodes,
    Map<String, Set<String>> adjacency,
  ) {
    final dangling = adjacency.entries
        .where((e) => e.value.length == 1)
        .map((e) => e.key)
        .toList()
      ..sort();

    for (var i = 0; i < dangling.length; i++) {
      final a = dangling[i];
      if ((adjacency[a]?.length ?? 0) != 1) continue;

      String? best;
      var bestDistance = double.infinity;

      for (var j = i + 1; j < dangling.length; j++) {
        final b = dangling[j];
        if ((adjacency[b]?.length ?? 0) != 1) continue;
        if (adjacency[a]!.contains(b)) continue;

        final distance = _distanceMeters(nodes[a]!, nodes[b]!);
        if (distance <= _gapCloseMeters && distance < bestDistance) {
          best = b;
          bestDistance = distance;
        }
      }

      if (best != null) {
        adjacency[a]!.add(best);
        adjacency[best]!.add(a);
      }
    }
  }

  static double _distanceMeters(LatLng a, LatLng b) {
    const r = 6371000.0;
    final dLat = (b.latitude - a.latitude) * pi / 180.0;
    final dLng = (b.longitude - a.longitude) * pi / 180.0;
    final lat1 = a.latitude * pi / 180.0;
    final lat2 = b.latitude * pi / 180.0;

    final h = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1) * cos(lat2) * sin(dLng / 2) * sin(dLng / 2);
    return 2 * r * asin(min(1.0, sqrt(h)));
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
