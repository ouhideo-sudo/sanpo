import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models/walk_route.dart';
import 'services/route_service.dart';

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
  late GoogleMapController mapController;
  late RouteService routeService;
  int _currentIndex = 0;
  Set<Polyline> _polylines = {};
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

  void _startRouteRecording() {
    setState(() {
      _isRecording = true;
      _currentRoute.clear();
      _recordingStartTime = DateTime.now();
    });
    _trackPosition();
  }

  Future<void> _stopRouteRecording() async {
    setState(() {
      _isRecording = false;
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

    if (mounted) {
      setState(() {
        _currentRoute.add(latLng);
      });
    }

    // 次の更新を1秒後に予約
    await Future.delayed(const Duration(seconds: 1));
    _trackPosition();
  }

  void _clearRoutes() {
    setState(() {
      _polylines.clear();
      _currentRoute.clear();
    });
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
          polylines: _polylines,
          myLocationEnabled: true,
          myLocationButtonEnabled: true,
          zoomControlsEnabled: true,
        ),
        Positioned(
          bottom: 20,
          left: 20,
          right: 20,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              FloatingActionButton.extended(
                onPressed: _isRecording ? _stopRouteRecording : _startRouteRecording,
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
              title: Text(
                '${route.startTime.month}/${route.startTime.day} - ${route.distanceKm.toStringAsFixed(2)}km',
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
