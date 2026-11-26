import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// ================= BLE UUID (與 ESP32-S3 韌體完全對齊) =================
const String kBleDevicePrefix = 'AirRide';
const String kServiceUuid = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';
const String kTelemetryUuid = 'beb5483e-36e1-4688-b7f5-ea07361b26a8';

// ================= 114年環境部最新法規門檻 =================
const double kCoWarnLimit = 9.0;
const double kCoDangerLimit = 31.0;
const double kPmWarnLimit = 30.0;
const double kPmDangerLimit = 50.5;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await WakelockPlus.enable();
  runApp(const AirRideApp());
}

class AirRideApp extends StatefulWidget {
  const AirRideApp({super.key});

  @override
  State<AirRideApp> createState() => _AirRideAppState();
}

class _AirRideAppState extends State<AirRideApp> {
  String _themeModePref = 'auto'; // 'auto' | 'light' | 'dark'
  String _lang = 'zh-TW'; // 'zh-TW' | 'en'
  Timer? _themeTimer;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _themeTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      if (_themeModePref == 'auto' && mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _themeTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _themeModePref = prefs.getString('airride_theme') ?? 'auto';
      _lang = prefs.getString('airride_lang') ?? 'zh-TW';
    });
  }

  ThemeMode get _effectiveThemeMode {
    if (_themeModePref == 'light') return ThemeMode.light;
    if (_themeModePref == 'dark') return ThemeMode.dark;
    final hour = DateTime.now().hour;
    return (hour >= 6 && hour < 18) ? ThemeMode.light : ThemeMode.dark;
  }

  Future<void> _setThemePref(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('airride_theme', mode);
    setState(() => _themeModePref = mode);
  }

  Future<void> _toggleLang() async {
    final next = _lang == 'zh-TW' ? 'en' : 'zh-TW';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('airride_lang', next);
    setState(() => _lang = next);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AirRide',
      debugShowCheckedModeBanner: false,
      themeMode: _effectiveThemeMode,
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF1F5F9),
        cardColor: Colors.white,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF10B981),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B0F19),
        cardColor: const Color(0xFF111927),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF10B981),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: AirRideHomePage(
        lang: _lang,
        themeModePref: _themeModePref,
        onChangeTheme: _setThemePref,
        onToggleLang: _toggleLang,
      ),
    );
  }
}

// ================= 主頁面 =================
class AirRideHomePage extends StatefulWidget {
  final String lang;
  final String themeModePref;
  final Future<void> Function(String) onChangeTheme;
  final Future<void> Function() onToggleLang;

  const AirRideHomePage({
    super.key,
    required this.lang,
    required this.themeModePref,
    required this.onChangeTheme,
    required this.onToggleLang,
  });

  @override
  State<AirRideHomePage> createState() => _AirRideHomePageState();
}

class _AirRideHomePageState extends State<AirRideHomePage> {
  int _tabIndex = 0;

  // 伺服器與模式設定
  String _serverAddress = '192.168.36.132:8000';
  final TextEditingController _ipController = TextEditingController();
  bool _indoorDemoMode = true;
  bool _notifyEnabled = true;
  String _selectedCity = 'taipei';
  String _recordPeriod = 'day';

  // BLE 狀態
  bool _isScanning = false;
  bool _bleConnected = false;
  String _connectedDeviceName = '';
  BluetoothDevice? _connectedDevice;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connStateSub;
  StreamSubscription<List<int>>? _notifySub;

  // 即時感測數值
  String _vehicleId = 'MOTO-01';
  double _coPpm = 0.0;
  double _pm25 = 0.0;
  int _vocIndex = 0;
  double _temp = 0.0;
  double _humidity = 0.0;
  String _status = 'normal';
  final List<double> _coHistory = List.filled(24, 0.0, growable: true);

  // GPS 與軌跡
  double _lat = 25.0463;
  double _lng = 121.5170;
  int _speedKmh = 0;
  StreamSubscription<Position>? _gpsSub;
  final List<Offset> _localTrail = [];

  // 單趟騎乘記錄器
  bool _rideActive = false;
  DateTime? _rideStartTime;
  final List<double> _sessionCoSamples = [];
  final List<double> _sessionPmSamples = [];
  double _sessionPeakCo = 0.0;
  int _sessionDangerSec = 0;
  double _sessionDistanceMeters = 0.0;
  DateTime _lastDataAt = DateTime.now();
  Timer? _rideTicker;

  // 離線補傳與歷史報告
  final List<Map<String, dynamic>> _pendingQueue = [];
  bool _gatewayOnline = false;
  List<Map<String, dynamic>> _savedReports = [];

  // 本地通知
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  DateTime _lastAlertNotifTime = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isZh => widget.lang == 'zh-TW';

  @override
  void initState() {
    super.initState();
    _ipController.text = _serverAddress;
    _initNotifications();
    _loadSettingsAndData();
    _startGpsListener();
    _startRideTimer();
  }

  @override
  void dispose() {
    _ipController.dispose();
    _scanSub?.cancel();
    _connStateSub?.cancel();
    _notifySub?.cancel();
    _gpsSub?.cancel();
    _rideTicker?.cancel();
    _connectedDevice?.disconnect();
    super.dispose();
  }

