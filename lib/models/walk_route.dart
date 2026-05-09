import 'package:google_maps_flutter/google_maps_flutter.dart';

class WalkRoute {
  final String id;
  final DateTime startTime;
  final DateTime endTime;
  final List<LatLng> points;
  final double distanceKm;
  final int durationMinutes;
  final bool isSuggested;
  final bool isSuggestedCompleted;

  WalkRoute({
    required this.id,
    required this.startTime,
    required this.endTime,
    required this.points,
    required this.distanceKm,
    required this.durationMinutes,
    this.isSuggested = false,
    this.isSuggestedCompleted = false,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'startTime': startTime.toIso8601String(),
    'endTime': endTime.toIso8601String(),
    'points': points.map((p) => {'lat': p.latitude, 'lng': p.longitude}).toList(),
    'distanceKm': distanceKm,
    'durationMinutes': durationMinutes,
    'isSuggested': isSuggested,
    'isSuggestedCompleted': isSuggestedCompleted,
  };

  factory WalkRoute.fromJson(Map<String, dynamic> json) => WalkRoute(
    id: json['id'] as String,
    startTime: DateTime.parse(json['startTime'] as String),
    endTime: DateTime.parse(json['endTime'] as String),
    points: (json['points'] as List)
        .cast<Map<String, dynamic>>()
        .map((p) => LatLng(p['lat'] as double, p['lng'] as double))
        .toList(),
    distanceKm: json['distanceKm'] as double,
    durationMinutes: json['durationMinutes'] as int,
    isSuggested: json['isSuggested'] as bool? ?? false,
    isSuggestedCompleted: json['isSuggestedCompleted'] as bool? ?? false,
  );

  double get speedKmh {
    if (durationMinutes <= 0) {
      return 0;
    }
    return distanceKm / (durationMinutes / 60);
  }
}
