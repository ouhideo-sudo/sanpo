import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Google Maps Directions API のレスポンスから構築するルート情報
class DirectionsRoute {
  DirectionsRoute({
    required this.summary,
    required this.polylinePoints,
    required this.legs,
    required this.distanceMeters,
    required this.durationSeconds,
  });

  /// ルート概要 (e.g. "5.2 km, about 1 hour 10 mins")
  final String summary;

  /// ポリライン（座標列）
  final List<LatLng> polylinePoints;

  /// ルートの区間リスト
  final List<RouteLeg> legs;

  /// 総距離（メートル）
  final int distanceMeters;

  /// 総時間（秒）
  final int durationSeconds;

  /// 距離（km）
  double get distanceKm => distanceMeters / 1000.0;

  /// 推定時間（分）
  int get estimatedMinutes => (durationSeconds / 60).round();

  /// JSON からのファクトリコンストラクタ
  factory DirectionsRoute.fromJson(Map<String, dynamic> json) {
    final route = json['routes'][0] as Map<String, dynamic>;
    final legs = (route['legs'] as List)
        .map((leg) => RouteLeg.fromJson(leg as Map<String, dynamic>))
        .toList();

    final polylineString = route['overview_polyline']['points'] as String;
    final polylinePoints = _decodePolyline(polylineString);

    return DirectionsRoute(
      summary: route['summary'] as String? ?? '',
      polylinePoints: polylinePoints,
      legs: legs,
      distanceMeters: (route['legs'] as List)
          .fold(0, (sum, leg) => sum + (leg['distance']['value'] as int? ?? 0)),
      durationSeconds: (route['legs'] as List)
          .fold(0, (sum, leg) => sum + (leg['duration']['value'] as int? ?? 0)),
    );
  }

  /// Polyline format をデコード (encoded polyline から LatLng 列に変換)
  static List<LatLng> _decodePolyline(String encoded) {
    final points = <LatLng>[];
    int index = 0, lat = 0, lng = 0;

    while (index < encoded.length) {
      int result = 0;
      int shift = 0;

      int b;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);

      final dlat = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      lat += dlat;

      result = 0;
      shift = 0;

      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);

      final dlng = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      lng += dlng;

      points.add(LatLng(lat / 1e5, lng / 1e5));
    }

    return points;
  }
}

/// ルートの区間（複数の step で構成）
class RouteLeg {
  RouteLeg({
    required this.summary,
    required this.steps,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.startLocation,
    required this.endLocation,
  });

  /// 区間概要
  final String summary;

  /// ターン・ターン指示のリスト
  final List<RouteStep> steps;

  /// 区間距離（メートル）
  final int distanceMeters;

  /// 区間時間（秒）
  final int durationSeconds;

  /// 区間の開始地点
  final LatLng startLocation;

  /// 区間の終了地点
  final LatLng endLocation;

  factory RouteLeg.fromJson(Map<String, dynamic> json) {
    final steps = (json['steps'] as List)
        .map((step) => RouteStep.fromJson(step as Map<String, dynamic>))
        .toList();

    final startLoc = json['start_location'] as Map<String, dynamic>;
    final endLoc = json['end_location'] as Map<String, dynamic>;

    return RouteLeg(
      summary: json['summary'] as String? ?? '',
      steps: steps,
      distanceMeters: json['distance']['value'] as int? ?? 0,
      durationSeconds: json['duration']['value'] as int? ?? 0,
      startLocation: LatLng(startLoc['lat'], startLoc['lng']),
      endLocation: LatLng(endLoc['lat'], endLoc['lng']),
    );
  }
}

/// ルートのステップ（ターン・ターン指示）
class RouteStep {
  RouteStep({
    required this.instruction,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.location,
    required this.maneuver,
  });

  /// ターン・ターン指示 (e.g. "Turn right onto Main St")
  final String instruction;

  /// ステップの距離（メートル）
  final int distanceMeters;

  /// ステップの時間（秒）
  final int durationSeconds;

  /// ステップの位置
  final LatLng location;

  /// 操作タイプ (e.g. "turn-right", "head-north")
  final String maneuver;

  factory RouteStep.fromJson(Map<String, dynamic> json) {
    final loc = json['start_location'] as Map<String, dynamic>;

    return RouteStep(
      instruction: _htmlToPlain(json['html_instructions'] as String? ?? ''),
      distanceMeters: json['distance']['value'] as int? ?? 0,
      durationSeconds: json['duration']['value'] as int? ?? 0,
      location: LatLng(loc['lat'], loc['lng']),
      maneuver: json['maneuver'] as String? ?? 'unknown',
    );
  }

  /// HTML タグを削除してプレーンテキストに変換
  static String _htmlToPlain(String html) {
    return html
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
  }
}