  Future<void> _initNotifications() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const settings = InitializationSettings(android: androidInit, iOS: iosInit);
    await _notifications.initialize(settings);
  }

  Future<void> _loadSettingsAndData() async {
    final prefs = await SharedPreferences.getInstance();
    final savedIp = prefs.getString('server_addr') ?? '192.168.36.132:8000';
    setState(() {
      _serverAddress = savedIp;
      _ipController.text = savedIp;
      _indoorDemoMode = prefs.getBool('indoor_demo') ?? true;
      _notifyEnabled = prefs.getBool('notify_enabled') ?? true;
      _selectedCity = prefs.getString('selected_city') ?? 'taipei';

      final reportsRaw = prefs.getString('saved_reports');
      if (reportsRaw != null) {
        _savedReports = List<Map<String, dynamic>>.from(jsonDecode(reportsRaw));
      }
      final queueRaw = prefs.getString('pending_queue');
      if (queueRaw != null) {
        _pendingQueue.addAll(
          List<Map<String, dynamic>>.from(jsonDecode(queueRaw)),
        );
      }
    });
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location,
        Permission.notification,
      ].request();
    } else if (Platform.isIOS) {
      await [
        Permission.bluetooth,
        Permission.locationWhenInUse,
        Permission.notification,
      ].request();
    }
  }

  Future<void> _startGpsListener() async {
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) return;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return;
      }

      _gpsSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5,
        ),
      ).listen((pos) {
        if (!mounted) return;
        setState(() {
          if (!_indoorDemoMode) {
            if (_rideActive) {
              _sessionDistanceMeters += Geolocator.distanceBetween(
                _lat,
                _lng,
                pos.latitude,
                pos.longitude,
              );
            }
            _lat = pos.latitude;
            _lng = pos.longitude;
          }
          _speedKmh = (pos.speed * 3.6).clamp(0, 200).round();
        });
      });
    } catch (_) {}
  }

  // ================= BLE 掃描與連線 =================
  Future<void> _scanAndConnectBle() async {
    await _requestPermissions();
    if (_isScanning) return;

    setState(() => _isScanning = true);
    bool foundTarget = false;

    try {
      _scanSub?.cancel();
      _scanSub = FlutterBluePlus.scanResults.listen((results) async {
        for (final r in results) {
          final name = r.device.platformName.isNotEmpty
              ? r.device.platformName
              : r.advertisementData.advName;
          final hasService = r.advertisementData.serviceUuids.any(
            (u) => u.toString().toLowerCase() == kServiceUuid.toLowerCase(),
          );
          if (name.contains(kBleDevicePrefix) || hasService) {
            if (!foundTarget) {
              foundTarget = true;
              await FlutterBluePlus.stopScan();
              await _connectToDevice(
                r.device,
                name.isEmpty ? 'AirRide-MOTO-01' : name,
              );
            }
            break;
          }
        }
      });

      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 6));
    } catch (e) {
      if (mounted) {
        _showSnack(isZh ? '藍牙掃描失敗：$e' : 'BLE Scan failed: $e');
      }
    } finally {
      if (mounted) setState(() => _isScanning = false);
    }
  }

  Future<void> _connectToDevice(BluetoothDevice device, String label) async {
    try {
      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 10),
      );
      _connectedDevice = device;

      _connStateSub?.cancel();
      _connStateSub = device.connectionState.listen((state) {
        if (!mounted) return;
        if (state == BluetoothConnectionState.disconnected) {
          final wasRiding = _rideActive && _sessionCoSamples.length >= 3;
          setState(() {
            _bleConnected = false;
            _connectedDeviceName = '';
          });
          if (wasRiding) {
            _finishRideAndSaveReport();
          }
        }
      });

      final services = await device.discoverServices();
      for (final s in services) {
        if (s.uuid.toString().toLowerCase() == kServiceUuid.toLowerCase()) {
          for (final c in s.characteristics) {
            if (c.uuid.toString().toLowerCase() ==
                kTelemetryUuid.toLowerCase()) {
              await c.setNotifyValue(true);
              _notifySub?.cancel();
              _notifySub = c.lastValueStream.listen(_handleBleBytes);
              setState(() {
                _bleConnected = true;
                _connectedDeviceName = label;
              });
              _showSnack(isZh ? '✅ 已透過藍牙連上 $label' : '✅ Connected to $label');
              return;
            }
          }
        }
      }
    } catch (e) {
      if (mounted) {
        _showSnack(isZh ? '藍牙連線失敗：$e' : 'BLE Connect failed: $e');
      }
    }
  }

  Future<void> _disconnectBle() async {
    await _connectedDevice?.disconnect();
  }

  // ================= 處理 ESP32 BLE 傳來的 JSON 數據 =================
  void _handleBleBytes(List<int> bytes) {
    if (bytes.isEmpty) return;
    try {
      final rawStr = utf8.decode(bytes);
      final map = jsonDecode(rawStr) as Map<String, dynamic>;

      final double co = (map['co'] ?? 0.0).toDouble();
      final double pm = (map['pm'] ?? 0.0).toDouble();
      final int voc = (map['voc'] ?? 0).toInt();
      final double temp = (map['t'] ?? 32.0).toDouble();
      final double hum = (map['h'] ?? 60.0).toDouble();
      final String vid = (map['v'] ?? 'MOTO-01').toString();

      final String evalStatus = co >= kCoDangerLimit
          ? 'danger'
          : (co >= kCoWarnLimit ? 'warning' : 'normal');

      _lastDataAt = DateTime.now();

      if (!_rideActive) {
        _rideActive = true;
        _rideStartTime = DateTime.now();
        _sessionCoSamples.clear();
        _sessionPmSamples.clear();
        _sessionPeakCo = 0.0;
        _sessionDangerSec = 0;
        _sessionDistanceMeters = 0.0;
      }

      _sessionCoSamples.add(co);
      _sessionPmSamples.add(pm);
      if (co > _sessionPeakCo) _sessionPeakCo = co;
      if (co >= kCoDangerLimit) _sessionDangerSec += 2;
      if (_indoorDemoMode) {
        _sessionDistanceMeters += 20.0;
      }

      setState(() {
        _vehicleId = vid;
        _coPpm = co;
        _pm25 = pm;
        _vocIndex = voc;
        _temp = temp;
        _humidity = hum;
        _status = evalStatus;
        _coHistory.add(co);
        if (_coHistory.length > 24) _coHistory.removeAt(0);

        _localTrail.add(
          Offset(
            (_localTrail.isEmpty ? 0.5 : _localTrail.last.dx) +
                (math.cos(_sessionCoSamples.length * 0.35) * 0.05),
            (_localTrail.isEmpty ? 0.5 : _localTrail.last.dy) +
                (math.sin(_sessionCoSamples.length * 0.35) * 0.05),
          ),
        );
        if (_localTrail.length > 30) _localTrail.removeAt(0);
      });

      if (evalStatus == 'danger') {
        HapticFeedback.heavyImpact();
        _triggerBackgroundDangerNotification(co);
      }

      _forwardTelemetryToBackend(
        vid: vid,
        co: co,
        pm25: pm,
        voc: voc,
        temp: temp,
        hum: hum,
      );
    } catch (_) {}
  }

  Future<void> _triggerBackgroundDangerNotification(double co) async {
    if (!_notifyEnabled) return;
    final now = DateTime.now();
    if (now.difference(_lastAlertNotifTime).inSeconds < 10) return;
    _lastAlertNotifTime = now;

    const androidDetails = AndroidNotificationDetails(
      'airride_danger_channel',
      '排放超標危險警報',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentSound: true,
    );
    await _notifications.show(
      1001,
      isZh ? '🚨 排氣嚴重超標警報' : '🚨 Hazardous CO Emission Alert',
      isZh
          ? 'CO 濃度達 ${co.toStringAsFixed(1)} ppm（超過 31.0 ppm 法定上限）！'
          : 'CO reached ${co.toStringAsFixed(1)} ppm (exceeded 31.0 ppm)!',
      const NotificationDetails(android: androidDetails, iOS: iosDetails),
    );
  }

  Future<void> _forwardTelemetryToBackend({
    required String vid,
    required double co,
    required double pm25,
    required int voc,
    required double temp,
    required double hum,
  }) async {
    final payload = {
      'vehicle_id': vid,
      'plate_number': vid == 'MOTO-01' ? 'EMG-0001' : 'EMG-0002',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'gps': {
        'lat': _indoorDemoMode ? 0.0 : _lat,
        'lng': _indoorDemoMode ? 0.0 : _lng,
      },
      'sensors': {
        'co_ppm': co,
        'pm1_0': double.parse((pm25 * 0.75).toStringAsFixed(1)),
        'pm2_5': pm25,
        'pm4_0': double.parse((pm25 * 1.15).toStringAsFixed(1)),
        'pm10': double.parse((pm25 * 1.25).toStringAsFixed(1)),
        'voc_index': voc,
        'nox_index': 2,
        'temp': temp,
        'humidity': hum,
      },
    };

    try {
      final uri = Uri.parse('http://$_serverAddress/api/telemetry');
      final res = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 2));

      if (res.statusCode == 200) {
        if (mounted) setState(() => _gatewayOnline = true);
        if (_pendingQueue.isNotEmpty) {
          _flushPendingQueue();
        }
      } else {
        _enqueueOffline(payload);
      }
    } catch (_) {
      _enqueueOffline(payload);
    }
  }

  Future<void> _enqueueOffline(Map<String, dynamic> payload) async {
    if (mounted) setState(() => _gatewayOnline = false);
    if (_pendingQueue.length < 300) {
      _pendingQueue.add(payload);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('pending_queue', jsonEncode(_pendingQueue));
    }
  }

  Future<void> _flushPendingQueue() async {
    final copy = List<Map<String, dynamic>>.from(_pendingQueue);
    _pendingQueue.clear();
    for (final item in copy) {
      try {
        await http
            .post(
              Uri.parse('http://$_serverAddress/api/telemetry'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(item),
            )
            .timeout(const Duration(seconds: 2));
      } catch (_) {
        _pendingQueue.add(item);
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pending_queue', jsonEncode(_pendingQueue));
  }

  // ================= 熄火偵測與騎乘報告結算 =================
  void _startRideTimer() {
    _rideTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_rideActive) {
        setState(() {});
        if (DateTime.now().difference(_lastDataAt).inSeconds >= 8 &&
            _sessionCoSamples.length >= 3) {
          _finishRideAndSaveReport();
        }
      }
    });
  }

  Future<void> _finishRideAndSaveReport() async {
    if (!_rideActive) return;
    final start = _rideStartTime ?? DateTime.now();
    final end = DateTime.now();
    final durSec = math.max(1, end.difference(start).inSeconds);
    final durMin = math.max(1, (durSec / 60).round());
    final count = _sessionCoSamples.length;
    final avgCo = count > 0
        ? double.parse(
            (_sessionCoSamples.reduce((a, b) => a + b) / count)
                .toStringAsFixed(1),
          )
        : 0.0;
    final avgPm = count > 0
        ? double.parse(
            (_sessionPmSamples.reduce((a, b) => a + b) / count)
                .toStringAsFixed(1),
          )
        : 0.0;
    final peakCo = double.parse(_sessionPeakCo.toStringAsFixed(1));
    final distKm = double.parse(
      (_sessionDistanceMeters / 1000).toStringAsFixed(2),
    );
    final rating = avgCo < kCoWarnLimit
        ? '優良過濾'
        : (avgCo < kCoDangerLimit ? '中等過濾' : '超標偏高');

    final report = {
      'vehicle_id': _vehicleId,
      'plate_number': _vehicleId == 'MOTO-01' ? 'EMG-0001' : 'EMG-0002',
      'start_time': start.toIso8601String(),
      'end_time': end.toIso8601String(),
      'duration_seconds': durSec,
      'duration_minutes': durMin,
      'distance_km': distKm,
      'avg_co_ppm': avgCo,
      'max_co_ppm': peakCo,
      'danger_seconds': _sessionDangerSec,
      'avg_pm25': avgPm,
      'rating': rating,
      'created_at': end.toIso8601String(),
    };

    setState(() {
      _rideActive = false;
      _savedReports.insert(0, report);
      if (_savedReports.length > 30) _savedReports.removeLast();
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_reports', jsonEncode(_savedReports));

    try {
      await http
          .post(
            Uri.parse('http://$_serverAddress/api/ride_reports'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(report),
          )
          .timeout(const Duration(seconds: 3));
    } catch (_) {}

    if (mounted) {
      _showReportDialog(report);
    }
  }

  Future<void> _switchBackendCity(String cityKey) async {
    setState(() => _selectedCity = cityKey);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_city', cityKey);
    try {
      await http
          .post(Uri.parse('http://$_serverAddress/api/city/$cityKey'))
          .timeout(const Duration(seconds: 2));
      _showSnack(
        cityKey == 'taipei'
            ? (isZh ? '已同步切換為：台灣台北地圖' : 'Switched to Taipei Map')
            : (isZh ? '已同步切換為：韓國首爾地圖' : 'Switched to Seoul Map'),
      );
    } catch (_) {}
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  String _formatElapsed() {
    if (!_rideActive || _rideStartTime == null) return '00:00:00';
    final sec = DateTime.now().difference(_rideStartTime!).inSeconds;
    final h = (sec ~/ 3600).toString().padLeft(2, '0');
    final m = ((sec % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (sec % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  // ================= UI 建構 =================
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bool showDangerOverlay = _bleConnected && _status == 'danger';

    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                _buildHeader(isDark),
                Expanded(
                  child: IndexedStack(
                    index: _tabIndex,
                    children: [
                      _buildHomeTab(isDark),
                      _buildMapTab(isDark),
                      _buildRecordsTab(isDark),
                      _buildSettingsTab(isDark),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (showDangerOverlay) _buildDangerFullOverlay(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (idx) => setState(() => _tabIndex = idx),
        backgroundColor: isDark ? const Color(0xFF0F172A) : Colors.white,
        indicatorColor: const Color(0xFF10B981).withValues(alpha: 0.2),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.speed_outlined),
            selectedIcon: const Icon(Icons.speed, color: Color(0xFF10B981)),
            label: isZh ? '首頁儀表' : 'HUD',
          ),
          NavigationDestination(
            icon: const Icon(Icons.map_outlined),
            selectedIcon: const Icon(Icons.map, color: Color(0xFF10B981)),
            label: isZh ? '污染地圖' : 'Map',
          ),
          NavigationDestination(
            icon: const Icon(Icons.bar_chart_outlined),
            selectedIcon: const Icon(Icons.bar_chart, color: Color(0xFF10B981)),
            label: isZh ? '騎乘紀錄' : 'Records',
          ),
          NavigationDestination(
            icon: const Icon(Icons.settings_outlined),
            selectedIcon: const Icon(Icons.settings, color: Color(0xFF10B981)),
            label: isZh ? '系統設定' : 'Settings',
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F172A) : Colors.white,
        border: Border(
          bottom: BorderSide(
            color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
          ),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: const Color(0xFF10B981).withValues(alpha: 0.15),
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFF10B981)),
            ),
            child: const Icon(Icons.eco, color: Color(0xFF10B981), size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      'AirRide',
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _bleConnected ? const Color(0xFF10B981) : Colors.grey,
                      ),
                    ),
                  ],
                ),
                Text(
                  _bleConnected
                      ? (isZh ? '藍牙已連線：$_connectedDeviceName' : 'BLE: $_connectedDeviceName')
                      : (isZh ? '等待藍牙連線 ESP32-S3' : 'Waiting for BLE ESP32-S3'),
                  style: TextStyle(
                    fontSize: 11,
                    color: _bleConnected ? const Color(0xFF10B981) : Colors.grey,
                  ),
                ),
              ],
            ),
          ),
          InkWell(
            onTap: _bleConnected ? _disconnectBle : _scanAndConnectBle,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: _bleConnected
                    ? const Color(0xFF10B981).withValues(alpha: 0.15)
                    : const Color(0xFF0284C7).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _bleConnected ? const Color(0xFF10B981) : const Color(0xFF0284C7),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _isScanning
                        ? Icons.bluetooth_searching
                        : (_bleConnected ? Icons.bluetooth_connected : Icons.bluetooth),
                    size: 14,
                    color: _bleConnected ? const Color(0xFF10B981) : const Color(0xFF0284C7),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _isScanning
                        ? (isZh ? '搜尋中' : 'Scan...')
                        : (_bleConnected ? (isZh ? '已連線' : 'Linked') : (isZh ? '連藍牙' : 'Connect')),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: _bleConnected ? const Color(0xFF10B981) : const Color(0xFF0284C7),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHomeTab(bool isDark) {
    final Color statusColor = _status == 'danger'
        ? const Color(0xFFEF4444)
        : (_status == 'warning' ? const Color(0xFFF59E0B) : const Color(0xFF10B981));
    final String levelLabel = _status == 'danger'
        ? (isZh ? '🔴 危險 (嚴重超標)' : '🔴 Danger')
        : (_status == 'warning' ? (isZh ? '🟡 警告 (排放偏高)' : '🟡 Warning') : (isZh ? '🌱 良好 (安心騎行)' : '🌱 Normal'));
    final String bannerHint = !_bleConnected
        ? (isZh ? '⚪ 開發板亮白燈等待中，請點擊右上角「連藍牙」' : '⚪ Board waiting (White LED). Tap Connect.')
        : (_status == 'danger'
            ? (isZh ? '🚨 尾氣嚴重超標！正強制警報中！' : '🚨 Critical emissions!')
            : (_status == 'warning'
                ? (isZh ? '⚠️ 排氣略高，建議留意濾網與通風。' : '⚠️ Elevated exhaust level.')
                : (isZh ? '✅ 目前排氣過濾良好，可安心巡航！' : '✅ Exhaust filtration optimal.')));

    final pmColor = _pm25 >= kPmDangerLimit
        ? const Color(0xFFEF4444)
        : (_pm25 >= kPmWarnLimit ? const Color(0xFFF59E0B) : const Color(0xFF10B981));

    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF10B981).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        _rideActive
                            ? (isZh ? '🏍️ 騎行監測中' : '🏍️ Riding')
                            : (isZh ? '⏸️ 待機準備中' : '⏸️ Standby'),
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF10B981)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '⏱️ ${_formatElapsed()}',
                      style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                  ],
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text('$_speedKmh', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: Color(0xFF38BDF8))),
                    const SizedBox(width: 3),
                    const Text('km/h', style: TextStyle(fontSize: 11, color: Colors.grey)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0)),
            ),
            child: Column(
              children: [
                SizedBox(
                  width: 205,
                  height: 205,
                  child: CustomPaint(
                    painter: _CoGaugePainter(
                      value: _coPpm,
                      maxValue: 45.0,
                      activeColor: statusColor,
                      trackColor: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                    ),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            isZh ? 'CO 排放濃度' : 'CO Level',
                            style: const TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.bold),
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Text(
                                _coPpm.toStringAsFixed(1),
                                style: const TextStyle(fontSize: 44, fontWeight: FontWeight.w900),
                              ),
                              const SizedBox(width: 3),
                              const Text('ppm', style: TextStyle(fontSize: 13, color: Colors.grey, fontWeight: FontWeight.bold)),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                            decoration: BoxDecoration(
                              color: statusColor.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: statusColor),
                            ),
                            child: Text(levelLabel, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: statusColor)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: statusColor.withValues(alpha: 0.4)),
                  ),
                  child: Text(bannerHint, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: statusColor)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          Row(
            children: [
              _miniMetricCard('CO', _coPpm.toStringAsFixed(1), 'ppm', statusColor, isDark),
              const SizedBox(width: 8),
              _miniMetricCard('PM2.5', _pm25.toStringAsFixed(1), 'µg/m³', pmColor, isDark),
              const SizedBox(width: 8),
              _miniMetricCard('VOC', '$_vocIndex', 'index', const Color(0xFF6366F1), isDark),
              const SizedBox(width: 8),
              _miniMetricCard(
                isZh ? '溫溼度' : 'T / RH',
                '${_temp.toStringAsFixed(0)}°',
                '${_humidity.toStringAsFixed(0)}%',
                const Color(0xFFF59E0B),
                isDark,
              ),
            ],
          ),
          const SizedBox(height: 12),

          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0)),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(isZh ? '📈 即時排放波動趨勢' : '📈 Live CO Waveform', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    const Text('CO 門檻: 9.0 / 31.0 ppm', style: TextStyle(fontSize: 10, color: Colors.grey)),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 100,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _SparklinePainter(
                      points: _coHistory,
                      lineColor: statusColor,
                      gridColor: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _miniMetricCard(String title, String value, String unit, Color color, bool isDark) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0)),
        ),
        child: Column(
          children: [
            Text(title, style: const TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.w600)),
            const SizedBox(height: 3),
            Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: color)),
            Text(unit, style: const TextStyle(fontSize: 9, color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  Widget _buildMapTab(bool isDark) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(isZh ? '🗺️ 展演軌跡與雲端轉傳' : '🗺️ Trail & Cloud Gateway', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    Text(
                      _indoorDemoMode
                          ? (isZh ? '室內模式：後端模擬街廓移動' : 'Indoor: Backend Road Sim')
                          : 'GPS: ${_lat.toStringAsFixed(4)}, ${_lng.toStringAsFixed(4)}',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ],
                ),
                Row(
                  children: [
                    ChoiceChip(
                      label: const Text('台北', style: TextStyle(fontSize: 11)),
                      selected: _selectedCity == 'taipei',
                      onSelected: (_) => _switchBackendCity('taipei'),
                    ),
                    const SizedBox(width: 6),
                    ChoiceChip(
                      label: const Text('首爾', style: TextStyle(fontSize: 11)),
                      selected: _selectedCity == 'seoul',
                      onSelected: (_) => _switchBackendCity('seoul'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0)),
              ),
              child: CustomPaint(
                painter: _RadarTrailPainter(
                  trail: _localTrail,
                  status: _status,
                  cityLabel: _selectedCity == 'seoul' ? '🇰🇷 Seoul COEX' : '🇹🇼 Taipei City',
                  isDark: isDark,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),

          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      _gatewayOnline ? Icons.cloud_done : Icons.cloud_off,
                      color: _gatewayOnline ? const Color(0xFF10B981) : Colors.amber,
                    ),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _gatewayOnline
                              ? (isZh ? '監控後端同步中' : 'Synced to Monitor')
                              : (isZh ? '離線快取保護中' : 'Offline Caching'),
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                        Text(
                          '$_serverAddress (${isZh ? '待補傳' : 'Queued'}: ${_pendingQueue.length})',
                          style: const TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                      ],
                    ),
                  ],
                ),
                if (_pendingQueue.isNotEmpty)
                  TextButton(
                    onPressed: _flushPendingQueue,
                    child: Text(isZh ? '立即補傳' : 'Retry'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordsTab(bool isDark) {
    final labels = _recordPeriod == 'day'
        ? ['06', '09', '12', '15', '18', '21']
        : (_recordPeriod == 'week' ? ['一', '二', '三', '四', '五', '六', '日'] : ['W1', 'W2', 'W3', 'W4']);
    final values = _recordPeriod == 'day'
        ? [4.2, 18.5, 9.2, 11.4, 24.2, 12.0]
        : (_recordPeriod == 'week' ? [8.5, 7.8, 8.1, 9.4, 11.2, 5.5, 4.8] : [8.2, 7.9, 7.4, 7.1]);
    final peakText = _recordPeriod == 'day'
        ? (isZh ? '今日排放峰值時段：17:00 ~ 19:00 (24.2 ppm)' : 'Peak today: 17:00~19:00')
        : (_recordPeriod == 'week'
            ? (isZh ? '本週最高日期：週五晚間 (11.2 ppm)' : 'Peak week: Fri night')
            : (isZh ? '月度濾網效能：穩定優良' : 'Monthly filtration: Optimal'));

    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(isZh ? '📊 排放時段分析' : '📊 Emission Analysis', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'day', label: Text('日', style: TextStyle(fontSize: 11))),
                        ButtonSegment(value: 'week', label: Text('週', style: TextStyle(fontSize: 11))),
                        ButtonSegment(value: 'month', label: Text('月', style: TextStyle(fontSize: 11))),
                      ],
                      selected: {_recordPeriod},
                      onSelectionChanged: (s) => setState(() => _recordPeriod = s.first),
                      showSelectedIcon: false,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 110,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _BarChartPainter(labels: labels, values: values, isDark: isDark),
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.amber.withValues(alpha: 0.4)),
                  ),
                  child: Text('⚠️ $peakText', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.amber)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(isZh ? '📋 熄火結算報告列表' : '📋 Ride Summary Reports', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      if (_rideActive && _sessionCoSamples.length >= 3)
                        TextButton(
                          onPressed: _finishRideAndSaveReport,
                          child: Text(isZh ? '模擬熄火結算' : 'Test Flameout', style: const TextStyle(fontSize: 11)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: _savedReports.isEmpty
                        ? Center(
                            child: Text(
                              isZh ? '尚無報告，機車熄火後將自動產出並存檔！' : 'No reports yet. Auto-generated on flameout.',
                              style: const TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                          )
                        : ListView.separated(
                            itemCount: _savedReports.length,
                            separatorBuilder: (_, _) => const SizedBox(height: 8),
                            itemBuilder: (_, idx) {
                              final r = _savedReports[idx];
                              final avgCo = (r['avg_co_ppm'] ?? 0.0).toDouble();
                              final col = avgCo >= kCoDangerLimit
                                  ? Colors.red
                                  : (avgCo >= kCoWarnLimit ? Colors.amber : const Color(0xFF10B981));
                              return InkWell(
                                onTap: () => _showReportDialog(r),
                                borderRadius: BorderRadius.circular(12),
                                child: Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0)),
                                  ),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text('🏁 ${r['vehicle_id']} 騎乘結算', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                                          Text('歷時 ${r['duration_minutes']} 分 ｜ ${r['distance_km']} km', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                                        ],
                                      ),
                                      Column(
                                        crossAxisAlignment: CrossAxisAlignment.end,
                                        children: [
                                          Text('${r['avg_co_ppm']} ppm', style: TextStyle(fontWeight: FontWeight.w900, color: col)),
                                          Text('${r['rating']}', style: const TextStyle(fontSize: 10, color: Colors.grey)),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsTab(bool isDark) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(isZh ? '🎨 軟體背景色調設定' : '🎨 Appearance Theme', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _themeChoiceBtn('auto', isZh ? '☀️/🌙 系統自動' : 'Auto', widget.themeModePref == 'auto'),
                    const SizedBox(width: 8),
                    _themeChoiceBtn('light', isZh ? '🌞 手動明亮' : 'Light', widget.themeModePref == 'light'),
                    const SizedBox(width: 8),
                    _themeChoiceBtn('dark', isZh ? '🌙 手動深暗' : 'Dark', widget.themeModePref == 'dark'),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  widget.themeModePref == 'auto'
                      ? (isZh ? '目前為系統自動：白天明亮、黑夜深暗' : 'Auto: Day Light / Night Dark')
                      : (isZh ? '已手動鎖定色調，不再自動變換' : 'Locked manually'),
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
                const Divider(height: 28),

                Text(isZh ? '🖥️ 監控者後端伺服器 IP : Port' : '🖥️ Monitor Server IP:Port', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _ipController,
                        decoration: const InputDecoration(
                          isDense: true,
                          border: OutlineInputBorder(),
                          hintText: '192.168.36.132:8000',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () async {
                        final prefs = await SharedPreferences.getInstance();
                        final val = _ipController.text.trim();
                        await prefs.setString('server_addr', val);
                        setState(() => _serverAddress = val);
                        _showSnack(isZh ? '已儲存伺服器位址' : 'Server saved');
                      },
                      child: Text(isZh ? '儲存' : 'Save'),
                    ),
                  ],
                ),
                const Divider(height: 24),

                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(isZh ? '室內展覽模式 (模擬道路移動)' : 'Indoor Exhibition Mode', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                  subtitle: Text(isZh ? '關閉後將傳送手機真實 GPS 定位' : 'Off = send real phone GPS', style: const TextStyle(fontSize: 11)),
                  value: _indoorDemoMode,
                  onChanged: (v) async {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setBool('indoor_demo', v);
                    setState(() => _indoorDemoMode = v);
                  },
                ),

                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(isZh ? '背景超標警報通知 (CO ≥ 31.0 ppm)' : 'Background Danger Alert', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                  value: _notifyEnabled,
                  onChanged: (v) async {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setBool('notify_enabled', v);
                    setState(() => _notifyEnabled = v);
                  },
                ),

                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(isZh ? '🌐 語言設定 (Language)' : '🌐 Language', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                  trailing: OutlinedButton(
                    onPressed: widget.onToggleLang,
                    child: Text(isZh ? '切換至 English' : '切換至 繁體中文'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _themeChoiceBtn(String mode, String label, bool selected) {
    return Expanded(
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          backgroundColor: selected ? const Color(0xFF10B981).withValues(alpha: 0.15) : null,
          side: BorderSide(color: selected ? const Color(0xFF10B981) : Colors.grey.shade600),
          padding: const EdgeInsets.symmetric(vertical: 10),
        ),
        onPressed: () => widget.onChangeTheme(mode),
        child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: selected ? const Color(0xFF10B981) : null)),
      ),
    );
  }

  Widget _buildDangerFullOverlay() {
    return Positioned.fill(
      child: Container(
        color: const Color(0xFF7F1D1D).withValues(alpha: 0.94),
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 84),
            const SizedBox(height: 16),
            Text(
              isZh ? '排放異常危險警示' : 'HAZARDOUS EMISSION ALERT',
              style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w900),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Text(
              '${_coPpm.toStringAsFixed(1)} ppm',
              style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 58, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 16),
            Text(
              isZh ? '一氧化碳濃度超過 31.0 ppm 法定標準！\n請保持通風並檢查過濾裝置。' : 'CO exceeded 31.0 ppm legal threshold!',
              style: const TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 36),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(30),
                border: Border.all(color: Colors.redAccent),
              ),
              child: Text(
                isZh ? '🛑 騎行安全保護：濃度恢復正常後自動關閉' : '🛑 Auto-dismisses when normalized',
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showReportDialog(Map<String, dynamic> r) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isZh ? '🏁 騎行過程污染結算報告' : '🏁 Ride Emission Report', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${isZh ? '車輛' : 'Vehicle'}: ${r['vehicle_id']}'),
            Text('${isZh ? '歷時' : 'Duration'}: ${r['duration_minutes']} 分 ｜ ${r['distance_km']} km'),
            const Divider(),
            Text('${isZh ? '全程平均 CO' : 'Avg CO'}: ${r['avg_co_ppm']} ppm', style: const TextStyle(fontWeight: FontWeight.bold)),
            Text('${isZh ? '最高 CO 峰值' : 'Peak CO'}: ${r['max_co_ppm']} ppm', style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
            Text('${isZh ? '超標危險秒數' : 'Danger Time'}: ${r['danger_seconds'] ?? 0} 秒'),
            Text('${isZh ? '全程平均 PM2.5' : 'Avg PM2.5'}: ${r['avg_pm25']} µg/m³'),
            const SizedBox(height: 8),
            Text('${isZh ? '過濾評定' : 'Rating'}: 🌱 ${r['rating']}', style: const TextStyle(color: Color(0xFF10B981), fontWeight: FontWeight.bold)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              SharePlus.instance.share(
                ShareParams(text: jsonEncode(r), subject: 'AirRide_Report_${r['vehicle_id']}.json'),
              );
            },
            child: Text(isZh ? '📤 匯出 JSON' : 'Export JSON'),
          ),
          FilledButton(
            onPressed: () {
              final text = '🏍️ AirRide 騎乘污染結算\n車輛: ${r['vehicle_id']}\n里程: ${r['distance_km']} km\n平均 CO: ${r['avg_co_ppm']} ppm\n最高峰值: ${r['max_co_ppm']} ppm\n評定: ${r['rating']}';
              SharePlus.instance.share(ShareParams(text: text));
            },
            child: Text(isZh ? '🔗 分享報告' : 'Share'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(isZh ? '關閉' : 'Close'),
          ),
        ],
      ),
    );
  }
}

// ================= 自訂高效能繪圖元件 =================
class _CoGaugePainter extends CustomPainter {
  final double value;
  final double maxValue;
  final Color activeColor;
  final Color trackColor;

  _CoGaugePainter({required this.value, required this.maxValue, required this.activeColor, required this.trackColor});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 12;
    const startAngle = math.pi * 0.75;
    const sweepTotal = math.pi * 1.5;

    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius), startAngle, sweepTotal, false, trackPaint);

    final ratio = (value / maxValue).clamp(0.0, 1.0);
    final activePaint = Paint()
      ..color = activeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius), startAngle, sweepTotal * ratio, false, activePaint);
  }

  @override
  bool shouldRepaint(covariant _CoGaugePainter old) => old.value != value || old.activeColor != activeColor;
}

