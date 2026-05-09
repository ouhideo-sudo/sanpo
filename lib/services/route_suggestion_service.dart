import 'dart:math';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import '../models/directions_route.dart';

class RouteSuggestion {
  RouteSuggestion({
    required this.distanceKm,
    required this.estimatedMinutes,
    required this.points,
    this.directionsRoute,
  });

  final double distanceKm;
  final int estimatedMinutes;
  final List<LatLng> points;

  /// 詳細なルート情報（Directions API から取得した場合）
  final DirectionsRoute? directionsRoute;
}

class RouteSuggestionService {
  // 徒歩速度 4.8 km/h を仮定
  static const double _walkingSpeedKmh = 4.8;
  static const double _earthRadiusKm = 6371.0;

  /// Google Maps Directions API キー
  final String mapsApiKey;

  RouteSuggestionService({required this.mapsApiKey});

  /// Google Maps Directions API を使用して周回ルートを提案
  /// [center]: 現在地
  /// [distanceKm]: 希望距離
  Future<RouteSuggestion> suggestLoopRoute({
    required LatLng center,
    required double distanceKm,
  }) async {
    try {
      // 往路と復路で距離を分割
      final halfDistanceKm = distanceKm / 2;

      // 現在地から半径と方向をランダムに選んで、往路の目的地を決定
      final bearing = Random().nextDouble() * 360;
      final destination = _move(center, halfDistanceKm, bearing);

      // Directions API で往路を取得
      final outboundRoute = await _fetchDirectionsRoute(
        origin: center,
        destination: destination,
      );

      if (outboundRoute == null) {
        // API 失敗時は従来の正方形ルートにフォールバック
        return buildLoop(center: center, distanceKm: distanceKm);
      }

      // 復路は往路の逆向きを取得
      final returnRoute = await _fetchDirectionsRoute(
        origin: destination,
        destination: center,
      );

      if (returnRoute == null) {
        // 復路取得失敗時は往路のみ返す
        return RouteSuggestion(
          distanceKm: outboundRoute.distanceKm,
          estimatedMinutes: outboundRoute.estimatedMinutes,
          points: outboundRoute.polylinePoints,
          directionsRoute: outboundRoute,
        );
      }

      // 往路と復路を結合
      final combinedPoints = <LatLng>[
        ...outboundRoute.polylinePoints,
        ...returnRoute.polylinePoints.skip(1), // 重複を避ける
      ];

      final totalDistanceKm =
          outboundRoute.distanceKm + returnRoute.distanceKm;
      final totalMinutes =
          outboundRoute.estimatedMinutes + returnRoute.estimatedMinutes;

      return RouteSuggestion(
        distanceKm: totalDistanceKm,
        estimatedMinutes: totalMinutes,
        points: combinedPoints,
        directionsRoute: outboundRoute, // 往路をメインに保持
      );
    } catch (e) {
      debugPrint('Error suggesting route: $e');
      // エラー時は従来の正方形ルートにフォールバック
      return buildLoop(center: center, distanceKm: distanceKm);
    }
  }

  /// Google Maps Directions API からルート情報を取得
  Future<DirectionsRoute?> _fetchDirectionsRoute({
    required LatLng origin,
    required LatLng destination,
  }) async {
    try {
      final String url =
          'https://maps.googleapis.com/maps/api/directions/json'
          '?origin=${origin.latitude},${origin.longitude}'
          '&destination=${destination.latitude},${destination.longitude}'
          '&mode=walking'
          '&key=$mapsApiKey';

      final response = await http.get(Uri.parse(url)).timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException('API request timeout'),
      );

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        if (json['status'] == 'OK' && (json['routes'] as List).isNotEmpty) {
          return DirectionsRoute.fromJson(json);
        } else {
          debugPrint('Directions API error: ${json['status']}');
          return null;
        }
      } else {
        debugPrint('HTTP error: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      debugPrint('Exception fetching directions: $e');
      return null;
    }
  }

  /// 従来の正方形周回ルート（フォールバック用）
  static RouteSuggestion buildLoop({
    required LatLng center,
    required double distanceKm,
  }) {
    // 正方形に近い周回ルートを作る（1辺 = 全長の1/4）
    final segmentKm = distanceKm / 4;

    final p1 = _move(center, segmentKm, 0); // 北
    final p2 = _move(p1, segmentKm, 90); // 東
    final p3 = _move(p2, segmentKm, 180); // 南
    final p4 = _move(p3, segmentKm, 270); // 西

    final points = <LatLng>[center, p1, p2, p3, p4, center];
    final estimatedMinutes = ((distanceKm / _walkingSpeedKmh) * 60).round();

    return RouteSuggestion(
      distanceKm: distanceKm,
      estimatedMinutes: max(1, estimatedMinutes),
      points: points,
    );
  }

  static LatLng _move(LatLng from, double distanceKm, double bearingDeg) {
    final bearing = _degToRad(bearingDeg);
    final lat1 = _degToRad(from.latitude);
    final lon1 = _degToRad(from.longitude);
    final angularDistance = distanceKm / _earthRadiusKm;

    final lat2 = asin(
      sin(lat1) * cos(angularDistance) +
          cos(lat1) * sin(angularDistance) * cos(bearing),
    );

    final lon2 = lon1 +
        atan2(
          sin(bearing) * sin(angularDistance) * cos(lat1),
          cos(angularDistance) - sin(lat1) * sin(lat2),
        );

    return LatLng(_radToDeg(lat2), _radToDeg(lon2));
  }

  static double _degToRad(double deg) => deg * pi / 180;
  static double _radToDeg(double rad) => rad * 180 / pi;
}
