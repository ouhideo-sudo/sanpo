import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models/walk_route.dart';
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

class _SanpoHomeState extends State<SanpoHome> {
  static const double _destinationArrivalThresholdMeters = 35;

  late GoogleMapController mapController;
  late RouteService routeService;
  int _currentIndex = 0;
  List<WalkRoute> _savedRoutes = [];
  bool _showSuggestedWalkRoutes = true;
  bool _showRegularWalkRoutes = true;
  Polyline? _suggestedPolyline;
  RouteSuggestion? _latestSuggestion;
  LatLng? _suggestedDestination;
  Marker? _destinationMarker;
  double _selectedSuggestionDistanceKm = 2.0;
  bool _isSuggesting = false;
  double? _targetDistanceKm;
  final List<LatLng> _currentRoute = [];
  bool _isRecording = false;
  DateTime? _recordingStartTime;
  
  @override
  void initState() {
    super.initState();
    routeService = RouteService(widget.prefs);
    _requestLocationPermission();
    _loadSavedRoutes();
  }

  Future<void> _loadSavedRoutes() async {
    final routes = await routeService.getRoutes();

    setState(() {
      _savedRoutes = routes;
    });
  }

  Future<void> _requestLocationPermission() async {
    final status = await Geolocator.requestPermission();
    if (status == LocationPermission.denied) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('位置情報許可が必要です')),
        );
      }
    }
  }

  Future<void> _getCurrentLocation() async {
    try {
      final position = await Geolocator.getCurrentPosition();
      if (mounted) {
        mapController.animateCamera(
          CameraUpdate.newLatLngZoom(
            LatLng(position.latitude, position.longitude),
            15,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('位置情報取得エラー: $e')),
        );
      }
    }
  }

  void _startRouteRecording({double? targetDistanceKm}) {
    setState(() {
      _isRecording = true;
      _targetDistanceKm = targetDistanceKm;
      _currentRoute.clear();
      _recordingStartTime = DateTime.now();
    });
    _trackPosition();
  }

  void _startRegularWalk() {
    setState(() {
      _suggestedDestination = null;
      _destinationMarker = null;
    });
    _startRouteRecording();
  }

  void _startSuggestedWalk() {
    if (_latestSuggestion == null || _suggestedDestination == null || _isRecording) {
      return;
    }

    _startRouteRecording(targetDistanceKm: _latestSuggestion!.distanceKm);
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

  void _toggleSuggestedFilter(bool value) {
    setState(() {
      _showSuggestedWalkRoutes = value;
    });
  }

  void _toggleRegularFilter(bool value) {
    setState(() {
      _showRegularWalkRoutes = value;
    });
  }

  Future<void> _trackPosition() async {
    if (!_isRecording) return;

    final position = await Geolocator.getCurrentPosition();
    final latLng = LatLng(position.latitude, position.longitude);
    if (mounted) {
      setState(() {
        _currentRoute.add(latLng);
      });

      final reachedDestination = _targetDistanceKm != null &&
          _suggestedDestination != null &&
          _isNearDestination(latLng);

      if (reachedDestination) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('目的地に到着しました。記録を自動保存します。'),
            duration: Duration(seconds: 2),
          ),
        );
        await _stopRouteRecording(isSuggestedCompleted: true);
        return;
      }
    }

    // 次の更新を1秒後に予約
    await Future.delayed(const Duration(seconds: 1));
    _trackPosition();
  }

  Future<void> _clearRoutes() async {
    await routeService.deleteAllRoutes();
    if (!mounted) {
      return;
    }

    setState(() {
      _savedRoutes = [];
      _suggestedPolyline = null;
      _latestSuggestion = null;
      _suggestedDestination = null;
      _destinationMarker = null;
      _currentRoute.clear();
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('保存済みルートを削除しました')),
    );
  }

  Future<void> _suggestRoute() async {
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
      final service = RouteSuggestionService(mapsApiKey: mapsApiKey);
      final suggestion = await service.suggestLoopRoute(
        center: current,
        distanceKm: _selectedSuggestionDistanceKm,
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
        mapController.animateCamera(CameraUpdate.newLatLngBounds(bounds, 64));
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

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      _buildMapPage(),
      RoutesHistoryPage(prefs: widget.prefs, onRouteDeleted: _loadSavedRoutes),
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
            mapController = controller;
            _getCurrentLocation();
          },
          initialCameraPosition: const CameraPosition(
            target: LatLng(35.6762, 139.6503), // 東京
            zoom: 15,
          ),
          polylines: displayedPolylines,
          markers: displayedMarkers,
          myLocationEnabled: true,
          myLocationButtonEnabled: true,
          zoomControlsEnabled: true,
        ),
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
                  const Text(
                    'おすすめ散歩ルート',
                    style: TextStyle(fontWeight: FontWeight.bold),
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
                      child: Text(
                        '記録中: $progressText',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          bottom: 20,
          left: 20,
          right: 20,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              FloatingActionButton.extended(
                onPressed: _isRecording
                    ? _stopRouteRecording
                    : _startRegularWalk,
                label: Text(_isRecording ? '停止' : '開始'),
                icon: Icon(_isRecording ? Icons.stop : Icons.play_arrow),
                backgroundColor: _isRecording ? Colors.red : Colors.green,
              ),
              if (_savedRoutes.isNotEmpty || _suggestedPolyline != null)
                FloatingActionButton(
                  onPressed: () => _clearRoutes(),
                  backgroundColor: Colors.grey,
                  child: const Icon(Icons.delete_outline),
                ),
            ],
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
    return FutureBuilder<List<WalkRoute>>(
      future: routeService.getRoutes(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.history, size: 64, color: Colors.grey),
                SizedBox(height: 16),
                Text('ルート履歴がありません'),
                SizedBox(height: 8),
                Text('散歩ルートを記録してみましょう'),
              ],
            ),
          );
        }

        final routes = snapshot.data!;
        return ListView.builder(
          itemCount: routes.length,
          itemBuilder: (context, index) {
            final route = routes[index];
            return ListTile(
              leading: const Icon(Icons.directions_walk),
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${route.startTime.month}/${route.startTime.day} - ${route.distanceKm.toStringAsFixed(2)}km',
                    ),
                  ),
                  if (route.isSuggestedCompleted)
                    const Chip(
                      label: Text('提案完歩'),
                      visualDensity: VisualDensity.compact,
                    )
                  else if (route.isSuggested)
                    const Chip(
                      label: Text('提案ルート'),
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
                  await routeService.deleteRoute(route.id);
                  widget.onRouteDeleted();
                  setState(() {});
                },
              ),
            );
          },
        );
      },
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
