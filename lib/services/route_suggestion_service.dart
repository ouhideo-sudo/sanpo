import 'dart:math';

import 'package:google_maps_flutter/google_maps_flutter.dart';

class RouteSuggestion {
  RouteSuggestion({
    required this.distanceKm,
    required this.estimatedMinutes,
    required this.points,
  });

  final double distanceKm;
  final int estimatedMinutes;
  final List<LatLng> points;
}

class RouteSuggestionService {
  // 徒歩速度 4.8 km/h を仮定
  static const double _walkingSpeedKmh = 4.8;
  static const double _earthRadiusKm = 6371.0;

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
