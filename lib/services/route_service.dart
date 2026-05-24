import 'dart:convert';
import 'dart:math';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/active_route_draft.dart';
import '../models/dungeon_challenge_result.dart';
import '../models/walk_route.dart';

class RouteService {
  static const _routesKey = 'routes_list';
  static const _activeDraftKey = 'active_route_draft';
  static const _dungeonResultsKey = 'dungeon_results';
  final SharedPreferences prefs;

  RouteService(this.prefs);

  Future<void> saveRoute(WalkRoute route) async {
    final routes = await getRoutes();
    routes.add(route);
    await prefs.setString(
      _routesKey,
      jsonEncode(routes.map((r) => r.toJson()).toList()),
    );
  }

  Future<List<WalkRoute>> getRoutes() async {
    final json = prefs.getString(_routesKey);
    if (json == null) return [];
    
    final List<dynamic> decoded = jsonDecode(json);
    return decoded
        .cast<Map<String, dynamic>>()
        .map(WalkRoute.fromJson)
        .toList()
        .reversed
        .toList();
  }

  Future<void> deleteRoute(String routeId) async {
    final routes = await getRoutes();
    routes.removeWhere((r) => r.id == routeId);
    await prefs.setString(
      _routesKey,
      jsonEncode(routes.map((r) => r.toJson()).toList()),
    );
  }

  Future<void> deleteAllRoutes() async {
    await prefs.remove(_routesKey);
  }

  Future<void> saveActiveDraft(ActiveRouteDraft draft) async {
    await prefs.setString(_activeDraftKey, jsonEncode(draft.toJson()));
  }

  ActiveRouteDraft? getActiveDraft() {
    final json = prefs.getString(_activeDraftKey);
    if (json == null) {
      return null;
    }

    final decoded = jsonDecode(json) as Map<String, dynamic>;
    return ActiveRouteDraft.fromJson(decoded);
  }

  Future<void> clearActiveDraft() async {
    await prefs.remove(_activeDraftKey);
  }

  Future<void> saveDungeonResult(DungeonChallengeResult result) async {
    final results = await getDungeonResults();
    results.add(result);
    await prefs.setString(
      _dungeonResultsKey,
      jsonEncode(results.map((r) => r.toJson()).toList()),
    );
  }

  Future<List<DungeonChallengeResult>> getDungeonResults() async {
    final json = prefs.getString(_dungeonResultsKey);
    if (json == null) {
      return [];
    }

    final decoded = jsonDecode(json) as List<dynamic>;
    return decoded
        .cast<Map<String, dynamic>>()
        .map(DungeonChallengeResult.fromJson)
        .toList()
        .reversed
        .toList();
  }

  /// 2つの地点間の距離をキロメートルで計算（Haversine公式）
  static double calculateDistance(LatLng point1, LatLng point2) {
    const R = 6371; // 地球の半径（キロメートル）
    final lat1 = point1.latitude * pi / 180;
    final lat2 = point2.latitude * pi / 180;
    final deltaLat = (point2.latitude - point1.latitude) * pi / 180;
    final deltaLng = (point2.longitude - point1.longitude) * pi / 180;

    final a = sin(deltaLat / 2) * sin(deltaLat / 2) +
        cos(lat1) * cos(lat2) * sin(deltaLng / 2) * sin(deltaLng / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));

    return R * c;
  }

  /// ルートの総距離を計算
  static double calculateTotalDistance(List<LatLng> points) {
    double totalDistance = 0;
    for (int i = 0; i < points.length - 1; i++) {
      totalDistance += calculateDistance(points[i], points[i + 1]);
    }
    return totalDistance;
  }
}
