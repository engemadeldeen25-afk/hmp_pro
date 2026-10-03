import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:http/http.dart' as http;

import 'models/models.dart';
import 'services/storage_service.dart';
import 'services/ble_service.dart';
import 'services/gps_service.dart';
import 'services/voice_service.dart';
import 'services/units_service.dart';
import 'widgets/magic_eye.dart';
import 'screens/user_profile_page.dart';
import 'screens/project_settings_page.dart';
import 'screens/drop_settings_page.dart';
import 'screens/measurement_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Color(0xFF0A0E1A),
    statusBarIconBrightness: Brightness.light,
  ));
  FlutterError.onError = (d) => print('Flutter error: ${d.exception}');
  runApp(const HmpProApp());
}

class HmpProApp extends StatelessWidget {
  const HmpProApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HMP PRO',
      debugShowCheckedModeBanner: false,
           theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00FFFF),
          secondary: Color(0xFF42A5F5),
          surface: Color(0xFF0D1B2A),
          onPrimary: Color(0xFF000000),
          onSurface: Color(0xFFFFFFFF),
        ),
        scaffoldBackgroundColor: const Color(0xFF000000),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF000000),
          elevation: 0,
          titleTextStyle: TextStyle(
            color: Color(0xFFFFFFFF),
            fontSize: 20,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.5,
          ),
        ),
        textTheme: const TextTheme(
          bodyLarge: TextStyle(
            color: Color(0xFFFFFFFF),
            fontWeight: FontWeight.w600,
          ),
          bodyMedium: TextStyle(
            color: Color(0xFFE0E0E0),
            fontWeight: FontWeight.w500,
          ),
          titleLarge: TextStyle(
            color: Color(0xFFFFFFFF),
            fontWeight: FontWeight.w900,
          ),
        ),
        iconTheme: const IconThemeData(
          color: Color(0xFFFFFFFF),
          size: 28,
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF0D1B2A),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF20344B), width: 1.5),
          ),
        ),
      ),
      home: const SplashScreen(child: HomePage()),
    );
  }
}

