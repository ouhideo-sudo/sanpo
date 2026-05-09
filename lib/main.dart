import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
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
  static const _autoFinishKey = 'auto_finish_on_suggested_complete';
  late GoogleMapController mapController;
  late RouteService routeService;
  int _currentIndex = 0;
  Set<Polyline> _polylines = {};
  Polyline? _suggestedPolyline;
  Set<Marker> _suggestionMarkers = {};
  RouteSuggestion? _latestSuggestion;
  double _selectedSuggestionDistanceKm = 2.0;
  bool _isSuggesting = false;
  double? _targetDistanceKm;
  int _reachedCheckpointCount = 0;
  final Set<int> _reachedCheckpointIndexes = <int>{};
  bool _suggestedRouteCompleted = false;
  bool _autoFinishOnSuggestedComplete = true;
  final List<LatLng> _currentRoute = [];
  bool _isRecording = false;
  DateTime? _recordingStartTime;
  
  @override
  void initState() {
    super.initState();
    routeService = RouteService(widget.prefs);
    _autoFinishOnSuggestedComplete =
        widget.prefs.getBool(_autoFinishKey) ?? true;
    _requestLocationPermission();
    _loadSavedRoutes();
  }

  Future<void> _setAutoFinishOnSuggestedComplete(bool value) async {
    setState(() {
      _autoFinishOnSuggestedComplete = value;
    });
    await widget.prefs.setBool(_autoFinishKey, value);
  }

  Future<void> _loadSavedRoutes() async {
    final routes = await routeService.getRoutes();
    final colors = [Colors.blue, Colors.green, Colors.orange, Colors.purple, Colors.red];
    
    final polylines = <Polyline>{};
    for (int i = 0; i < routes.length; i++) {
      polylines.add(
        Polyline(
          polylineId: PolylineId(routes[i].id),
          points: routes[i].points,
          color: colors[i % colors.length],
          width: 3,
        ),
      );
    }
    
    setState(() {
      _polylines = polylines;
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
      _reachedCheckpointCount = 0;
      _reachedCheckpointIndexes.clear();
      _suggestedRouteCompleted = false;
      _currentRoute.clear();
      _recordingStartTime = DateTime.now();
    });
    _trackPosition();
  }

  void _startSuggestedWalk() {
    if (_latestSuggestion == null || _isRecording) {
      return;
    }

    _startRouteRecording(targetDistanceKm: _latestSuggestion!.distanceKm);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '提案ルートで開始: ${_latestSuggestion!.distanceKm.toStringAsFixed(1)}km',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _stopRouteRecording() async {
    final wasSuggestedRoute = _targetDistanceKm != null;
    final suggestedCompleted = _suggestedRouteCompleted;

    setState(() {
      _isRecording = false;
      _targetDistanceKm = null;
      _suggestedRouteCompleted = false;
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
        isSuggestedCompleted: suggestedCompleted,
      );

      await routeService.saveRoute(route);

      setState(() {
        _polylines.add(
          Polyline(
            polylineId: PolylineId(route.id),
            points: _currentRoute,
            color: Colors.blue,
            width: 3,
          ),
        );
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

  Future<void> _trackPosition() async {
    if (!_isRecording) return;

    final position = await Geolocator.getCurrentPosition();
    final latLng = LatLng(position.latitude, position.longitude);
    var completedNow = false;

    if (mounted) {
      final newlyReached = _findNewlyReachedCheckpoints(
        suggestionPoints: _latestSuggestion?.points,
        walkedPoint: latLng,
      );

      setState(() {
        _currentRoute.add(latLng);
        if (_latestSuggestion != null && _targetDistanceKm != null) {
          _reachedCheckpointIndexes.addAll(newlyReached);
          _reachedCheckpointCount = _reachedCheckpointIndexes.length;
          _suggestionMarkers = _buildSuggestionMarkers(_latestSuggestion!.points);

          final justReachedGoal = !_suggestedRouteCompleted &&
              _reachedCheckpointCount >= 4 &&
              _isNearSuggestionStart(
                suggestionPoints: _latestSuggestion!.points,
                currentPoint: latLng,
              );
          if (justReachedGoal) {
            _suggestedRouteCompleted = true;
            completedNow = true;
          }
        }
      });

      if (newlyReached.isNotEmpty) {
        final sorted = newlyReached.toList()..sort();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('チェックポイント ${sorted.join(', ')} に到達！'),
              duration: const Duration(seconds: 1),
            ),
          );
        }
      }

      if (completedNow && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('提案ルート完歩！おつかれさまでした。'),
            duration: Duration(seconds: 2),
          ),
        );

        if (_autoFinishOnSuggestedComplete && _isRecording) {
          await _stopRouteRecording();
          if (!mounted) {
            return;
          }
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('オートフィニッシュ: 記録を自動保存しました。'),
              duration: Duration(seconds: 2),
            ),
          );
          return;
        }
      }
    }

    // 次の更新を1秒後に予約
    await Future.delayed(const Duration(seconds: 1));
    _trackPosition();
  }

  void _clearRoutes() {
    setState(() {
      _polylines.clear();
      _suggestedPolyline = null;
      _suggestionMarkers = {};
      _latestSuggestion = null;
      _reachedCheckpointCount = 0;
      _reachedCheckpointIndexes.clear();
      _suggestedRouteCompleted = false;
      _currentRoute.clear();
    });
  }

  Future<void> _suggestRoute() async {
    setState(() {
      _isSuggesting = true;
    });

    try {
      final position = await Geolocator.getCurrentPosition();
      final current = LatLng(position.latitude, position.longitude);

      RouteSuggestion suggestion;
      if (ApiKeys.isConfigured) {
        // Google Maps Directions API を使用
        final service = RouteSuggestionService(mapsApiKey: ApiKeys.mapsApiKey);
        suggestion = await service.suggestLoopRoute(
          center: current,
          distanceKm: _selectedSuggestionDistanceKm,
        );
      } else {
        // API キー未設定時は従来の正方形ルート
        suggestion = RouteSuggestionService.buildLoop(
          center: current,
          distanceKm: _selectedSuggestionDistanceKm,
        );
      }

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
          _reachedCheckpointCount = 0;
          _reachedCheckpointIndexes.clear();
          _latestSuggestion = suggestion;
          _suggestedPolyline = polyline;
          _suggestionMarkers = _buildSuggestionMarkers(suggestion.points);
          _suggestedRouteCompleted = false;
        });

        final bounds = _computeBounds(suggestion.points);
        mapController.animateCamera(CameraUpdate.newLatLngBounds(bounds, 64));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('ルート提案の作成に失敗しました: $e')),
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

  Set<Marker> _buildSuggestionMarkers(List<LatLng> points) {
    // 先頭と末尾は同地点（スタート/ゴール）なので、チェックポイントは中間4点
    final markers = <Marker>{};
    for (int i = 1; i <= 4 && i < points.length - 1; i++) {
      markers.add(
        Marker(
          markerId: MarkerId('cp-$i'),
          position: points[i],
          infoWindow: InfoWindow(title: 'チェックポイント $i'),
          icon: BitmapDescriptor.defaultMarkerWithHue(
            _reachedCheckpointIndexes.contains(i)
                ? BitmapDescriptor.hueGreen
                : BitmapDescriptor.hueAzure,
          ),
        ),
      );
    }
    return markers;
  }

  Set<int> _findNewlyReachedCheckpoints({
    required List<LatLng>? suggestionPoints,
    required LatLng walkedPoint,
  }) {
    if (suggestionPoints == null || suggestionPoints.length < 3) {
      return <int>{};
    }

    final reached = <int>{};
    for (int i = 1; i <= 4 && i < suggestionPoints.length - 1; i++) {
      if (_reachedCheckpointIndexes.contains(i)) {
        continue;
      }

      final checkpoint = suggestionPoints[i];
      final meters = Geolocator.distanceBetween(
        checkpoint.latitude,
        checkpoint.longitude,
        walkedPoint.latitude,
        walkedPoint.longitude,
      );
      final isReached = meters <= 35;
      if (isReached) {
        reached.add(i);
      }
    }
    return reached;
  }

  bool _isNearSuggestionStart({
    required List<LatLng> suggestionPoints,
    required LatLng currentPoint,
  }) {
    if (suggestionPoints.isEmpty) {
      return false;
    }

    final start = suggestionPoints.first;
    final meters = Geolocator.distanceBetween(
      start.latitude,
      start.longitude,
      currentPoint.latitude,
      currentPoint.longitude,
    );
    return meters <= 45;
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
    final liveDistanceKm = _currentRoute.length > 1
        ? RouteService.calculateTotalDistance(_currentRoute)
        : 0.0;
    final progressText = _targetDistanceKm != null
        ? '${liveDistanceKm.toStringAsFixed(2)} / ${_targetDistanceKm!.toStringAsFixed(1)} km'
        : '${liveDistanceKm.toStringAsFixed(2)} km';

    final displayedPolylines = <Polyline>{..._polylines};
    final displayedMarkers = <Marker>{..._suggestionMarkers};
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
                  FilledButton.icon(
                    onPressed: (_isSuggesting || _isRecording) ? null : _suggestRoute,
                    icon: (_isSuggesting || _isRecording)
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.route),
                    label: Text(_isSuggesting ? '提案中...' : 'この距離で提案'),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Expanded(child: Text('完歩時に自動保存（オートフィニッシュ）')),
                      Switch(
                        value: _autoFinishOnSuggestedComplete,
                        onChanged: _setAutoFinishOnSuggestedComplete,
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
                        _targetDistanceKm != null
                            ? _suggestedRouteCompleted
                                ? '完歩達成！ $progressText | CP $_reachedCheckpointCount/4'
                                : '記録中: $progressText | CP $_reachedCheckpointCount/4'
                            : '記録中: $progressText',
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
                    : () => _startRouteRecording(),
                label: Text(_isRecording ? '停止' : '開始'),
                icon: Icon(_isRecording ? Icons.stop : Icons.play_arrow),
                backgroundColor: _isRecording ? Colors.red : Colors.green,
              ),
              if (_polylines.isNotEmpty)
                FloatingActionButton(
                  onPressed: _clearRoutes,
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

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.prefs});

  final SharedPreferences prefs;

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
            title: const Text('ルート履歴の自動削除'),
            subtitle: const Text('30日以上前のルートを自動削除'),
            leading: const Icon(Icons.auto_delete),
          ),
          const Divider(),
          ListTile(
            title: const Text('バージョン'),
            subtitle: const Text('1.0.0'),
            leading: const Icon(Icons.info),
          ),
        ],
      ),
    );
  }
}
