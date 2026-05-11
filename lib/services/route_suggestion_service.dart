import 'dart:math';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import '../models/directions_route.dart';

enum RouteSuggestionFailureType {
  noRouteFound,
  apiKeyDenied,
  quotaExceeded,
  invalidRequest,
  timeout,
  network,
  unknown,
}

class RouteSuggestionException implements Exception {
  RouteSuggestionException({
    required this.type,
    required this.userMessage,
    this.rawStatus,
  });

  final RouteSuggestionFailureType type;
  final String userMessage;
  final String? rawStatus;
}

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
  static const double _earthRadiusKm = 6371.0;

  /// Google Maps Directions API キー
  final String mapsApiKey;

  RouteSuggestionService({required this.mapsApiKey});

  Future<RouteSuggestion> suggestRouteToDestination({
    required LatLng origin,
    required LatLng destination,
  }) async {
    try {
      final route = await _fetchDirectionsRoute(
        origin: origin,
        destination: destination,
      );

      return RouteSuggestion(
        distanceKm: route.distanceKm,
        estimatedMinutes: route.estimatedMinutes,
        points: route.polylinePoints,
        directionsRoute: route,
      );
    } on RouteSuggestionException {
      rethrow;
    } catch (e) {
      debugPrint('Error suggesting route to destination: $e');
      throw RouteSuggestionException(
        type: RouteSuggestionFailureType.unknown,
        userMessage: '変更先目的地へのルート提案に失敗しました。',
      );
    }
  }

  /// Google Maps Directions API を使用して周回ルートを提案
  /// [center]: 現在地
  /// [distanceKm]: 希望距離
  /// [recordedRoutes]: 既に歩いたルート（重複を避けるため）
  Future<RouteSuggestion> suggestLoopRoute({
    required LatLng center,
    required double distanceKm,
    List<List<LatLng>>? recordedRoutes,
  }) async {
    try {
      // 方位と半径を段階的に変えて候補を試し、提案成功率を上げる
      const bearingSteps = <double>[0, 60, 120, 180, 240, 300];
      const distanceScales = <double>[0.5, 0.42, 0.35];
      final random = Random();
      final baseBearing = random.nextDouble() * 360;
      DirectionsRoute? fallbackOutbound;

      for (final scale in distanceScales) {
        for (final step in bearingSteps) {
          final bearing = (baseBearing + step) % 360;
          final destination = _move(center, distanceKm * scale, bearing);

          final outboundRoute = await _tryFetchRoute(
            origin: center,
            destination: destination,
            useAlternatives: true,
            recordedRoutes: recordedRoutes,
          );
          if (outboundRoute == null) {
            continue;
          }
          fallbackOutbound ??= outboundRoute;

          final returnRoute = await _tryFetchRoute(
            origin: destination,
            destination: center,
            useAlternatives: false,
          );
          if (returnRoute == null) {
            continue;
          }

          final combinedPoints = <LatLng>[
            ...outboundRoute.polylinePoints,
            ...returnRoute.polylinePoints.skip(1),
          ];

          final totalDistanceKm =
              outboundRoute.distanceKm + returnRoute.distanceKm;
          final totalMinutes =
              outboundRoute.estimatedMinutes + returnRoute.estimatedMinutes;

          return RouteSuggestion(
            distanceKm: totalDistanceKm,
            estimatedMinutes: totalMinutes,
            points: combinedPoints,
            directionsRoute: outboundRoute,
          );
        }
      }

      if (fallbackOutbound != null) {
        return RouteSuggestion(
          distanceKm: fallbackOutbound.distanceKm,
          estimatedMinutes: fallbackOutbound.estimatedMinutes,
          points: fallbackOutbound.polylinePoints,
          directionsRoute: fallbackOutbound,
        );
      }

      throw RouteSuggestionException(
        type: RouteSuggestionFailureType.noRouteFound,
        userMessage: '徒歩ルートが見つかりませんでした。距離を短くして再試行してください。',
      );
    } on RouteSuggestionException {
      rethrow;
    } catch (e) {
      debugPrint('Error suggesting route: $e');
      throw RouteSuggestionException(
        type: RouteSuggestionFailureType.unknown,
        userMessage: 'ルート提案に失敗しました。時間をおいて再試行してください。',
      );
    }
  }

  Future<DirectionsRoute?> _tryFetchRoute({
    required LatLng origin,
    required LatLng destination,
    bool useAlternatives = false,
    List<List<LatLng>>? recordedRoutes,
  }) async {
    try {
      return await _fetchDirectionsRoute(
        origin: origin,
        destination: destination,
        useAlternatives: useAlternatives,
        recordedRoutes: recordedRoutes,
      );
    } on RouteSuggestionException catch (e) {
      final isRetryable = e.type == RouteSuggestionFailureType.noRouteFound ||
          e.type == RouteSuggestionFailureType.timeout ||
          e.type == RouteSuggestionFailureType.network;

      if (isRetryable) {
        return null;
      }
      rethrow;
    }
  }

  /// Google Maps Directions API からルート情報を取得
  Future<DirectionsRoute> _fetchDirectionsRoute({
    required LatLng origin,
    required LatLng destination,
    bool useAlternatives = false,
    List<List<LatLng>>? recordedRoutes,
  }) async {
    try {
      final alternativesParam = useAlternatives ? 'true' : 'false';
      final String url =
          'https://maps.googleapis.com/maps/api/directions/json'
          '?origin=${origin.latitude},${origin.longitude}'
          '&destination=${destination.latitude},${destination.longitude}'
          '&mode=walking'
          '&alternatives=$alternativesParam'
          '&key=$mapsApiKey';

      final response = await http.get(Uri.parse(url)).timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException('API request timeout'),
      );

      if (response.statusCode != 200) {
        throw RouteSuggestionException(
          type: RouteSuggestionFailureType.network,
          userMessage: '通信エラーが発生しました。ネットワークを確認してください。',
          rawStatus: 'HTTP_${response.statusCode}',
        );
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final status = json['status'] as String? ?? 'UNKNOWN_ERROR';
      final routes = json['routes'] as List? ?? const [];

      if (status == 'OK' && routes.isNotEmpty) {
        // alternatives=true の場合、複数ルート候補から最適なものを選ぶ
        if (useAlternatives && recordedRoutes != null && recordedRoutes.isNotEmpty) {
          return _selectBestRoute(json, recordedRoutes);
        } else {
          // alternatives=false または記録ルートなし：最初のルートを返す
          return DirectionsRoute.fromJson(json);
        }
      }

      switch (status) {
        case 'ZERO_RESULTS':
          throw RouteSuggestionException(
            type: RouteSuggestionFailureType.noRouteFound,
            userMessage: '候補ルートが見つかりませんでした。',
            rawStatus: status,
          );
        case 'OVER_QUERY_LIMIT':
          throw RouteSuggestionException(
            type: RouteSuggestionFailureType.quotaExceeded,
            userMessage: 'API利用上限に達しました。時間をおいて再試行してください。',
            rawStatus: status,
          );
        case 'REQUEST_DENIED':
          throw RouteSuggestionException(
            type: RouteSuggestionFailureType.apiKeyDenied,
            userMessage: 'APIキー設定を確認してください（REQUEST_DENIED）。',
            rawStatus: status,
          );
        case 'INVALID_REQUEST':
          throw RouteSuggestionException(
            type: RouteSuggestionFailureType.invalidRequest,
            userMessage: 'ルートリクエストが不正です。',
            rawStatus: status,
          );
        default:
          throw RouteSuggestionException(
            type: RouteSuggestionFailureType.unknown,
            userMessage: 'ルート提案に失敗しました。時間をおいて再試行してください。',
            rawStatus: status,
          );
      }
    } on TimeoutException {
      throw RouteSuggestionException(
        type: RouteSuggestionFailureType.timeout,
        userMessage: '通信がタイムアウトしました。時間をおいて再試行してください。',
      );
    } on SocketException {
      throw RouteSuggestionException(
        type: RouteSuggestionFailureType.network,
        userMessage: '通信エラーが発生しました。ネットワークを確認してください。',
      );
    } on RouteSuggestionException {
      rethrow;
    } catch (e) {
      debugPrint('Exception fetching directions: $e');
      throw RouteSuggestionException(
        type: RouteSuggestionFailureType.unknown,
        userMessage: 'ルート提案に失敗しました。時間をおいて再試行してください。',
      );
    }
  }

  /// 複数ルート候補の中から最適なものを選ぶ（最も重複度が低いもの）
  DirectionsRoute _selectBestRoute(
    Map<String, dynamic> json,
    List<List<LatLng>> recordedRoutes,
  ) {
    final routes = json['routes'] as List;
    if (routes.isEmpty) {
      throw RouteSuggestionException(
        type: RouteSuggestionFailureType.noRouteFound,
        userMessage: '候補ルートが見つかりませんでした。',
      );
    }

    late DirectionsRoute bestRoute;
    double minOverlap = double.infinity;

    for (final routeJson in routes) {
      final route = DirectionsRoute.fromJson({
        'routes': [routeJson],
        'status': 'OK',
      });

      double totalOverlap = 0;
      for (final recordedRoute in recordedRoutes) {
        final overlap = DirectionsRouteAlternatives.calculateRouteOverlap(
          route.polylinePoints,
          recordedRoute,
        );
        totalOverlap += overlap;
      }

      if (totalOverlap < minOverlap) {
        minOverlap = totalOverlap;
        bestRoute = route;
      }
    }

    return bestRoute;
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
