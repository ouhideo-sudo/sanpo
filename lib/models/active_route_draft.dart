import 'package:google_maps_flutter/google_maps_flutter.dart';

class ActiveRouteDraft {
  ActiveRouteDraft({
    required this.startTime,
    required this.points,
    required this.isSuggested,
    this.targetDistanceKm,
    this.suggestedDestination,
  });

  final DateTime startTime;
  final List<LatLng> points;
  final bool isSuggested;
  final double? targetDistanceKm;
  final LatLng? suggestedDestination;

  Map<String, dynamic> toJson() => {
        'startTime': startTime.toIso8601String(),
        'points': points
            .map((point) => {
                  'lat': point.latitude,
                  'lng': point.longitude,
                })
            .toList(),
        'isSuggested': isSuggested,
        'targetDistanceKm': targetDistanceKm,
        'suggestedDestination': suggestedDestination == null
            ? null
            : {
                'lat': suggestedDestination!.latitude,
                'lng': suggestedDestination!.longitude,
              },
      };

  factory ActiveRouteDraft.fromJson(Map<String, dynamic> json) {
    final destinationJson = json['suggestedDestination'] as Map<String, dynamic>?;
    return ActiveRouteDraft(
      startTime: DateTime.parse(json['startTime'] as String),
      points: (json['points'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(
            (point) => LatLng(
              (point['lat'] as num).toDouble(),
              (point['lng'] as num).toDouble(),
            ),
          )
          .toList(),
      isSuggested: json['isSuggested'] as bool? ?? false,
      targetDistanceKm: (json['targetDistanceKm'] as num?)?.toDouble(),
      suggestedDestination: destinationJson == null
          ? null
          : LatLng(
              (destinationJson['lat'] as num).toDouble(),
              (destinationJson['lng'] as num).toDouble(),
            ),
    );
  }
}