class _SparklinePainter extends CustomPainter {
  final List<double> points;
  final Color lineColor;
  final Color gridColor;

  _SparklinePainter({required this.points, required this.lineColor, required this.gridColor});

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()..color = gridColor..strokeWidth = 1;
    canvas.drawLine(Offset(0, size.height * 0.3), Offset(size.width, size.height * 0.3), gridPaint);
    canvas.drawLine(Offset(0, size.height * 0.8), Offset(size.width, size.height * 0.8), gridPaint);

    if (points.length < 2) return;
    final path = Path();
    final stepX = size.width / (points.length - 1);
    for (int i = 0; i < points.length; i++) {
      final x = i * stepX;
      final y = size.height - ((points[i] / 45.0).clamp(0.0, 1.0) * size.height);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    final paint = Paint()
      ..color = lineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) => true;
}

class _BarChartPainter extends CustomPainter {
  final List<String> labels;
  final List<double> values;
  final bool isDark;

  _BarChartPainter({required this.labels, required this.values, required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final maxVal = values.reduce(math.max) * 1.15;
    final slotW = size.width / values.length;
    final barW = slotW * 0.48;

    for (int i = 0; i < values.length; i++) {
      final h = (values[i] / maxVal) * (size.height - 20);
      final left = i * slotW + (slotW - barW) / 2;
      final top = size.height - 18 - h;
      final col = values[i] >= 15 ? Colors.amber : const Color(0xFF10B981);
      final paint = Paint()..color = col;
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(left, top, barW, h), const Radius.circular(5)), paint);

      final tp = TextPainter(
        text: TextSpan(text: labels[i], style: TextStyle(fontSize: 10, color: isDark ? Colors.white60 : Colors.black54)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(left + (barW - tp.width) / 2, size.height - 14));
    }
  }

