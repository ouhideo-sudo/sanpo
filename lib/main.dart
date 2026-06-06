import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models/active_route_draft.dart';
import 'models/dungeon_challenge_result.dart';
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

enum PlayMode {
  recommendation,
  territory,
  dungeon,
}

class ModeDefinition {
  const ModeDefinition({
    required this.mode,
    required this.label,
    required this.description,
    required this.icon,
  });

  final PlayMode mode;
  final String label;
  final String description;
  final IconData icon;
}

class SanpoHome extends StatefulWidget {
  const SanpoHome({super.key, required this.prefs});

  final SharedPreferences prefs;

  @override
  State<SanpoHome> createState() => _SanpoHomeState();
}

class _SanpoHomeState extends State<SanpoHome> with WidgetsBindingObserver {
  static const double _destinationArrivalThresholdMeters = 35;
  static const Duration _draftSaveInterval = Duration(seconds: 10);
  static const Duration _dungeonTimeLimit = Duration(minutes: 30);
  static const Duration _dungeonRadarDuration = Duration(minutes: 10);
  static const double _dungeonSearchRadiusMeters = 500;
  static const double _dungeonRevealDistanceMeters = 100;
  static const double _dungeonContactDistanceMeters = 20;
  static const double _dungeonMinZoomLevel = 14.5;
  static const IconData _dungeonIcon = Icons.castle;

  static const List<ModeDefinition> _modeDefinitions = [
    ModeDefinition(
      mode: PlayMode.recommendation,
      label: 'おすすめ散歩ルート',
      description: '提案ルートで散歩を楽しむモード',
      icon: Icons.route,
    ),
    ModeDefinition(
      mode: PlayMode.territory,
      label: '陣取り',
      description: '囲みエリアと自治体踏破を楽しむモード',
      icon: Icons.crop_square,
    ),
    ModeDefinition(
      mode: PlayMode.dungeon,
      label: 'ダンジョン',
      description: '制限時間内にダンジョン到達を目指すモード',
      icon: _dungeonIcon,
    ),
  ];

  GoogleMapController? _mapController;
  int _mapControllerGeneration = 0;
  late RouteService routeService;
  late AreaCoverageService areaCoverageService;
  final Random _random = Random();
  int _currentIndex = 0;
  PlayMode _selectedMode = PlayMode.recommendation;
  List<WalkRoute> _savedRoutes = [];
  // フィルター適用後の表示用囲みポリゴン
  List<List<LatLng>> _displayEnclosedPolygons = [];
  // Nominatim 再呼び出し抑制用キャッシュ（-1 = 未取得）
  int _lastMunicipalityCheckRouteCount = -1;
  bool _showSuggestionPanel = true;
  AdministrativeCoverageResult? _prefectureCoverage;
  AdministrativeCoverageResult? _cityCoverage;
  AdministrativeCoverageResult? _townCoverage;
  String? _territoryCoverageError;
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
  bool _isDungeonActive = false;
  LatLng? _dungeonCenter;
  LatLng? _dungeonTarget;
  DateTime? _dungeonStartedAt;
  DateTime? _dungeonEndsAt;
  Timer? _dungeonTimer;
  Duration _dungeonRemaining = _dungeonTimeLimit;
  Duration _radarRemaining = _dungeonRadarDuration;
  DateTime? _radarLastUpdatedAt;
  bool _isRadarActive = false;
  bool _showModePanel = true;
  bool _showDungeonPanel = true;
  bool _showDungeonResult = false;
  String _dungeonResultMessage = '';
  LatLng? _latestPosition;
  Offset? _radarButtonOffset;
  double? _radarArrowAngle;
  bool _isRefreshingRadarControl = false;
  bool _isDungeonDefeatDialogOpen = false;
  bool _hasDeclinedDefeatInRange = false;
  
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
    _dungeonTimer?.cancel();
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
    TerritoryCoverageResult? territoryCoverage;
    String? territoryCoverageError;
    final routeCountChanged = routes.length != _lastMunicipalityCheckRouteCount;
    if (enclosedPolygons.isNotEmpty && routeCountChanged) {
      final referencePoint = _latestPosition;
      if (referencePoint != null) {
        try {
          territoryCoverage = await areaCoverageService.estimateTerritoryCoverage(
            reference: referencePoint,
            coveredPolygons: enclosedPolygons,
          );
        } on TerritoryCoverageException catch (e) {
          territoryCoverageError = e.message;
        } catch (_) {
          territoryCoverageError = '踏破率の取得に失敗しました。';
        }
      } else {
        territoryCoverageError = '現在地を取得できないため踏破率を計算できません。';
      }
    }

