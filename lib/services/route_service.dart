import 'dart:convert';
import 'dart:math';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/walk_route.dart';

class RouteService {
  static const _routesKey = 'routes_list';
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