class SplashScreen extends StatefulWidget {
  final Widget child;
  const SplashScreen({super.key, required this.child});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    Timer(const Duration(seconds: 2), () {
      if (mounted) {
        Navigator.of(context).pushReplacement(
          PageRouteBuilder(
            pageBuilder: (_, __, ___) => widget.child,
            transitionsBuilder: (_, anim, __, c) =>
                FadeTransition(opacity: anim, child: c),
            transitionDuration: const Duration(milliseconds: 400),
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(30),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    const Color(0xFF00E5FF).withOpacity(0.3),
                    const Color(0xFF00E5FF).withOpacity(0.05),
                  ],
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF00E5FF).withOpacity(0.3),
                    blurRadius: 40,
                    spreadRadius: 5,
                  ),
                ],
              ),
                   child: Image.asset(
                'assets/icon/logo_v3.png',
                width: 140,
                height: 140,
                errorBuilder: (_, __, ___) => const Icon(
                  Icons.speed,
                  color: Color(0xFF00E5FF),
                  size: 120,
                ),
              ),
            ),
            const SizedBox(height: 30),
            const Text(
              'HMP PRO',
              style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold,
                letterSpacing: 4,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Industrial LWD System',
              style: TextStyle(
                color: Color(0xFF00E5FF),
                fontSize: 12,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 40),
            const SizedBox(
              width: 40,
              height: 40,
              child: CircularProgressIndicator(
                color: Color(0xFF00E5FF),
                strokeWidth: 2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _storage = StorageService();
  final _ble = BleService();
  final _gps = GpsService();
  final _voice = VoiceService();
  final _battery = Battery();

  UserProfile _profile = UserProfile();
  List<Site> _sites = [];
  String _activeSiteId = '';
  String _activeJobId = '';
  String _activeLocationId = '';
  DropSettings _dropSettings = DropSettings();
  Calibration _calibration = Calibration();

  bool _gpsRecordingEnabled = true;
  bool _voiceEnabled = true;
  MagicEyeState _eyeState = MagicEyeState.off;
  int _batteryLevel = -1;
  bool _batteryCharging = false;
  DateTime _now = DateTime.now();
  String _weather = '';

  StreamSubscription? _bleConnSub;
  StreamSubscription? _gpsSub;

  double _lastEvd = 0;
  double _lastDef = 0;
  double _lastAcc = 0;
  double _lastVel = 0;

  Timer? _clockTimer;
  Timer? _batteryTimer;
  String? _errorMessage;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _init();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    _batteryTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _refreshBattery();
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _batteryTimer?.cancel();
    _bleConnSub?.cancel();
    _gpsSub?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      await [
        Permission.location,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.camera,
      ].request();

      try {
        await _voice.init();
      } catch (_) {}

      try {
        _profile = await _storage.loadProfile();
        _sites = await _storage.loadSites();
        final active = await _storage.loadActive();
        _activeSiteId = active['siteId'] ?? '';
        _activeJobId = active['jobId'] ?? '';
        _activeLocationId = active['locationId'] ?? '';
        _dropSettings = await _storage.loadDropSettings();
        _calibration = await _storage.loadCalibration();
        _gpsRecordingEnabled = await _storage.loadGpsRecordingEnabled();
        _voiceEnabled = await _storage.loadVoiceEnabled();
        _voice.setEnabled(_voiceEnabled);
        UnitsService.setSystem(
            _profile.useMetric ? UnitsService.METRIC : UnitsService.SI);
      } catch (e) {
        print('Storage error: $e');
      }

      try {
        if (_gpsRecordingEnabled) _gps.start();
        _gpsSub = _gps.positionStream.listen((_) {
          if (mounted) setState(() {});
        });
      } catch (e) {
        print('GPS error: $e');
      }

      _refreshBattery();
      _fetchWeather();

      try {
        _bleConnSub = _ble.connectionStream.listen((connected) {
          if (!mounted) return;
          setState(() {
            _eyeState = connected
                ? (_eyeState == MagicEyeState.green
                    ? MagicEyeState.green
                    : MagicEyeState.blue)
                : MagicEyeState.red;
          });
        });
        _ble.dataStream.listen((m) {
          final type = m['type'] as String?;
          if (type == 'hb') return;
          setState(() {
            _lastEvd = (m['evd'] ?? 0).toDouble() * _calibration.factor;
            _lastDef = (m['def'] ?? 0).toDouble();
            _lastAcc = (m['acc'] ?? 0).toDouble();
            _lastVel = (m['vel'] ?? 0).toDouble();
          });
        });
      } catch (e) {
        print('BLE error: $e');
      }

      if (mounted) {
        setState(() {
          _initialized = true;
          _eyeState = MagicEyeState.red;
        });
      }
    } catch (e) {
      print('FATAL: $e');
      if (mounted) setState(() => _errorMessage = 'Error: $e');
    }
  }

  Future<void> _refreshBattery() async {
    try {
      final l = await _battery.batteryLevel;
      final s = await _battery.batteryState;
      if (!mounted) return;
      setState(() {
        _batteryLevel = l;
        _batteryCharging =
            s == BatteryState.charging || s == BatteryState.full;
      });
    } catch (_) {}
  }

  Future<void> _fetchWeather() async {
    try {
      final pos = _gps.current;
      if (pos == null) return;
      final url = Uri.parse(
          'https://wttr.in/${pos.latitude},${pos.longitude}?format=%C+%t');
      final res =
          await http.get(url).timeout(const Duration(seconds: 5));
      if (res.statusCode == 200 && mounted) {
        setState(() => _weather = res.body.trim());
      }
    } catch (_) {}
  }

  Site? get _activeSite =>
      _sites.firstWhereOrNull((s) => s.id == _activeSiteId);
  Job? get _activeJob =>
      _activeSite?.jobs.firstWhereOrNull((j) => j.id == _activeJobId);
  Location? get _activeLocation =>
      _activeJob?.locations.firstWhereOrNull((l) => l.id == _activeLocationId);

  TestGroup? get _lastCompletedGroup {
    final loc = _activeLocation;
    if (loc == null || loc.testGroups.isEmpty) return null;
    return loc.testGroups.last;
  }

  @override
  Widget build(BuildContext context) {
    if (_errorMessage != null) {
      return Scaffold(
        backgroundColor: const Color(0xFF0A0E1A),
        body: Center(
          child: Text(_errorMessage!,
              style: const TextStyle(color: Colors.redAccent)),
        ),
      );
    }

    if (!_initialized) {
      return const Scaffold(
        backgroundColor: Color(0xFF0A0E1A),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF00E5FF)),
        ),
      );
    }

    return Scaffold(
      drawer: _buildSettingsDrawer(),
      body: SafeArea(
        child: Column(
          children: [
            _buildUpperZone(),
            Expanded(child: _buildCentralZone()),
            _buildLowerZone(),
          ],
        ),
      ),
    );
  }

  Widget _buildUpperZone() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0xFF0A0E1A),
        border: Border(bottom: BorderSide(color: Color(0xFF1A2540))),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Builder(
                builder: (ctx) => IconButton(
                  icon: const Icon(Icons.menu, color: Color(0xFF00E5FF)),
                  onPressed: () => Scaffold.of(ctx).openDrawer(),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(DateFormat('EEEE, MMM d, yyyy').format(_now),
                        style: TextStyle(
                            color: Colors.grey.shade400, fontSize: 11)),
                    Text(DateFormat('HH:mm:ss').format(_now),
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'monospace')),
                  ],
                ),
              ),
              if (_ble.isConnected && _batteryLevel >= 0)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF151B2E),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: _batteryLevel > 20
                            ? Colors.greenAccent
                            : Colors.redAccent),
                  ),
                  child: Row(
                    children: [
                      Icon(
                          _batteryCharging
                              ? Icons.battery_charging_full
                              : Icons.battery_full,
                          color: _batteryLevel > 20
                              ? Colors.greenAccent
                              : Colors.redAccent,
                          size: 14),
                      const SizedBox(width: 4),
                      Text('$_batteryLevel%',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF151B2E),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF2A3654)),
            ),
            child: Row(
              children: [
                Icon(
                    _ble.isConnected
                        ? Icons.bluetooth_connected
                        : Icons.bluetooth_disabled,
                    color: _ble.isConnected
                        ? Colors.greenAccent
                        : Colors.redAccent,
                    size: 14),
                const SizedBox(width: 6),
                Text(_ble.isConnected ? 'Connected' : 'Disconnected',
                    style: TextStyle(
                        fontSize: 10,
                        color: _ble.isConnected
                            ? Colors.greenAccent
                            : Colors.redAccent,
                        fontWeight: FontWeight.bold)),
                const Spacer(),
                if (_weather.isNotEmpty)
                  Text(_weather,
                      style: TextStyle(
                          color: Colors.grey.shade400, fontSize: 10)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCentralZone() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          _buildProjectStatusCard(),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                  child: _actionButton(
                      icon: Icons.business,
                      label: 'Project\nSettings',
                      color: const Color(0xFF1E88E5),
                      onTap: _openProjectSettings)),
              const SizedBox(width: 8),
              Expanded(
                  child: _actionButton(
                      icon: Icons.tune,
                      label: 'Test\nSettings',
                      color: Colors.amber.shade700,
                      onTap: _openDropSettings)),
              const SizedBox(width: 8),
              Expanded(
                  child: _actionButton(
                      icon: Icons.location_on,
                      label: 'GPS',
                      color: Colors.purpleAccent.shade700,
                      onTap: _showGpsInfo)),
              const SizedBox(width: 8),
              Expanded(
                  child: _actionButton(
                      icon: _gpsRecordingEnabled
                          ? Icons.gps_fixed
                          : Icons.gps_off,
                      label: _gpsRecordingEnabled ? 'GPS ON' : 'GPS OFF',
                      color: _gpsRecordingEnabled
                          ? Colors.green.shade700
                          : Colors.grey.shade700,
                      onTap: _toggleGpsRecording)),
            ],
          ),
          const SizedBox(height: 12),
          _buildLiveCard(),
          const SizedBox(height: 10),
          _buildLastGroupMeansCard(),
          const SizedBox(height: 10),
          _buildEyeCard(),
        ],
      ),
    );
  }

  Widget _buildProjectStatusCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            colors: [Color(0xFF151B2E), Color(0xFF1E2740)]),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF2A3654)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('ACTIVE PROJECT',
              style: TextStyle(
                  color: Colors.grey,
                  fontSize: 10,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          _statusRow('Site', _activeSite?.name ?? 'None'),
          _statusRow('Job', _activeJob?.name ?? 'None'),
          _statusRow('Location', _activeLocation?.name ?? 'None'),
          _statusRow(
              'Groups',
              _activeLocation == null
                  ? '—'
                  : '${_activeLocation!.testGroups.length}'),
        ],
      ),
    );
  }

  Widget _statusRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(label,
                style:
                    TextStyle(color: Colors.grey.shade500, fontSize: 11)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        decoration: BoxDecoration(
          gradient: LinearGradient(
              colors: [color.withOpacity(0.25), color.withOpacity(0.1)]),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.6), width: 1.2),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 6),
            Text(label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    height: 1.2)),
          ],
        ),
      ),
    );
  }

  Widget _buildLiveCard() {
    final passed = _lastEvd >= _dropSettings.targetEvd;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            colors: [Color(0xFF151B2E), Color(0xFF1E2740)]),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: passed
                ? Colors.green.withOpacity(0.4)
                : const Color(0xFF2A3654)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('EVD',
                  style: TextStyle(
                      color: Colors.grey.shade500,
                      fontSize: 10,
                      letterSpacing: 1.5)),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(UnitsService.evd(_lastEvd).toStringAsFixed(1),
                      style: const TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF00E5FF),
                          fontFamily: 'monospace')),
                  const SizedBox(width: 4),
                  Text(UnitsService.evdUnit(),
                      style: TextStyle(
                          color: Colors.grey.shade500, fontSize: 12)),
                ],
              ),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('DEFL',
                  style: TextStyle(
                      color: Colors.grey.shade500,
                      fontSize: 10,
                      letterSpacing: 1.5)),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(UnitsService.deflection(_lastDef).toStringAsFixed(2),
                      style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.orangeAccent,
                          fontFamily: 'monospace')),
                  const SizedBox(width: 4),
                  Text(UnitsService.deflectionUnit(),
                      style: TextStyle(
                          color: Colors.grey.shade500, fontSize: 10)),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(UnitsService.velocity(_lastVel).toStringAsFixed(2),
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.greenAccent,
                          fontFamily: 'monospace')),
                  const SizedBox(width: 4),
                  Text(UnitsService.velocityUnit(),
                      style: TextStyle(
                          color: Colors.grey.shade500, fontSize: 9)),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLastGroupMeansCard() {
    final group = _lastCompletedGroup;

    if (group == null) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF151B2E),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF2A3654)),
        ),
        child: Column(
          children: [
            Icon(Icons.analytics_outlined,
                color: Colors.grey.shade700, size: 32),
            const SizedBox(height: 8),
            Text('No test completed yet',
                style:
                    TextStyle(color: Colors.grey.shade600, fontSize: 12)),
          ],
        ),
      );
    }

    final passed = group.avgEvd >= _dropSettings.targetEvd;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: passed
              ? [
                  Colors.green.shade900.withOpacity(0.4),
                  Colors.green.shade900.withOpacity(0.05),
                ]
              : [
                  Colors.red.shade900.withOpacity(0.4),
                  Colors.red.shade900.withOpacity(0.05),
                ],
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: passed ? Colors.greenAccent : Colors.redAccent,
            width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(passed ? Icons.verified : Icons.cancel,
                  color: passed ? Colors.greenAccent : Colors.redAccent,
                  size: 18),
              const SizedBox(width: 6),
              Text(passed ? 'VALID TEST' : 'INVALID TEST',
                  style: TextStyle(
                      color:
                          passed ? Colors.greenAccent : Colors.redAccent,
                      fontSize: 12,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.bold)),
              const Spacer(),
              Text(DateFormat('HH:mm:ss').format(group.time),
                  style: TextStyle(
                      color: Colors.grey.shade400, fontSize: 10)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _meanMetric(
                  'EVD MEAN',
                  UnitsService.evd(group.avgEvd).toStringAsFixed(1),
                  UnitsService.evdUnit(),
                  const Color(0xFF00E5FF),
                ),
              ),
              Expanded(
                child: _meanMetric(
                  'S MEAN',
                  UnitsService.deflection(group.avgDeflection)
                      .toStringAsFixed(2),
                  UnitsService.deflectionUnit(),
                  Colors.orangeAccent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _meanMetric(
                  'DEFL MEAN',
                  UnitsService.deflection(group.avgDeflection)
                      .toStringAsFixed(2),
                  UnitsService.deflectionUnit(),
                  Colors.purpleAccent,
                ),
              ),
              Expanded(
                child: _meanMetric(
                  'S/V MAX',
                  group.maxSOverV.toStringAsFixed(3),
                  'mm·s/m',
                  Colors.greenAccent,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _meanMetric(String label, String value, String unit, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                color: Colors.grey.shade500,
                fontSize: 9,
                letterSpacing: 1)),
        const SizedBox(height: 3),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(value,
                style: TextStyle(
                    color: color,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace')),
            const SizedBox(width: 3),
            Text(unit,
                style:
                    TextStyle(color: Colors.grey.shade600, fontSize: 9)),
          ],
        ),
      ],
    );
  }

  Widget _buildEyeCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF151B2E),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF2A3654)),
      ),
      child: Row(
        children: [
          MagicEye(state: _eyeState, size: 50),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('MAGIC EYE',
                    style: TextStyle(
                        color: Colors.grey,
                        fontSize: 10,
                        letterSpacing: 1.5,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(_eyeStateText(),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _eyeStateText() {
    switch (_eyeState) {
      case MagicEyeState.off:
        return 'System Off';
      case MagicEyeState.selfTest:
        return 'Running Self-Test...';
      case MagicEyeState.red:
        return 'Not Connected';
      case MagicEyeState.blue:
        return 'Connected - Ready';
      case MagicEyeState.green:
        return 'Recording...';
    }
  }

  Widget _buildLowerZone() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        color: Color(0xFF0A0E1A),
        border: Border(top: BorderSide(color: Color(0xFF1A2540))),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _ble.isConnected ? null : _connectDevice,
                  icon: Icon(
                      _ble.isConnected
                          ? Icons.bluetooth_connected
                          : Icons.bluetooth,
                      size: 18),
                  label:
                      Text(_ble.isConnected ? 'CONNECTED' : 'CONNECT'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _ble.isConnected
                        ? Colors.green.shade800
                        : Colors.red.shade800,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: Icon(
                    _voiceEnabled ? Icons.volume_up : Icons.volume_off,
                    color: _voiceEnabled
                        ? const Color(0xFF00E5FF)
                        : Colors.grey),
                onPressed: _toggleVoice,
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xFF151B2E),
                  padding: const EdgeInsets.all(10),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _ble.isConnected ? _startMeasurement : null,
              icon: const Icon(Icons.play_arrow, size: 22),
              label: const Text('START TEST',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00E5FF),
                foregroundColor: const Color(0xFF0A0E1A),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsDrawer() {
    return Drawer(
      backgroundColor: const Color(0xFF0A0E1A),
      child: SafeArea(
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              width: double.infinity,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                    colors: [Color(0xFF1E88E5), Color(0xFF00E5FF)]),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.speed, size: 40, color: Colors.white),
                  const SizedBox(height: 8),
                  const Text('HMP PRO',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 2)),
                  Text(
                      _profile.companyName.isEmpty
                          ? 'Settings Menu'
                          : _profile.companyName,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 12)),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  _drawerItem(Icons.home, 'Home',
                      () => Navigator.pop(context)),
                  _drawerItem(Icons.person, 'User Profile', () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => UserProfilePage(
                                profile: _profile,
                                onSave: _saveProfile,
                                onDelete: _deleteProfile,
                              )),
                    );
                  }),
                  _drawerItem(Icons.business, 'Project Settings', () {
                    Navigator.pop(context);
                    _openProjectSettings();
                  }),
                  _drawerItem(Icons.tune, 'Drop Settings', () {
                    Navigator.pop(context);
                    _openDropSettings();
                  }),
                  const Divider(color: Color(0xFF2A3654)),
                  _drawerItem(Icons.phone, 'Contact', () {
                    Navigator.pop(context);
                    _showContactDialog();
                  }),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _drawerItem(IconData icon, String title, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon, color: const Color(0xFF00E5FF)),
      title: Text(title,
          style: const TextStyle(color: Colors.white, fontSize: 14)),
      onTap: onTap,
    );
  }

  Future<void> _saveProfile(UserProfile p) async {
    await _storage.saveProfile(p);
    UnitsService.setSystem(
        p.useMetric ? UnitsService.METRIC : UnitsService.SI);
    setState(() => _profile = p);
    _snack('User profile saved successfully');
  }

  Future<void> _deleteProfile() async {
    await _storage.deleteProfile();
    setState(() => _profile = UserProfile());
    _snack('Profile deleted');
  }

  Future<void> _toggleGpsRecording() async {
    final newVal = !_gpsRecordingEnabled;
    setState(() => _gpsRecordingEnabled = newVal);
    await _storage.saveGpsRecordingEnabled(newVal);
    if (newVal) {
      _gps.start();
    } else {
      _gps.stop();
    }
  }

  Future<void> _toggleVoice() async {
    final newVal = !_voiceEnabled;
    setState(() => _voiceEnabled = newVal);
    _voice.setEnabled(newVal);
    await _storage.saveVoiceEnabled(newVal);
  }

  Future<void> _connectDevice() async {
    _voice.say('Connecting');
    setState(() => _eyeState = MagicEyeState.selfTest);
    final ok = await _ble.scanAndConnect();
    if (!mounted) return;
    setState(() =>
        _eyeState = ok ? MagicEyeState.blue : MagicEyeState.red);
    _voice.say(ok ? 'Connected' : 'Connection failed');
  }

  Future<void> _startMeasurement() async {
    final loc = _activeLocation;
    if (loc == null) {
      _snack('Please select a Location first');
      return;
    }
    _voice.say('Ready for preload 1');
    setState(() => _eyeState = MagicEyeState.green);
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MeasurementPage(
          ble: _ble,
          gps: _gps,
          voice: _voice,
          storage: _storage,
          dropSettings: _dropSettings,
          calibration: _calibration,
          site: _activeSite!,
          job: _activeJob!,
          location: loc,
          profile: _profile,
          gpsRecordingEnabled: _gpsRecordingEnabled,
          onComplete: _saveSitesAndActive,
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _eyeState = MagicEyeState.blue);
  }

  Future<void> _saveSitesAndActive() async {
    await _storage.saveSites(_sites);
    await _storage
        .saveActive(_activeSiteId, _activeJobId, _activeLocationId);
    if (mounted) setState(() {});
  }

  void _openProjectSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ProjectSettingsPage(
          sites: _sites,
          activeSiteId: _activeSiteId,
          activeJobId: _activeJobId,
          activeLocationId: _activeLocationId,
          profile: _profile,
          onChanged: (sites, sId, jId, lId) async {
            setState(() {
              _sites = sites;
              _activeSiteId = sId;
              _activeJobId = jId;
              _activeLocationId = lId;
            });
            await _saveSitesAndActive();
          },
        ),
      ),
    );
  }

  void _openDropSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DropSettingsPage(
          settings: _dropSettings,
          calibration: _calibration,
          password: '2841998',
          onSave: (s, c) async {
            setState(() {
              _dropSettings = s;
              _calibration = c;
            });
            await _storage.saveDropSettings(s);
            await _storage.saveCalibration(c);
          },
        ),
      ),
    );
  }

  void _showGpsInfo() {
    final pos = _gps.current;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF151B2E),
        title: const Text('GPS Coordinates'),
        content: pos == null
            ? const Text('GPS not ready. Move outdoors.')
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Lat: ${pos.latitude.toStringAsFixed(6)}',
                      style: const TextStyle(
                          color: Colors.white, fontFamily: 'monospace')),
                  Text('Lng: ${pos.longitude.toStringAsFixed(6)}',
                      style: const TextStyle(
                          color: Colors.white, fontFamily: 'monospace')),
                  Text('Accuracy: ±${pos.accuracy.toStringAsFixed(1)} m',
                      style: const TextStyle(color: Colors.white70)),
                ],
              ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close')),
        ],
      ),
    );
  }

  void _showContactDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF151B2E),
        title: const Text('Contact & Support'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('📞 01148221872',
                style: TextStyle(color: Colors.white)),
            SizedBox(height: 8),
            Text('✉️ eng.emadeldeen23@gmail.com',
                style: TextStyle(color: Colors.white)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close')),
        ],
      ),
    );
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), duration: const Duration(seconds: 2)),
    );
  }
}

extension FirstWhereOrNull<E> on List<E> {
  E? firstWhereOrNull(bool Function(E) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}