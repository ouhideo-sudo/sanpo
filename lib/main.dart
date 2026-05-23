import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models/active_route_draft.dart';
import 'models/walk_route.dart';
import 'services/area_coverage_service.dart';
import 'services/route_service.dart';
import 'services/route_suggestion_service.dart';
import 'config/api_keys.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(MyApp(prefs: prefs));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, required this.prefs});

  final SharedPreferences prefs;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sanpo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: SanpoHome(prefs: prefs),
    );
  }
}

class SanpoHome extends StatefulWidget {
  const SanpoHome({super.key, required this.prefs});

  final SharedPreferences prefs;

  @override
  State<SanpoHome> createState() => _SanpoHomeState();
}

class _SanpoHomeState extends State<SanpoHome> with WidgetsBindingObserver {
  static const double _destinationArrivalThresholdMeters = 35;
  static const double _municipalityConqueredThreshold = 0.9;
  static const Duration _draftSaveInterval = Duration(seconds: 10);

  GoogleMapController? _mapController;
  int _mapControllerGeneration = 0;
  late RouteService routeService;
  late AreaCoverageService areaCoverageService;
  int _currentIndex = 0;
  List<WalkRoute> _savedRoutes = [];
  // 全ルートから生成した囲みポリゴン（自治体制覇判定用）
  List<List<LatLng>> _enclosedPolygons = [];
  // フィルター適用後の表示用囲みポリゴン
  List<List<LatLng>> _displayEnclosedPolygons = [];
  // Nominatim 再呼び出し抑制用キャッシュ（-1 = 未取得）
  int _lastMunicipalityCheckRouteCount = -1;
  bool _showSuggestedWalkRoutes = true;
  bool _showRegularWalkRoutes = true;
  bool _showEnclosedAreas = true;
  bool _showSuggestionPanel = true;
  String? _conqueredMunicipalityName;
  double _municipalityCoverageRatio = 0;
  Polyline? _suggestedPolyline;
  RouteSuggestion? _latestSuggestion;
  LatLng? _suggestedDestination;
  Marker? _destinationMarker;
  double _selectedSuggestionDistanceKm = 2.0;
  bool _isSuggesting = false;
  bool _isDestinationSelectionMode = false;
  double? _targetDistanceKm;
  final List<LatLng> _currentRoute = [];
  bool _isRecording = false;
  DateTime? _recordingStartTime;
  StreamSubscription<Position>? _positionSubscription;
  DateTime? _lastDraftSavedAt;
  
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    routeService = RouteService(widget.prefs);
    areaCoverageService = AreaCoverageService();
    _requestLocationPermission();
    _loadSavedRoutes();
    _restoreActiveDraft();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _positionSubscription?.cancel();
    _mapController?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _persistActiveDraft(force: true);
    }
  }

  Future<void> _loadSavedRoutes() async {
    final routes = await routeService.getRoutes();
    final enclosedPolygons = areaCoverageService.extractEnclosedPolygons(routes);

    // Nominatim は routes 数が変わった時だけ叩く（レート制限・タブ切替の都度呼び出し防止）
    MunicipalityCoverageResult? coverage;
    final routeCountChanged = routes.length != _lastMunicipalityCheckRouteCount;
    if (enclosedPolygons.isNotEmpty && routeCountChanged) {
      final referencePoint = _resolveCoverageReference(enclosedPolygons);
      if (referencePoint != null) {
        try {
          coverage = await areaCoverageService.estimateMunicipalityCoverage(
            reference: referencePoint,
            coveredPolygons: enclosedPolygons,
          );
        } catch (_) {
          coverage = null;
        }
      }
    }

    setState(() {
      _savedRoutes = routes;
      _enclosedPolygons = enclosedPolygons;
      _displayEnclosedPolygons = _computeDisplayPolygons(routes, enclosedPolygons);
      if (routeCountChanged && enclosedPolygons.isNotEmpty) {
        _lastMunicipalityCheckRouteCount = routes.length;
        _municipalityCoverageRatio = coverage?.coverageRatio ?? _municipalityCoverageRatio;
        _conqueredMunicipalityName =
            (coverage != null &&
                coverage.coverageRatio >= _municipalityConqueredThreshold)
            ? coverage.municipalityName
            : (coverage == null ? _conqueredMunicipalityName : null);
      } else if (enclosedPolygons.isEmpty) {
        _lastMunicipalityCheckRouteCount = routes.length;
        _municipalityCoverageRatio = 0;
        _conqueredMunicipalityName = null;
      }
    });
  }

  // 全囲みポリゴンの重心を自治体判定の基準点とする。
  // 最後の記録点（特定ルートの末尾）ではなく、塗り領域全体の中心を参照する。
  LatLng? _resolveCoverageReference(List<List<LatLng>> enclosedPolygons) {
    final allPoints = enclosedPolygons.expand((p) => p).toList();
    if (allPoints.isEmpty) return null;
    final avgLat = allPoints.map((p) => p.latitude).reduce((a, b) => a + b) / allPoints.length;
    final avgLng = allPoints.map((p) => p.longitude).reduce((a, b) => a + b) / allPoints.length;
    return LatLng(avgLat, avgLng);
  }

  // 現在のフィルター設定に合わせた表示用囲みポリゴンを返す。
  List<List<LatLng>> _computeDisplayPolygons(
    List<WalkRoute> routes,
    List<List<LatLng>> allEnclosedPolygons,
  ) {
    // 両フィルターが ON の場合はキャッシュ済みを使う（再計算不要）
    if (_showSuggestedWalkRoutes && _showRegularWalkRoutes) {
      return allEnclosedPolygons;
    }
    final filteredRoutes = routes.where((r) {
      if (r.isSuggested && !_showSuggestedWalkRoutes) return false;
      if (!r.isSuggested && !_showRegularWalkRoutes) return false;
      return true;
    }).toList();
    return areaCoverageService.extractEnclosedPolygons(filteredRoutes);
  }

  Future<void> _requestLocationPermission() async {
    final servicesEnabled = await Geolocator.isLocationServiceEnabled();
    if (!servicesEnabled && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('位置情報サービスを有効にしてください')),
      );
    }

    final status = await Geolocator.requestPermission();
    if (status == LocationPermission.denied || status == LocationPermission.deniedForever) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('位置情報許可が必要です')),
        );
      }
    }
  }

  Future<void> _restoreActiveDraft() async {
    final draft = routeService.getActiveDraft();
    if (draft == null || draft.points.isEmpty) {
      return;
    }

    setState(() {
      _isRecording = true;
      _recordingStartTime = draft.startTime;
      _currentRoute
        ..clear()
        ..addAll(draft.points);
      _targetDistanceKm = draft.targetDistanceKm;
      _suggestedDestination = draft.suggestedDestination;
      _destinationMarker = draft.suggestedDestination == null
          ? null
          : Marker(
              markerId: const MarkerId('suggested-destination'),
              position: draft.suggestedDestination!,
              infoWindow: const InfoWindow(title: '目的地'),
            );
    });

    final trackingStarted = await _startPositionTracking();
    if (!trackingStarted) {
      if (mounted) {
        setState(() {
          _isRecording = false;
          _targetDistanceKm = null;
          _currentRoute.clear();
          _recordingStartTime = null;
          _suggestedDestination = null;
          _destinationMarker = null;
        });
      }
      // ドラフトは保持しておく（権限付与後に再起動すれば復元可能）
      return;
    }

    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('保存されていた散歩記録を復元しました'),
            duration: Duration(seconds: 3),
          ),
        );
      });
    }
  }

  Future<void> _persistActiveDraft({bool force = false}) async {
    if (!_isRecording || _recordingStartTime == null) {
      return;
    }
    if (_currentRoute.isEmpty && !force) {
      return;
    }

    final now = DateTime.now();
    if (!force &&
        _lastDraftSavedAt != null &&
        now.difference(_lastDraftSavedAt!) < _draftSaveInterval) {
      return;
    }

    _lastDraftSavedAt = now;
    await routeService.saveActiveDraft(
      ActiveRouteDraft(
        startTime: _recordingStartTime!,
        points: List<LatLng>.from(_currentRoute),
        isSuggested: _targetDistanceKm != null,
        targetDistanceKm: _targetDistanceKm,
        suggestedDestination: _suggestedDestination,
      ),
    );
  }

  LocationSettings _buildLocationSettings() {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
        intervalDuration: const Duration(seconds: 5),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Sanpo が散歩を記録中',
          notificationText: 'バックグラウンドでも位置情報を記録しています。',
          enableWakeLock: true,
        ),
      );
    }

    return const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 5,
    );
  }

  Future<bool> _startPositionTracking() async {
    final permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('位置情報の許可が必要です'),
            action: permission == LocationPermission.deniedForever
                ? SnackBarAction(
                    label: '設定を開く',
                    onPressed: () => Geolocator.openAppSettings(),
                  )
                : null,
          ),
        );
      }
      return false;
    }

    final servicesEnabled = await Geolocator.isLocationServiceEnabled();
    if (!servicesEnabled) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('位置情報サービスを有効にしてください')),
        );
      }
      return false;
    }

    await _positionSubscription?.cancel();
    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: _buildLocationSettings(),
    ).listen(
      _handlePositionUpdate,
      onError: (Object error) {
        _positionSubscription?.cancel();
        _positionSubscription = null;
        if (mounted) {
          setState(() {
            _isRecording = false;
            _targetDistanceKm = null;
            _isDestinationSelectionMode = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('位置追跡が中断されました。再度開始してください。'),
            ),
          );
        }
        routeService.clearActiveDraft();
      },
      cancelOnError: true,
    );
    return true;
  }

  Future<void> _handlePositionUpdate(Position position) async {
    if (!_isRecording) {
      return;
    }

    final latLng = LatLng(position.latitude, position.longitude);
    final isDuplicatePoint = _currentRoute.isNotEmpty &&
        Geolocator.distanceBetween(
              _currentRoute.last.latitude,
              _currentRoute.last.longitude,
              latLng.latitude,
              latLng.longitude,
            ) <
            3;
    if (isDuplicatePoint) {
      return;
    }

    if (mounted) {
      setState(() {
        _currentRoute.add(latLng);
      });
    } else {
      _currentRoute.add(latLng);
    }

    await _persistActiveDraft();

    final reachedDestination = _targetDistanceKm != null &&
        _suggestedDestination != null &&
        _isNearDestination(latLng);

    if (reachedDestination) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('目的地に到着しました。記録を自動保存します。'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      await _stopRouteRecording(isSuggestedCompleted: true);
    }
  }

  Future<void> _getCurrentLocation({required int mapGeneration}) async {
    try {
      final position = await Geolocator.getCurrentPosition();
      await _animateMapCameraSafely(
        CameraUpdate.newLatLngZoom(
          LatLng(position.latitude, position.longitude),
          15,
        ),
        mapGeneration: mapGeneration,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('位置情報取得エラー: $e')),
        );
      }
    }
  }

  Future<void> _animateMapCameraSafely(
    CameraUpdate cameraUpdate, {
    required int mapGeneration,
  }) async {
    final controller = _mapController;
    if (!mounted || _currentIndex != 0 || controller == null) {
      return;
    }
    if (mapGeneration != _mapControllerGeneration) {
      return;
    }

    try {
      await controller.animateCamera(cameraUpdate);
    } on StateError {
      // タブ切替などでマップが破棄された直後は無視する。
    }
  }

  Future<void> _startRouteRecording({double? targetDistanceKm}) async {
    setState(() {
      _isRecording = true;
      _targetDistanceKm = targetDistanceKm;
      _currentRoute.clear();
      _recordingStartTime = DateTime.now();
    });
    _lastDraftSavedAt = null;
    await _persistActiveDraft(force: true);
    final success = await _startPositionTracking();
    if (!success && mounted) {
      setState(() {
        _isRecording = false;
        _targetDistanceKm = null;
      });
      await routeService.clearActiveDraft();
    }
  }

  void _startRegularWalk() {
    setState(() {
      _suggestedDestination = null;
      _destinationMarker = null;
      _isDestinationSelectionMode = false;
    });
    _startRouteRecording();
  }

  void _startSuggestedWalk() {
    if (_latestSuggestion == null || _suggestedDestination == null || _isRecording) {
      return;
    }

    _startRouteRecording(targetDistanceKm: _latestSuggestion!.distanceKm);
    setState(() {
      _isDestinationSelectionMode = false;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '提案ルートで開始: ${_latestSuggestion!.distanceKm.toStringAsFixed(1)}km（目的地まで自動記録）',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _stopRouteRecording({bool isSuggestedCompleted = false}) async {
    final wasSuggestedRoute = _targetDistanceKm != null;

    await _positionSubscription?.cancel();
    _positionSubscription = null;

    setState(() {
      _isRecording = false;
      _targetDistanceKm = null;
      _isDestinationSelectionMode = false;
    });

    if (_currentRoute.isNotEmpty && _recordingStartTime != null) {
      final now = DateTime.now();
      final distanceKm = RouteService.calculateTotalDistance(_currentRoute);
      final durationMinutes = now.difference(_recordingStartTime!).inMinutes;

      final route = WalkRoute(
        id: DateTime.now().toString(),
        startTime: _recordingStartTime!,
        endTime: now,
        points: List.from(_currentRoute),
        distanceKm: distanceKm,
        durationMinutes: durationMinutes,
        isSuggested: wasSuggestedRoute,
        isSuggestedCompleted: wasSuggestedRoute && isSuggestedCompleted,
      );

      await routeService.saveRoute(route);
      await routeService.clearActiveDraft();

      await _loadSavedRoutes();

      setState(() {
        _currentRoute.clear();
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '✓ ルート保存完了: ${distanceKm.toStringAsFixed(2)}km / $durationMinutes分',
            ),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } else {
      await routeService.clearActiveDraft();
    }
  }

  Set<Polyline> _buildSavedRoutePolylines() {
    final polylines = <Polyline>{};
    for (final route in _savedRoutes) {
      if (route.isSuggested && !_showSuggestedWalkRoutes) {
        continue;
      }
      if (!route.isSuggested && !_showRegularWalkRoutes) {
        continue;
      }

      final color = route.isSuggested
          ? (route.isSuggestedCompleted ? Colors.teal : Colors.deepOrange)
          : Colors.blue;

      polylines.add(
        Polyline(
          polylineId: PolylineId(route.id),
          points: route.points,
          color: color,
          width: 3,
        ),
      );
    }
    return polylines;
  }

  Set<Polygon> _buildSavedRoutePolygons() {
    final polygons = <Polygon>{};
    for (var i = 0; i < _displayEnclosedPolygons.length; i++) {
      polygons.add(
        Polygon(
          polygonId: PolygonId('area-$i'),
          points: _displayEnclosedPolygons[i],
          strokeColor: Colors.redAccent.withAlpha(110),
          strokeWidth: 1,
          fillColor: Colors.redAccent.withAlpha(45),
        ),
      );
    }
    return polygons;
  }

  void _toggleSuggestedFilter(bool value) {
    setState(() {
      _showSuggestedWalkRoutes = value;
      _displayEnclosedPolygons = _computeDisplayPolygons(_savedRoutes, _enclosedPolygons);
    });
  }

  void _toggleRegularFilter(bool value) {
    setState(() {
      _showRegularWalkRoutes = value;
      _displayEnclosedPolygons = _computeDisplayPolygons(_savedRoutes, _enclosedPolygons);
    });
  }

  void _toggleEnclosedAreaFilter(bool value) {
    setState(() {
      _showEnclosedAreas = value;
    });
  }

  Future<void> _suggestRoute() async {
    final mapGeneration = _mapControllerGeneration;
    setState(() {
      _isSuggesting = true;
    });

    try {
      final mapsApiKey = await ApiKeys.getMapsApiKey();
      if (mapsApiKey.isEmpty) {
        throw Exception('MAPS_API_KEY が未設定です。実ルート提案を利用するには API キーを設定してください。');
      }

      final position = await Geolocator.getCurrentPosition();
      final current = LatLng(position.latitude, position.longitude);
      
      // 既に歩いたルートを取得（重複を避けるため）
      final recordedRoutes = <List<LatLng>>[];
      final routes = await routeService.getRoutes();
      for (final route in routes) {
        recordedRoutes.add(route.points);
      }
      
      final service = RouteSuggestionService(mapsApiKey: mapsApiKey);
      final suggestion = await service.suggestLoopRoute(
        center: current,
        distanceKm: _selectedSuggestionDistanceKm,
        recordedRoutes: recordedRoutes.isNotEmpty ? recordedRoutes : null,
      );
      final destination = _selectDestinationPoint(
        points: suggestion.points,
        origin: current,
      );

      final polyline = Polyline(
        polylineId: const PolylineId('suggested-route'),
        points: suggestion.points,
        color: Colors.pink,
        width: 4,
        patterns: <PatternItem>[
          PatternItem.dash(20),
          PatternItem.gap(12),
        ],
      );

      if (mounted) {
        setState(() {
          _latestSuggestion = suggestion;
          _suggestedPolyline = polyline;
          _suggestedDestination = destination;
          _destinationMarker = Marker(
            markerId: const MarkerId('suggested-destination'),
            position: destination,
            infoWindow: const InfoWindow(title: '目的地'),
          );
        });

        final bounds = _computeBounds(suggestion.points);
        await _animateMapCameraSafely(
          CameraUpdate.newLatLngBounds(bounds, 64),
          mapGeneration: mapGeneration,
        );
      }
    } catch (e) {
      final message = e is RouteSuggestionException
          ? e.userMessage
          : 'ルート提案の作成に失敗しました。時間をおいて再試行してください。';
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSuggesting = false;
        });
      }
    }
  }

  LatLngBounds _computeBounds(List<LatLng> points) {
    var minLat = points.first.latitude;
    var maxLat = points.first.latitude;
    var minLng = points.first.longitude;
    var maxLng = points.first.longitude;

    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }

    return LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );
  }

  LatLng _selectDestinationPoint({
    required List<LatLng> points,
    required LatLng origin,
  }) {
    if (points.isEmpty) {
      return origin;
    }

    LatLng selected = points.first;
    double farthestMeters = -1;
    for (final point in points) {
      final meters = Geolocator.distanceBetween(
        origin.latitude,
        origin.longitude,
        point.latitude,
        point.longitude,
      );
      if (meters > farthestMeters) {
        farthestMeters = meters;
        selected = point;
      }
    }
    return selected;
  }

  bool _isNearDestination(LatLng currentPoint) {
    if (_suggestedDestination == null) {
      return false;
    }

    final meters = Geolocator.distanceBetween(
      _suggestedDestination!.latitude,
      _suggestedDestination!.longitude,
      currentPoint.latitude,
      currentPoint.longitude,
    );
    return meters <= _destinationArrivalThresholdMeters;
  }

  void _toggleDestinationSelectionMode() {
    if (!_isRecording || _targetDistanceKm == null) {
      return;
    }

    setState(() {
      _isDestinationSelectionMode = !_isDestinationSelectionMode;
    });

    if (_isDestinationSelectionMode && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('地図をタップして新しい目的地を設定してください。'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _updateDestination(LatLng destination) async {
    setState(() {
      _suggestedDestination = destination;
      _destinationMarker = Marker(
        markerId: const MarkerId('suggested-destination'),
        position: destination,
        infoWindow: const InfoWindow(title: '目的地'),
      );
      _isDestinationSelectionMode = false;
    });

    try {
      final mapsApiKey = await ApiKeys.getMapsApiKey();
      if (mapsApiKey.isEmpty) {
        throw RouteSuggestionException(
          type: RouteSuggestionFailureType.apiKeyDenied,
          userMessage: 'MAPS_API_KEY が未設定です。',
        );
      }

      final position = await Geolocator.getCurrentPosition();
      final origin = LatLng(position.latitude, position.longitude);
      final service = RouteSuggestionService(mapsApiKey: mapsApiKey);
      final suggestion = await service.suggestRouteToDestination(
        origin: origin,
        destination: destination,
      );

      final polyline = Polyline(
        polylineId: const PolylineId('suggested-route'),
        points: suggestion.points,
        color: Colors.pink,
        width: 4,
        patterns: <PatternItem>[
          PatternItem.dash(20),
          PatternItem.gap(12),
        ],
      );

      if (mounted) {
        setState(() {
          _latestSuggestion = suggestion;
          _suggestedPolyline = polyline;
          if (_targetDistanceKm != null) {
            _targetDistanceKm = suggestion.distanceKm;
          }
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '目的地を更新しました。新ルート: ${suggestion.distanceKm.toStringAsFixed(1)}km',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      final message = e is RouteSuggestionException
          ? e.userMessage
          : '目的地更新後のルート提案に失敗しました。';
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      _buildMapPage(),
      RoutesHistoryPage(
        prefs: widget.prefs,
        onRouteDeleted: _loadSavedRoutes,
        conqueredMunicipalityName: _conqueredMunicipalityName,
        municipalityCoverageRatio: _municipalityCoverageRatio,
      ),
      SettingsPage(prefs: widget.prefs),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sanpo - 散歩ルート記録'),
        elevation: 0,
      ),
      body: pages[_currentIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          setState(() {
            if (index != 0) {
              _mapControllerGeneration++;
              _mapController = null;
            }
            _currentIndex = index;
          });
          // マップタブに戻るときは保存ルートをリロード
          if (index == 0) {
            _loadSavedRoutes();
          }
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map),
            label: 'マップ',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history),
            label: '記録',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '設定',
          ),
        ],
      ),
    );
  }

  Widget _buildMapPage() {
    final isSuggestionSupportedPlatform =
      ApiKeys.isRouteSuggestionSupportedPlatform;
    final canSuggest =
      isSuggestionSupportedPlatform && !_isSuggesting && !_isRecording;
    final liveDistanceKm = _currentRoute.length > 1
        ? RouteService.calculateTotalDistance(_currentRoute)
        : 0.0;
    final progressText = _targetDistanceKm != null
        ? '${liveDistanceKm.toStringAsFixed(2)} / ${_targetDistanceKm!.toStringAsFixed(1)} km'
        : '${liveDistanceKm.toStringAsFixed(2)} km';

    final displayedPolylines = _buildSavedRoutePolylines();
    final displayedPolygons = _showEnclosedAreas
      ? _buildSavedRoutePolygons()
      : <Polygon>{};
    final displayedMarkers = <Marker>{};
    if (_destinationMarker != null) {
      displayedMarkers.add(_destinationMarker!);
    }
    if (_suggestedPolyline != null) {
      displayedPolylines.add(_suggestedPolyline!);
    }

    return Stack(
      children: [
        GoogleMap(
          onMapCreated: (controller) {
            _mapController = controller;
            _mapControllerGeneration++;
            final generation = _mapControllerGeneration;
            _getCurrentLocation(mapGeneration: generation);
          },
          onTap: (point) {
            if (_isRecording && _targetDistanceKm != null && _isDestinationSelectionMode) {
              _updateDestination(point);
            }
          },
          initialCameraPosition: const CameraPosition(
            target: LatLng(35.6762, 139.6503), // 東京
            zoom: 15,
          ),
          polylines: displayedPolylines,
          polygons: displayedPolygons,
          markers: displayedMarkers,
          myLocationEnabled: true,
          myLocationButtonEnabled: true,
          zoomControlsEnabled: true,
        ),
        if (_showSuggestionPanel)
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: Card(
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'おすすめ散歩ルート',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        IconButton(
                          onPressed: () {
                            setState(() {
                              _showSuggestionPanel = false;
                            });
                          },
                          icon: const Icon(Icons.close),
                          tooltip: 'パネルを閉じる',
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final distance in [1.0, 2.0, 3.0, 5.0])
                          ChoiceChip(
                            label: Text('${distance.toStringAsFixed(0)}km'),
                            selected: _selectedSuggestionDistanceKm == distance,
                            onSelected: (_) {
                              setState(() {
                                _selectedSuggestionDistanceKm = distance;
                              });
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilterChip(
                          label: const Text('提案散歩を表示'),
                          selected: _showSuggestedWalkRoutes,
                          onSelected: _toggleSuggestedFilter,
                        ),
                        FilterChip(
                          label: const Text('通常散歩を表示'),
                          selected: _showRegularWalkRoutes,
                          onSelected: _toggleRegularFilter,
                        ),
                        FilterChip(
                          label: const Text('囲みエリアを表示'),
                          selected: _showEnclosedAreas,
                          onSelected: _toggleEnclosedAreaFilter,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: canSuggest ? _suggestRoute : null,
                      icon: _isSuggesting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.route),
                      label: Text(
                        _isSuggesting
                            ? '提案中...'
                            : isSuggestionSupportedPlatform
                                ? 'この距離で提案'
                                : 'Android端末で利用可',
                      ),
                    ),
                    if (!isSuggestionSupportedPlatform)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          '道路ベースの提案はAndroidアプリで利用できます。',
                          style: TextStyle(color: Colors.black54),
                        ),
                      ),
                    if (_latestSuggestion != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '提案: ${_latestSuggestion!.distanceKm.toStringAsFixed(1)}km '
                              '(目安 ${_latestSuggestion!.estimatedMinutes}分)',
                            ),
                            if (_suggestedDestination != null)
                              const Padding(
                                padding: EdgeInsets.only(top: 4),
                                child: Text('目的地は自動設定されます。到達時に自動保存します。'),
                              ),
                            const SizedBox(height: 8),
                            OutlinedButton.icon(
                              onPressed: _isRecording ? null : _startSuggestedWalk,
                              icon: const Icon(Icons.play_circle_outline),
                              label: const Text('この提案で開始'),
                            ),
                          ],
                        ),
                      ),
                    if (_isRecording)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '記録中: $progressText',
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            if (_targetDistanceKm != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: OutlinedButton.icon(
                                  onPressed: _toggleDestinationSelectionMode,
                                  icon: Icon(
                                    _isDestinationSelectionMode
                                        ? Icons.close
                                        : Icons.edit_location_alt,
                                  ),
                                  label: Text(
                                    _isDestinationSelectionMode
                                        ? '目的地変更をキャンセル'
                                        : '目的地を変更',
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          )
        else
          Positioned(
            top: 12,
            left: 12,
            child: FilledButton.icon(
              onPressed: () {
                setState(() {
                  _showSuggestionPanel = true;
                });
              },
              icon: const Icon(Icons.route),
              label: const Text('おすすめを表示'),
            ),
          ),
        Positioned(
          bottom: 20,
          left: 20,
          right: 20,
          child: Center(
            child: FloatingActionButton.extended(
              onPressed: _isRecording
                  ? _stopRouteRecording
                  : _startRegularWalk,
              label: Text(_isRecording ? '停止' : '開始'),
              icon: Icon(_isRecording ? Icons.stop : Icons.play_arrow),
              backgroundColor: _isRecording ? Colors.red : Colors.green,
            ),
          ),
        ),
      ],
    );
  }
}