    setState(() {
      _savedRoutes = routes;
      _displayEnclosedPolygons = enclosedPolygons;
      if (routeCountChanged && enclosedPolygons.isNotEmpty) {
        _lastMunicipalityCheckRouteCount = routes.length;
        _territoryCoverageError = territoryCoverageError;
        if (territoryCoverage != null) {
          _prefectureCoverage = territoryCoverage.prefecture;
          _cityCoverage = territoryCoverage.city;
          _townCoverage = territoryCoverage.town;
        } else {
          _prefectureCoverage = null;
          _cityCoverage = null;
          _townCoverage = null;
        }
      } else if (enclosedPolygons.isEmpty) {
        _lastMunicipalityCheckRouteCount = routes.length;
        _prefectureCoverage = null;
        _cityCoverage = null;
        _townCoverage = null;
        _territoryCoverageError = null;
      }
    });
  }

  String _formatCoveragePercent(double ratio) {
    final value = ((ratio * 100).clamp(0, 100)).toDouble();
    return value.toStringAsFixed(2).padLeft(5, '0');
  }

  Widget _buildCoverageRow(String areaName, double ratio) {
    return Text('$areaName ${_formatCoveragePercent(ratio)}%');
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
        if (_isDungeonActive) {
          unawaited(_finishDungeon(success: false, message: 'ダンジョン討伐失敗'));
        }
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
    final latLng = LatLng(position.latitude, position.longitude);
    _latestPosition = latLng;
    unawaited(_refreshRadarButtonOffset());
    await _updateDungeonByPosition(latLng);
    if (!_isRecording) {
      return;
    }

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
      _latestPosition = LatLng(position.latitude, position.longitude);
      unawaited(_refreshRadarButtonOffset());
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

  void _switchMode(PlayMode mode) {
    setState(() {
      _selectedMode = mode;
      if (mode != PlayMode.recommendation) {
        _showSuggestionPanel = false;
      }
      if (mode == PlayMode.dungeon) {
        _showDungeonPanel = true;
      }
    });
    unawaited(_refreshRadarButtonOffset());
  }

  Future<void> _startDungeon() async {
    if (_isDungeonActive) {
      return;
    }

    final permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ダンジョン開始には位置情報許可が必要です。')),
        );
      }
      return;
    }

    try {
      final position = await Geolocator.getCurrentPosition();
      final center = LatLng(position.latitude, position.longitude);
      final target = await _pickDungeonTarget(center);
      if (target == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('ダンジョン設置に失敗しました。再試行してください。')),
          );
        }
        return;
      }

      final now = DateTime.now();
      final mapGeneration = _mapControllerGeneration;
      setState(() {
        _isDungeonActive = true;
        _dungeonCenter = center;
        _dungeonTarget = target;
        _dungeonStartedAt = now;
        _dungeonEndsAt = now.add(_dungeonTimeLimit);
        _dungeonRemaining = _dungeonTimeLimit;
        _radarRemaining = _dungeonRadarDuration;
        _radarLastUpdatedAt = null;
        _isRadarActive = false;
        _showDungeonPanel = true;
        _showDungeonResult = false;
        _dungeonResultMessage = '';
        _latestPosition = center;
        _isDungeonDefeatDialogOpen = false;
        _hasDeclinedDefeatInRange = false;
      });

      _dungeonTimer?.cancel();
      _dungeonTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        _tickDungeonTimer();
      });

      await _startPositionTracking();

      await _animateMapCameraSafely(
        CameraUpdate.newLatLngZoom(center, 16),
        mapGeneration: mapGeneration,
      );
      await _refreshRadarButtonOffset();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ダンジョン開始に失敗しました。')),
        );
      }
    }
  }

  Future<LatLng?> _pickDungeonTarget(LatLng center) async {
    final mapsApiKey = await ApiKeys.getMapsApiKey();
    if (mapsApiKey.isEmpty) {
      return null;
    }

    final service = RouteSuggestionService(mapsApiKey: mapsApiKey);
    try {
      final suggestion = await service.suggestLoopRoute(
        center: center,
        distanceKm: 2.0,
      );
      final inRange = suggestion.points.where((point) {
        final meters = Geolocator.distanceBetween(
          center.latitude,
          center.longitude,
          point.latitude,
          point.longitude,
        );
        return meters <= _dungeonSearchRadiusMeters && meters >= 100;
      }).toList();

      if (inRange.isEmpty) {
        return null;
      }

      return inRange[_random.nextInt(inRange.length)];
    } catch (_) {
      return null;
    }
  }

  void _tickDungeonTimer() {
    if (!_isDungeonActive || _dungeonEndsAt == null) {
      return;
    }

    final now = DateTime.now();
    final remaining = _dungeonEndsAt!.difference(now);
    if (remaining <= Duration.zero) {
      _finishDungeon(success: false, message: 'ダンジョン討伐失敗');
      return;
    }

    var isRadarActive = _isRadarActive;
    var radarRemaining = _radarRemaining;
    var radarLastUpdatedAt = _radarLastUpdatedAt;
    if (isRadarActive) {
      final last = radarLastUpdatedAt ?? now;
      final elapsed = now.difference(last);
      if (elapsed > Duration.zero) {
        radarRemaining -= elapsed;
      }
      if (radarRemaining <= Duration.zero) {
        radarRemaining = Duration.zero;
        isRadarActive = false;
        radarLastUpdatedAt = null;
      } else {
        radarLastUpdatedAt = now;
      }
    } else {
      radarLastUpdatedAt = null;
      if (radarRemaining < Duration.zero) {
        radarRemaining = Duration.zero;
      }
    }

    if (mounted) {
      setState(() {
        _dungeonRemaining = remaining;
        _isRadarActive = isRadarActive;
        _radarRemaining = radarRemaining;
        _radarLastUpdatedAt = radarLastUpdatedAt;
      });
    }
  }

  void _activateRadar() {
    if (!_isDungeonActive || _dungeonEndsAt == null || _radarRemaining <= Duration.zero) {
      return;
    }

    if (_isRadarActive) {
      return;
    }

    setState(() {
      _isRadarActive = true;
      _radarLastUpdatedAt = DateTime.now();
    });
  }

  void _deactivateRadar() {
    if (!_isRadarActive) {
      return;
    }

    setState(() {
      _isRadarActive = false;
      _radarLastUpdatedAt = null;
    });
  }

  Future<void> _updateDungeonByPosition(LatLng currentPosition) async {
    if (!_isDungeonActive || _dungeonTarget == null) {
      return;
    }

    final meters = Geolocator.distanceBetween(
      currentPosition.latitude,
      currentPosition.longitude,
      _dungeonTarget!.latitude,
      _dungeonTarget!.longitude,
    );

    if (meters > _dungeonRevealDistanceMeters) {
      _hasDeclinedDefeatInRange = false;
      return;
    }

    if (meters > _dungeonContactDistanceMeters) {
      return;
    }

    if (_isDungeonDefeatDialogOpen || _hasDeclinedDefeatInRange || !mounted) {
      return;
    }

    _isDungeonDefeatDialogOpen = true;
    final shouldDefeat = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) {
            return AlertDialog(
              title: const Text('ダンジョン'),
              content: const Text('討伐しますか？'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('NO'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('YES'),
                ),
              ],
            );
          },
        ) ??
        false;
    _isDungeonDefeatDialogOpen = false;

    if (!_isDungeonActive) {
      return;
    }

    if (shouldDefeat) {
      await _finishDungeon(success: true, message: 'ダンジョン討伐');
    } else {
      _hasDeclinedDefeatInRange = true;
    }
  }

  Future<void> _finishDungeon({
    required bool success,
    required String message,
  }) async {
    if (!_isDungeonActive || _dungeonStartedAt == null) {
      return;
    }

    final now = DateTime.now();
    final elapsed = now.difference(_dungeonStartedAt!).inSeconds;

    _dungeonTimer?.cancel();
    await routeService.saveDungeonResult(
      DungeonChallengeResult(
        id: now.microsecondsSinceEpoch.toString(),
        startTime: _dungeonStartedAt!,
        endTime: now,
        success: success,
        elapsedSeconds: elapsed,
      ),
    );

    if (mounted) {
      setState(() {
        _isDungeonActive = false;
        _dungeonCenter = null;
        _dungeonTarget = null;
        _dungeonStartedAt = null;
        _dungeonEndsAt = null;
        _dungeonRemaining = _dungeonTimeLimit;
        _radarRemaining = _dungeonRadarDuration;
        _radarLastUpdatedAt = null;
        _isRadarActive = false;
        _showDungeonResult = true;
        _dungeonResultMessage = message;
        _radarButtonOffset = null;
        _radarArrowAngle = null;
        _isDungeonDefeatDialogOpen = false;
        _hasDeclinedDefeatInRange = false;
      });
    }

    await _stopPositionTrackingIfIdle();
  }

  Future<void> _cancelDungeon() async {
    if (!_isDungeonActive) {
      return;
    }

    _dungeonTimer?.cancel();
    if (mounted) {
      setState(() {
        _isDungeonActive = false;
        _dungeonCenter = null;
        _dungeonTarget = null;
        _dungeonStartedAt = null;
        _dungeonEndsAt = null;
        _dungeonRemaining = _dungeonTimeLimit;
        _radarRemaining = _dungeonRadarDuration;
        _radarLastUpdatedAt = null;
        _isRadarActive = false;
        _showDungeonResult = false;
        _dungeonResultMessage = '';
        _radarButtonOffset = null;
        _radarArrowAngle = null;
        _isDungeonDefeatDialogOpen = false;
        _hasDeclinedDefeatInRange = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ダンジョン挑戦をキャンセルしました。')),
      );
    }

    await _stopPositionTrackingIfIdle();
  }

  String _formatRemaining(Duration remaining) {
    final minutes = remaining.inMinutes;
    final seconds = remaining.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  LatLng _offsetLatLng(
    LatLng origin,
    double distanceMeters,
    double bearingDegrees,
  ) {
    const earthRadiusMeters = 6378137.0;
    final angularDistance = distanceMeters / earthRadiusMeters;
    final bearingRadians = bearingDegrees * pi / 180;
    final latitudeRadians = origin.latitude * pi / 180;
    final longitudeRadians = origin.longitude * pi / 180;

    final shiftedLatitude = asin(
      sin(latitudeRadians) * cos(angularDistance) +
          cos(latitudeRadians) * sin(angularDistance) * cos(bearingRadians),
    );
    final shiftedLongitude = longitudeRadians +
        atan2(
          sin(bearingRadians) * sin(angularDistance) * cos(latitudeRadians),
          cos(angularDistance) - sin(latitudeRadians) * sin(shiftedLatitude),
        );

    return LatLng(
      shiftedLatitude * 180 / pi,
      shiftedLongitude * 180 / pi,
    );
  }

  Future<void> _refreshRadarButtonOffset() async {
    if (!mounted || _isRefreshingRadarControl) {
      return;
    }
    _isRefreshingRadarControl = true;

    final controller = _mapController;
    final latestPosition = _latestPosition;
    if (_selectedMode != PlayMode.dungeon ||
        !_isDungeonActive ||
        controller == null ||
        latestPosition == null) {
      if (_radarButtonOffset != null) {
        setState(() {
          _radarButtonOffset = null;
          _radarArrowAngle = null;
        });
      }
      _isRefreshingRadarControl = false;
      return;
    }

    try {
      final center = await controller.getScreenCoordinate(latestPosition);
      final eastEdge = await controller.getScreenCoordinate(
        _offsetLatLng(latestPosition, _dungeonRevealDistanceMeters, 90),
      );
      final ringDx = (eastEdge.x - center.x).toDouble();
      final ringDy = (eastEdge.y - center.y).toDouble();
      final ringRadius = sqrt(ringDx * ringDx + ringDy * ringDy);
      final safeRingRadius = ringRadius < 1 ? 1.0 : ringRadius;

      var directionDx = ringDx;
      var directionDy = ringDy;
      var arrowAngle = pi / 2;

      if (_isRadarActive && _dungeonTarget != null) {
        final target = await controller.getScreenCoordinate(_dungeonTarget!);
        directionDx = (target.x - center.x).toDouble();
        directionDy = (target.y - center.y).toDouble();
      }

      final directionLength = sqrt(directionDx * directionDx + directionDy * directionDy);
      final safeDirectionLength = directionLength < 1 ? 1.0 : directionLength;
      if (directionLength >= 1) {
        arrowAngle = atan2(directionDy, directionDx) + (pi / 2);
      }
      final outwardMultiplier = (safeRingRadius + 46) / safeDirectionLength;
      final offset = Offset(
        center.x + directionDx * outwardMultiplier,
        center.y + directionDy * outwardMultiplier,
      );

      if (!mounted) {
        _isRefreshingRadarControl = false;
        return;
      }

      setState(() {
        _radarButtonOffset = offset;
        _radarArrowAngle = arrowAngle;
      });
    } catch (_) {
      // カメラ更新中の座標変換失敗は次回更新で再計算する。
    } finally {
      _isRefreshingRadarControl = false;
    }
  }

  Widget _buildFloatingRadarControl(BoxConstraints constraints) {
    if (_selectedMode != PlayMode.dungeon || !_isDungeonActive) {
      return const SizedBox.shrink();
    }

    const left = 8.0;
    const bottom = 36.0;
    final isAvailable = _radarRemaining > Duration.zero && !_isRadarActive;
    final isExhausted = _radarRemaining <= Duration.zero;
    final canToggle = _isRadarActive || isAvailable;
    final label = _isRadarActive
        ? _formatRemaining(_radarRemaining)
        : isExhausted
            ? 'レーダー使用済み'
            : 'レーダー';
    final radarBackgroundColor = _isRadarActive
      ? Colors.white.withAlpha(238)
      : isExhausted
        ? Colors.grey
        : Colors.indigo;
    final radarForegroundColor = _isRadarActive ? Colors.indigo : Colors.white;

    return Positioned(
      left: left,
      bottom: bottom,
      child: FilledButton.icon(
        onPressed: canToggle
            ? () {
                if (_isRadarActive) {
                  _deactivateRadar();
                } else {
                  _activateRadar();
                }
              }
            : null,
        icon: _isRadarActive && _radarArrowAngle != null
            ? Transform.rotate(
                angle: _radarArrowAngle!,
                child: const Icon(Icons.navigation, size: 22, color: Colors.indigo),
              )
            : const Icon(Icons.explore, size: 22),
        label: Text(
          label,
          style: TextStyle(color: radarForegroundColor),
        ),
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          backgroundColor: radarBackgroundColor,
          foregroundColor: radarForegroundColor,
          disabledBackgroundColor: _isRadarActive
              ? Colors.white.withAlpha(238)
              : isExhausted
                  ? Colors.grey
                  : Colors.indigo,
          disabledForegroundColor: _isRadarActive ? Colors.indigo : Colors.white,
          textStyle: const TextStyle(
            inherit: false,
            fontFamily: 'Roboto',
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  String _radarStatusText() {
    if (_isRadarActive) {
      return 'レーダー作動中: ${_formatRemaining(_radarRemaining)}';
    }
    if (_radarRemaining <= Duration.zero) {
      return 'レーダー使用済みです。';
    }
    return 'レーダー残り時間: ${_formatRemaining(_radarRemaining)}';
  }

  String _radarGuideText() {
    if (_radarRemaining <= Duration.zero) {
      return '紫の円が探索範囲、白地の内側とオレンジの円枠がダンジョンを視認できる100m範囲です。レーダーは10分を使い切ったため使用できません。';
    }
    return '紫の円が探索範囲、白地の内側とオレンジの円枠がダンジョンを視認できる100m範囲です。レーダーは合計10分まで使え、時間内なら何度でも再起動できます。';
  }

  Widget _buildRadarPanelRow() {
    final canUseRadar = _radarRemaining > Duration.zero;
    final isExhausted = _radarRemaining <= Duration.zero;
    final canToggle = _isRadarActive || canUseRadar;
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: canToggle
                ? () {
                    if (_isRadarActive) {
                      _deactivateRadar();
                    } else {
                      _activateRadar();
                    }
                  }
                : null,
            icon: _isRadarActive && _radarArrowAngle != null
                ? Transform.rotate(
                    angle: _radarArrowAngle!,
                    child: const Icon(Icons.navigation, size: 21, color: Colors.indigo),
                  )
                : const Icon(Icons.explore, size: 21),
            label: Text(_isRadarActive ? _formatRemaining(_radarRemaining) : (isExhausted ? 'レーダー使用済み' : 'レーダー')),
            style: FilledButton.styleFrom(
              backgroundColor: _isRadarActive
                  ? Colors.white.withAlpha(238)
                  : isExhausted
                      ? Colors.grey
                      : Colors.indigo,
              foregroundColor: _isRadarActive ? Colors.indigo : Colors.white,
              disabledBackgroundColor: _isRadarActive
                  ? Colors.white.withAlpha(238)
                  : isExhausted
                      ? Colors.grey
                      : Colors.indigo,
              disabledForegroundColor: _isRadarActive ? Colors.indigo : Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              textStyle: const TextStyle(
                inherit: false,
                fontFamily: 'Roboto',
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    );
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

    await _stopPositionTrackingIfIdle();
  }

  Future<void> _stopPositionTrackingIfIdle() async {
    if (_isRecording || _isDungeonActive) {
      return;
    }
    await _positionSubscription?.cancel();
    _positionSubscription = null;
  }

  Set<Polyline> _buildSavedRoutePolylines() {
    final polylines = <Polyline>{};
    for (final route in _savedRoutes) {
      polylines.add(
        Polyline(
          polylineId: PolylineId(route.id),
          points: route.points,
          color: Colors.blue,
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

  void _clearSuggestionPreview() {
    if (_isRecording) {
      return;
    }
    setState(() {
      _latestSuggestion = null;
      _suggestedPolyline = null;
      _suggestedDestination = null;
      _destinationMarker = null;
    });
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

    final displayedPolylines = _selectedMode == PlayMode.territory
      ? _buildSavedRoutePolylines()
      : <Polyline>{};
    final displayedPolygons = _selectedMode == PlayMode.territory
        ? _buildSavedRoutePolygons()
        : <Polygon>{};
    final displayedCircles = <Circle>{};

    if (_selectedMode == PlayMode.dungeon && _dungeonCenter != null) {
      displayedCircles.add(
        Circle(
          circleId: const CircleId('dungeon-range'),
          center: _dungeonCenter!,
          radius: _dungeonSearchRadiusMeters,
          strokeColor: Colors.deepPurple.withAlpha(180),
          strokeWidth: 2,
          fillColor: Colors.deepPurple.withAlpha(35),
        ),
      );
    }

    if (_selectedMode == PlayMode.dungeon && _isDungeonActive && _latestPosition != null) {
      displayedCircles.add(
        Circle(
          circleId: const CircleId('dungeon-reveal-zone-mask'),
          center: _latestPosition!,
          radius: _dungeonRevealDistanceMeters,
          strokeColor: Colors.white,
          strokeWidth: 1,
          fillColor: Colors.white.withAlpha(210),
        ),
      );
      displayedCircles.add(
        Circle(
          circleId: const CircleId('dungeon-reveal-zone'),
          center: _latestPosition!,
          radius: _dungeonRevealDistanceMeters,
          strokeColor: Colors.orange.withAlpha(220),
          strokeWidth: 2,
          fillColor: Colors.transparent,
        ),
      );
    }

    final displayedMarkers = <Marker>{};
    if (_destinationMarker != null) {
      displayedMarkers.add(_destinationMarker!);
    }

    final canRevealDungeon =
        _dungeonTarget != null &&
        _latestPosition != null &&
        Geolocator.distanceBetween(
              _latestPosition!.latitude,
              _latestPosition!.longitude,
              _dungeonTarget!.latitude,
              _dungeonTarget!.longitude,
            ) <=
            _dungeonRevealDistanceMeters;

    if (_selectedMode == PlayMode.dungeon && _isDungeonActive && canRevealDungeon) {
      displayedMarkers.add(
        Marker(
          markerId: const MarkerId('dungeon-target'),
          position: _dungeonTarget!,
          infoWindow: const InfoWindow(title: 'ダンジョン'),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueViolet),
        ),
      );
    }

    if (_suggestedPolyline != null) {
      displayedPolylines.add(_suggestedPolyline!);
    }

    return LayoutBuilder(
      builder: (context, constraints) => Stack(
      children: [
        GoogleMap(
          onMapCreated: (controller) {
            _mapController = controller;
            _mapControllerGeneration++;
            final generation = _mapControllerGeneration;
            _getCurrentLocation(mapGeneration: generation);
            unawaited(_refreshRadarButtonOffset());
          },
          onCameraMove: (_) {
            unawaited(_refreshRadarButtonOffset());
          },
          onCameraIdle: () {
            unawaited(_refreshRadarButtonOffset());
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
          circles: displayedCircles,
          markers: displayedMarkers,
          minMaxZoomPreference: MinMaxZoomPreference(
            _isDungeonActive ? _dungeonMinZoomLevel : null,
            null,
          ),
          myLocationEnabled: true,
          myLocationButtonEnabled: true,
          zoomControlsEnabled: true,
        ),
        Positioned(
          top: 12,
          left: 12,
          right: 12,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_showModePanel)
                Card(
                  elevation: 2,
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'モード切替',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                            IconButton(
                              onPressed: () {
                                setState(() {
                                  _showModePanel = false;
                                });
                              },
                              icon: const Icon(Icons.close),
                              visualDensity: VisualDensity.compact,
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _modeDefinitions.map((def) {
                            return ChoiceChip(
                              selected: _selectedMode == def.mode,
                              label: Text(def.label),
                              avatar: Icon(def.icon, size: 18),
                              onSelected: (_) => _switchMode(def.mode),
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                  ),
                ),
              if (!_showModePanel)
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    onPressed: () {
                      setState(() {
                        _showModePanel = true;
                      });
                    },
                    icon: const Icon(Icons.swap_horiz),
                    label: const Text('モードを表示'),
                  ),
                ),
              const SizedBox(height: 8),
              if (_selectedMode == PlayMode.recommendation)
                _buildRecommendationPanel(
                  canSuggest: canSuggest,
                  isSuggestionSupportedPlatform: isSuggestionSupportedPlatform,
                  progressText: progressText,
                ),
              if (_selectedMode == PlayMode.territory)
                Align(
                  alignment: Alignment.centerLeft,
                  child: _buildTerritoryPanel(),
                ),
              if (_selectedMode == PlayMode.dungeon) _buildDungeonPanel(),
            ],
          ),
        ),
        if (_showDungeonResult)
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black45,
              child: Center(
                child: Card(
                  color: Colors.white,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _dungeonResultMessage,
                          style: const TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: () {
                            setState(() {
                              _showDungeonResult = false;
                            });
                          },
                          child: const Text('閉じる'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        _buildFloatingRadarControl(constraints),
        if (_selectedMode != PlayMode.dungeon)
          Positioned(
            bottom: 20,
            left: 20,
            right: 20,
            child: Center(
              child: FloatingActionButton.extended(
                onPressed: _isRecording ? _stopRouteRecording : _startRegularWalk,
                label: Text(_isRecording ? '停止' : '開始'),
                icon: Icon(_isRecording ? Icons.stop : Icons.play_arrow),
                backgroundColor: _isRecording ? Colors.red : Colors.green,
              ),
            ),
          ),
      ],
    ),
    );
  }

  Widget _buildRecommendationPanel({
    required bool canSuggest,
    required bool isSuggestionSupportedPlatform,
    required String progressText,
  }) {
    if (!_showSuggestionPanel) {
      return Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.icon(
          onPressed: () {
            setState(() {
              _showSuggestionPanel = true;
            });
          },
          icon: const Icon(Icons.route),
          label: const Text('おすすめを表示'),
        ),
      );
    }

    return Card(
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
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
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
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  onPressed: (_suggestedPolyline != null && !_isRecording)
                      ? _clearSuggestionPreview
                      : null,
                  tooltip: '提案表示を消す',
                  icon: const Icon(Icons.close),
                ),
              ],
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
                child: Text(
                  '記録中: $progressText',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTerritoryPanel() {
    if (_territoryCoverageError != null) {
      return Card(
        elevation: 2,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '陣取りモード',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(
                'エラー: $_territoryCoverageError',
                style: const TextStyle(color: Colors.redAccent),
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '陣取りモード',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            const Text('踏破率'),
            const SizedBox(height: 6),
            _buildCoverageRow(
              _prefectureCoverage?.areaName ?? '都道府県',
              _prefectureCoverage?.coverageRatio ?? 0,
            ),
            const SizedBox(height: 2),
            _buildCoverageRow(
              _cityCoverage?.areaName ?? '市区',
              _cityCoverage?.coverageRatio ?? 0,
            ),
            const SizedBox(height: 2),
            _buildCoverageRow(
              _townCoverage?.areaName ?? '町村',
              _townCoverage?.coverageRatio ?? 0,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDungeonPanel() {
    if (!_showDungeonPanel) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FilledButton.icon(
              onPressed: () {
                setState(() {
                  _showDungeonPanel = true;
                });
              },
              icon: const Icon(_dungeonIcon),
              label: const Text('ダンジョンを表示'),
            ),
            if (_isDungeonActive) ...[
              const SizedBox(height: 8),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(230),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x26000000),
                      blurRadius: 8,
                      offset: Offset(0, 3),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Text(
                    '残り時間: ${_formatRemaining(_dungeonRemaining)}',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: Colors.black87,
                        ),
                  ),
                ),
              ),
            ],
          ],
        ),
      );
    }

    return Card(
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
                    'ダンジョンモード',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  onPressed: () {
                    setState(() {
                      _showDungeonPanel = false;
                    });
                  },
                  icon: const Icon(Icons.close),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text('現在位置から半径500m内にダンジョンを発生します。発見して討伐してください！'),
            const SizedBox(height: 8),
            if (_isDungeonActive)
              Text(
                '残り時間: ${_formatRemaining(_dungeonRemaining)}',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                ),
              ),
            if (_isDungeonActive) ...[
              const SizedBox(height: 6),
              Text(
                _radarStatusText(),
                style: const TextStyle(color: Colors.black87),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _isDungeonActive ? null : _startDungeon,
                    icon: const Icon(_dungeonIcon),
                    label: Text(_isDungeonActive ? '挑戦中...' : 'ダンジョン発生'),
                  ),
                ),
                if (_isDungeonActive) ...[
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    onPressed: _cancelDungeon,
                    tooltip: '挑戦をキャンセル',
                    icon: const Icon(Icons.close),
                  ),
                ],
              ],
            ),
            if (_isDungeonActive) ...[
              const SizedBox(height: 8),
              _buildRadarPanelRow(),
            ],
            const SizedBox(height: 6),
            Text(
              _radarGuideText(),
              style: TextStyle(color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }
}

class RoutesHistoryPage extends StatefulWidget {
  const RoutesHistoryPage({
    super.key,
    required this.prefs,
    required this.onRouteDeleted,
  });

  final SharedPreferences prefs;
  final VoidCallback onRouteDeleted;

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
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const Expanded(
                  child: TabBar(
                    tabs: [
                      Tab(text: '散歩履歴'),
                      Tab(text: 'ダンジョン履歴'),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () {
                    widget.onRouteDeleted();
                    setState(() {});
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text('リロード'),
                ),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                FutureBuilder<List<WalkRoute>>(
                  future: routeService.getRoutes(),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    final routes = snapshot.data ?? [];
                    if (routes.isEmpty) {
                      return const Center(child: Text('記録されたルートがありません'));
                    }

                    return ListView.builder(
                      itemCount: routes.length,
                      itemBuilder: (context, index) {
                        final route = routes[index];
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: Colors.blue,
                            child: Text(
                              '${route.distanceKm.toStringAsFixed(1)}km',
                              style: const TextStyle(fontSize: 10, color: Colors.white),
                            ),
                          ),
                          title: Text(
                            '${route.startTime.month}/${route.startTime.day} ${route.startTime.hour}:${route.startTime.minute.toString().padLeft(2, '0')}',
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
                FutureBuilder<List<DungeonChallengeResult>>(
                  future: routeService.getDungeonResults(),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    final results = snapshot.data ?? [];
                    if (results.isEmpty) {
                      return const Center(child: Text('ダンジョン挑戦履歴がありません'));
                    }

                    return ListView.builder(
                      itemCount: results.length,
                      itemBuilder: (context, index) {
                        final result = results[index];
                        final status = result.success ? '成功' : '失敗';
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor:
                                result.success ? Colors.teal : Colors.redAccent,
                            child: Icon(
                              result.success ? Icons.check : Icons.close,
                              color: Colors.white,
                            ),
                          ),
                          title: Text(
                            '${result.startTime.month}/${result.startTime.day} ${result.startTime.hour}:${result.startTime.minute.toString().padLeft(2, '0')}',
                          ),
                          subtitle: Text(
                            '$status | 経過: ${result.elapsedMinutes}分',
                          ),
                        );
                      },
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
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
