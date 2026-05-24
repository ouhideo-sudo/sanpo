class DungeonChallengeResult {
  DungeonChallengeResult({
    required this.id,
    required this.startTime,
    required this.endTime,
    required this.success,
    required this.elapsedSeconds,
    this.points = 0,
  });

  final String id;
  final DateTime startTime;
  final DateTime endTime;
  final bool success;
  final int elapsedSeconds;
  final int points;

  Map<String, dynamic> toJson() => {
        'id': id,
        'startTime': startTime.toIso8601String(),
        'endTime': endTime.toIso8601String(),
        'success': success,
        'elapsedSeconds': elapsedSeconds,
        'points': points,
      };

  factory DungeonChallengeResult.fromJson(Map<String, dynamic> json) {
    return DungeonChallengeResult(
      id: json['id'] as String,
      startTime: DateTime.parse(json['startTime'] as String),
      endTime: DateTime.parse(json['endTime'] as String),
      success: json['success'] as bool,
      elapsedSeconds: json['elapsedSeconds'] as int,
      points: json['points'] as int? ?? 0,
    );
  }

  int get elapsedMinutes => (elapsedSeconds / 60).floor();
}