class RoutesHistoryPage extends StatefulWidget {
  const RoutesHistoryPage({
    super.key,
    required this.prefs,
    required this.onRouteDeleted,
    required this.conqueredMunicipalityName,
    required this.municipalityCoverageRatio,
  });

  final SharedPreferences prefs;
  final VoidCallback onRouteDeleted;
  final String? conqueredMunicipalityName;
  final double municipalityCoverageRatio;

  @override
  State<RoutesHistoryPage> createState() => _RoutesHistoryPageState();
}

class _RoutesHistoryPageState extends State<RoutesHistoryPage> {
  late RouteService routeService;

  @override
  void initState() {
    super.initState();
    routeService = RouteService(widget.prefs);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // リロードボタン
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              FilledButton.icon(
                onPressed: () {
                  widget.onRouteDeleted();
                },
                icon: const Icon(Icons.refresh),
                label: const Text('リロード'),
              ),
            ],
          ),
        ),
        if (widget.conqueredMunicipalityName != null)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.amber.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.amber.shade300),
            ),
            child: Row(
              children: [
                Icon(Icons.emoji_events, color: Colors.amber.shade800),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${widget.conqueredMunicipalityName} 制覇',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                Text(
                  '${(widget.municipalityCoverageRatio * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        Expanded(
          child: FutureBuilder<List<WalkRoute>>(
            future: routeService.getRoutes(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              final routes = snapshot.data ?? [];
              if (routes.isEmpty) {
                return const Center(
                  child: Text('記録されたルートがありません'),
                );
              }

              return ListView.builder(
                itemCount: routes.length,
                itemBuilder: (context, index) {
                  final route = routes[index];
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: route.isSuggested
                          ? (route.isSuggestedCompleted ? Colors.teal : Colors.deepOrange)
                          : Colors.blue,
                      child: Text(
                        '${route.distanceKm.toStringAsFixed(1)}km',
                        style: const TextStyle(fontSize: 10, color: Colors.white),
                      ),
                    ),
                    title: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${route.startTime.month}/${route.startTime.day} ${route.startTime.hour}:${route.startTime.minute.toString().padLeft(2, '0')}',
                          ),
                        ),
                        if (route.isSuggested)
                          Chip(
                            label: Text(route.isSuggestedCompleted ? '提案完了' : '提案ルート'),
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                    subtitle: Text(
                      '${route.durationMinutes}分 | 平均速度: ${route.speedKmh.toStringAsFixed(1)}km/h',
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete, color: Colors.red),
                      onPressed: () async {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (BuildContext context) {
                            return AlertDialog(
                              title: const Text('ルートを削除'),
                              content: const Text('本当に削除しますか？'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(context).pop(false),
                                  child: const Text('キャンセル'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.of(context).pop(true),
                                  child: const Text('削除'),
                                ),
                              ],
                            );
                          },
                        );
                        if (confirmed == true) {
                          await routeService.deleteRoute(route.id);
                          widget.onRouteDeleted();
                          setState(() {});
                        }
                      },
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.prefs});

  final SharedPreferences prefs;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String _appVersionLabel = '取得中...';

  @override
  void initState() {
    super.initState();
    _loadAppVersion();
  }

  Future<void> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final label = '${info.version}+${info.buildNumber}';
      if (!mounted) {
        return;
      }
      setState(() {
        _appVersionLabel = label;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _appVersionLabel = '取得失敗';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '設定',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 24),
          ListTile(
            title: const Text('位置情報精度'),
            subtitle: const Text('高精度（消費電力多）'),
            leading: const Icon(Icons.location_on),
          ),
          const Divider(),
          ListTile(
            title: const Text('バージョン'),
            subtitle: Text(_appVersionLabel),
            leading: const Icon(Icons.info),
          ),
        ],
      ),
    );
  }
}