  @override
  bool shouldRepaint(covariant _BarChartPainter old) => true;
}

class _RadarTrailPainter extends CustomPainter {
  final List<Offset> trail;
  final String status;
  final String cityLabel;
  final bool isDark;

  _RadarTrailPainter({required this.trail, required this.status, required this.cityLabel, required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()..color = isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0)..strokeWidth = 1;
    for (int i = 1; i <= 4; i++) {
      canvas.drawCircle(Offset(size.width / 2, size.height / 2), (size.shortestSide / 2) * (i / 4), gridPaint..style = PaintingStyle.stroke);
    }

    final tp = TextPainter(
      text: TextSpan(text: cityLabel, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF38BDF8))),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, const Offset(8, 8));

    if (trail.length > 1) {
      final path = Path();
      for (int i = 0; i < trail.length; i++) {
        final px = (trail[i].dx.clamp(0.1, 0.9)) * size.width;
        final py = (trail[i].dy.clamp(0.1, 0.9)) * size.height;
        if (i == 0) {
          path.moveTo(px, py);
        } else {
          path.lineTo(px, py);
        }
      }
      canvas.drawPath(path, Paint()..color = const Color(0xFF06B6D4)..style = PaintingStyle.stroke..strokeWidth = 3);
    }

    final dotPos = trail.isNotEmpty
        ? Offset(trail.last.dx.clamp(0.1, 0.9) * size.width, trail.last.dy.clamp(0.1, 0.9) * size.height)
        : Offset(size.width / 2, size.height / 2);
    final dotColor = status == 'danger' ? Colors.red : (status == 'warning' ? Colors.amber : const Color(0xFF10B981));
    canvas.drawCircle(dotPos, 10, Paint()..color = dotColor);
    canvas.drawCircle(dotPos, 10, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 2.5);
  }

  @override
  bool shouldRepaint(covariant _RadarTrailPainter old) => true;
}