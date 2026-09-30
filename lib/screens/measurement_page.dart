import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../models/models.dart';
import '../services/ble_service.dart';
import '../services/gps_service.dart';
import '../services/voice_service.dart';
import '../services/storage_service.dart';
import '../services/units_service.dart';
import '../widgets/magic_eye.dart';

enum MeasurementStage {
  idle,
  readyPreload,
  collectingPreload,
  readyTest,
  collectingTest,
  complete,
}

class MeasurementPage extends StatefulWidget {
  final BleService ble;
  final GpsService gps;
  final VoiceService voice;
  final StorageService storage;
  final DropSettings dropSettings;
  final Calibration calibration;
  final Site site;
  final Job job;
  final Location location;
  final UserProfile profile;
  final bool gpsRecordingEnabled;
  final Future<void> Function() onComplete;

  const MeasurementPage({
    super.key,
    required this.ble,
    required this.gps,
    required this.voice,
    required this.storage,
    required this.dropSettings,
    required this.calibration,
    required this.site,
    required this.job,
    required this.location,
    required this.profile,
    required this.gpsRecordingEnabled,
    required this.onComplete,
  });

  @override
  State<MeasurementPage> createState() => _MeasurementPageState();
}

class _MeasurementPageState extends State<MeasurementPage> {
  static const int _preloadCount = 3;
  static const int _testCount = 3;

  // Threshold: 20% of peak — keeps only the impact window
  static const double _trimThreshold = 0.20;

  late Location _location;

  MeasurementStage _stage = MeasurementStage.idle;
  int _preloadIndex = 0;
  int _testIndex = 0;

  double _currentEvd = 0;
  double _currentDef = 0;
  double _currentAcc = 0;
  double _currentVel = 0;
  bool _hasCurrentReading = false;

  final List<Drop> _testDrops = [];
  double _avgEvd = 0;
  bool _testValid = false;

  StreamSubscription? _dataSub;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _location = widget.location;
    _dataSub = widget.ble.dataStream.listen(_onData);
    _enableWakelock();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.voice.say('Ready for preload 1');
      _beginPreload();
    });
  }

  Future<void> _enableWakelock() async {
    try {
      await WakelockPlus.enable();
    } catch (_) {}
  }

  Future<void> _disableWakelock() async {
    try {
      await WakelockPlus.disable();
    } catch (_) {}
  }

  @override
  void dispose() {
    _dataSub?.cancel();
    _disableWakelock();
    super.dispose();
  }

  void _onData(Map<String, dynamic> m) {
    if (!mounted) return;
    final type = m['type'] as String?;
    if (type == 'hb') return;

    final evd = (m['evd'] ?? 0).toDouble() * widget.calibration.factor;
    final def = (m['def'] ?? 0).toDouble();
    final acc = (m['acc'] ?? 0).toDouble();
    final vel = (m['vel'] ?? 0).toDouble();

    setState(() {
      _currentEvd = evd;
      _currentDef = def;
      _currentAcc = acc;
      _currentVel = vel;
      _hasCurrentReading = true;
    });

    if ((_stage == MeasurementStage.collectingPreload ||
            _stage == MeasurementStage.collectingTest) &&
        def > 0.005 &&
        !_busy) {
      _captureDrop(
        isPreload: _stage == MeasurementStage.collectingPreload,
        m: m,
      );
    }
  }

  Future<void> _captureDrop({
    required bool isPreload,
    required Map<String, dynamic> m,
  }) async {
    if (_busy) return;
    _busy = true;

    List<double> curveT = [];
    List<double> curveD = [];
    List<double> curveV = [];

    try {
      if (m['ct'] != null) {
        curveT =
            (m['ct'] as List).map((v) => (v as num).toDouble()).toList();
      }
    } catch (_) {}
    try {
      if (m['cd'] != null) {
        curveD =
            (m['cd'] as List).map((v) => (v as num).toDouble()).toList();
      }
    } catch (_) {}
    try {
      if (m['cv'] != null) {
        curveV =
            (m['cv'] as List).map((v) => (v as num).toDouble()).toList();
      }
    } catch (_) {}

    if (curveD.isEmpty) {
      curveD = [0, _currentDef * 0.5, _currentDef, _currentDef * 0.7, 0];
      curveT = [0, 100, 200, 300, 400];
    }
    if (curveV.isEmpty && curveD.isNotEmpty) {
      curveV = List.filled(curveD.length, _currentVel);
    }

    if (!isPreload) {
      final drop = Drop(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        time: DateTime.now(),
        dropNumber: _testDrops.length + 1,
        evd: _currentEvd,
        deflection: _currentDef,
        acceleration: _currentAcc,
        velocity: _currentVel,
        settlementCurve: curveD,
        velocityCurve: curveV,
        impactTimeCurve: curveT,
      );
      _testDrops.add(drop);
    }

    HapticFeedback.mediumImpact();

    if (isPreload) {
      setState(() => _stage = MeasurementStage.idle);
      widget.voice.say('Preload ${_preloadIndex + 1} complete');
      _preloadIndex++;

      if (_preloadIndex >= _preloadCount) {
        widget.voice.say('Preloads complete. Ready for first test');
        await Future.delayed(const Duration(seconds: 2));
        if (mounted) _beginTest();
      } else {
        await Future.delayed(const Duration(seconds: 1));
        if (mounted) _beginPreload();
      }
    } else {
      setState(() => _stage = MeasurementStage.idle);
      widget.voice.say('Test ${_testIndex + 1} complete');
      _testIndex++;

      if (_testIndex >= _testCount) {
        _avgEvd = _testDrops.map((d) => d.evd).reduce((a, b) => a + b) /
            _testDrops.length;
        _testValid = _avgEvd >= widget.dropSettings.targetEvd;

        setState(() => _stage = MeasurementStage.complete);

        if (_testValid) {
          widget.voice.say('Successful test');
        } else {
          widget.voice.say('Fail test');
        }

        await _saveGroup();
        await Future.delayed(const Duration(seconds: 4));
        if (mounted) Navigator.pop(context);
      } else {
        await Future.delayed(const Duration(seconds: 1));
        if (mounted) _beginTest();
      }
    }
    _busy = false;
  }

  Future<void> _beginPreload() async {
    setState(() => _stage = MeasurementStage.readyPreload);
    widget.voice.say('Preload ${_preloadIndex + 1}');
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    setState(() => _stage = MeasurementStage.collectingPreload);
  }

  Future<void> _beginTest() async {
    setState(() => _stage = MeasurementStage.readyTest);
    widget.voice.say('Test ${_testIndex + 1}');
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    setState(() => _stage = MeasurementStage.collectingTest);
  }

  Future<void> _saveGroup() async {
    final pos = widget.gpsRecordingEnabled ? widget.gps.current : null;
    final group = TestGroup(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      time: DateTime.now(),
      drops: List.from(_testDrops),
      plateRadius: widget.dropSettings.plateRadius,
      latitude: pos?.latitude ?? 0,
      longitude: pos?.longitude ?? 0,
      accuracy: pos?.accuracy ?? 0,
    );
    _location.testGroups.add(group);
    await widget.onComplete();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        title: Text('Measurement (${_location.name})'),
        backgroundColor: const Color(0xFF0A0E1A),
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            _header(),
            const SizedBox(height: 8),
            _instructionCard(),
            const SizedBox(height: 8),
            _liveCard(),
            const SizedBox(height: 8),
            _progressRow('Preloads', _preloadIndex, _preloadCount,
                Colors.orangeAccent),
            const SizedBox(height: 6),
            _progressRow(
                'Tests', _testIndex, _testCount, const Color(0xFF00E5FF)),
            const SizedBox(height: 8),
            Expanded(child: _testChartCard()),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF151B2E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2A3654)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${widget.site.name} / ${widget.job.name} / ${_location.name}',
              style: const TextStyle(color: Colors.white, fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            'Plate: ${widget.dropSettings.plateDiameterMm.toStringAsFixed(0)} mm',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _instructionCard() {
    final (text, color, voice) = _instruction();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [color.withOpacity(0.2), color.withOpacity(0.05)],
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.5), width: 1.5),
      ),
      child: Row(
        children: [
          MagicEye(
            state: _stage == MeasurementStage.collectingPreload ||
                    _stage == MeasurementStage.collectingTest
                ? MagicEyeState.green
                : MagicEyeState.blue,
            size: 44,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(voice,
                    style: TextStyle(
                        color: color,
                        fontSize: 10,
                        letterSpacing: 1.5,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(text,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        height: 1.3)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  (String, Color, String) _instruction() {
    switch (_stage) {
      case MeasurementStage.idle:
        return ('Please wait...', Colors.grey, 'WAIT');
      case MeasurementStage.readyPreload:
        return (
          'Lift the weight, release for Preload ${_preloadIndex + 1} of $_preloadCount.',
          Colors.orangeAccent,
          'PRELOAD ${_preloadIndex + 1}'
        );
      case MeasurementStage.collectingPreload:
        return ('Drop the weight now...', Colors.greenAccent, 'RECORDING...');
      case MeasurementStage.readyTest:
        return (
          'Lift the weight, release for Test ${_testIndex + 1} of $_testCount.',
          const Color(0xFF00E5FF),
          'TEST ${_testIndex + 1}'
        );
      case MeasurementStage.collectingTest:
        return ('Drop the weight now...', Colors.greenAccent, 'RECORDING...');
      case MeasurementStage.complete:
        final evdVal = UnitsService.evd(_avgEvd).toStringAsFixed(2);
        final unit = UnitsService.evdUnit();
        return (
          _testValid
              ? 'VALID TEST. EVD_mean: $evdVal $unit'
              : 'INVALID TEST. EVD_mean: $evdVal $unit',
          _testValid ? Colors.greenAccent : Colors.redAccent,
          _testValid ? 'SUCCESS' : 'FAIL'
        );
    }
  }

  Widget _liveCard() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF151B2E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2A3654)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _metric('EVD',
              UnitsService.evd(_currentEvd).toStringAsFixed(1),
              UnitsService.evdUnit(), const Color(0xFF00E5FF), 20),
          _metric('DEFL',
              UnitsService.deflection(_currentDef).toStringAsFixed(2),
              UnitsService.deflectionUnit(), Colors.orangeAccent, 14),
          _metric('VEL',
              UnitsService.velocity(_currentVel).toStringAsFixed(2),
              UnitsService.velocityUnit(), Colors.greenAccent, 12),
          _metric('ACC', _currentAcc.toStringAsFixed(2), 'g',
              Colors.purpleAccent, 12),
        ],
      ),
    );
  }

  Widget _metric(String l, String v, String u, Color c, double s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l,
            style: TextStyle(
                color: Colors.grey.shade500,
                fontSize: 8,
                letterSpacing: 1)),
        Text(v,
            style: TextStyle(
                color: c,
                fontSize: s,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace')),
        Text(u,
            style: TextStyle(color: Colors.grey.shade600, fontSize: 7)),
      ],
    );
  }

  Widget _progressRow(String label, int current, int total, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label,
                style: TextStyle(
                    color: Colors.grey.shade500,
                    fontSize: 10,
                    fontWeight: FontWeight.w600)),
            const Spacer(),
            Text('$current / $total',
                style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.bold)),
          ],
        ),
        const SizedBox(height: 3),
        Row(
          children: List.generate(total, (i) {
            final filled = i < current;
            return Expanded(
              child: Container(
                height: 6,
                margin: EdgeInsets.only(right: i < total - 1 ? 5 : 0),
                decoration: BoxDecoration(
                  color: filled ? color : Colors.grey.shade900,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            );
          }),
        ),
      ],
    );
  }

  Widget _testChartCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF151B2E),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF2A3654)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.show_chart,
                  color: Color(0xFF00E5FF), size: 14),
              const SizedBox(width: 6),
              Text(
                  'SETTLEMENT vs IMPACT TIME (${UnitsService.deflectionUnit()})',
                  style: const TextStyle(
                      color: Colors.grey,
                      fontSize: 10,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w600)),
              const Spacer(),
              Text('${_testDrops.length} drops',
                  style: TextStyle(
                      color: Colors.grey.shade600, fontSize: 9)),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(child: _buildHmpStyleChart()),
        ],
      ),
    );
  }

  Color _colorForIndex(int i) {
    const colors = [
      Color(0xFF00E5FF),
      Colors.orangeAccent,
      Colors.greenAccent,
    ];
    return colors[i % colors.length];
  }

  // ============================================================
  //  IMPACT WINDOW: find [startIdx, endIdx] around peak where
  //  |value| >= threshold * peakValue
  // ============================================================
  List<int> _getImpactRange(List<double> data) {
    final n = data.length;
    if (n < 2) return [0, n - 1];

    // 1) Find the peak
    double peakVal = 0;
    int peakIdx = 0;
    for (int i = 0; i < n; i++) {
      if (data[i].abs() > peakVal) {
        peakVal = data[i].abs();
        peakIdx = i;
      }
    }
    if (peakVal == 0) return [0, n - 1];

    final threshold = peakVal * _trimThreshold;

    // 2) Walk LEFT from peak
    int startIdx = peakIdx;
    for (int i = peakIdx; i >= 0; i--) {
      if (data[i].abs() < threshold) {
        startIdx = i;
        break;
      }
      if (i == 0) startIdx = 0;
    }

    // 3) Walk RIGHT from peak
    int endIdx = peakIdx;
    for (int i = peakIdx; i < n; i++) {
      if (data[i].abs() < threshold) {
        endIdx = i;
        break;
      }
      if (i == n - 1) endIdx = n - 1;
    }

    // Safety
    if (endIdx <= startIdx) {
      startIdx = 0;
      endIdx = n - 1;
    }
    return [startIdx, endIdx];
  }

  // Settlement spots (trimmed to impact window)
  List<FlSpot> _buildSettlementSpots(Drop d) {
    if (d.settlementCurve.isEmpty) return [];
    final range = _getImpactRange(d.settlementCurve);
    final startIdx = range[0];
    final endIdx = range[1];

    final n = d.settlementCurve.length;
    final times = d.impactTimeCurve.isNotEmpty
        ? d.impactTimeCurve
        : List<double>.generate(n, (i) => i * 25.0);

    final spots = <FlSpot>[];
    final tStart = startIdx < times.length ? times[startIdx] : 0.0;
    spots.add(FlSpot(tStart, 0));

    for (int i = startIdx; i <= endIdx; i++) {
      final x = i < times.length ? times[i] : i * 25.0;
      spots.add(FlSpot(x, -d.settlementCurve[i].abs()));
    }

    final tEnd = endIdx < times.length ? times[endIdx] : endIdx * 25.0;
    spots.add(FlSpot(tEnd, 0));

    return spots;
  }

  Widget _buildHmpStyleChart() {
    if (_testDrops.isEmpty) {
      return Center(
        child: Text(
          _stage == MeasurementStage.readyTest
              ? 'Ready for next drop'
              : 'Waiting for first test drop...',
          style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
        ),
      );
    }

    // Compute ranges across all drops
    double maxSettle = 0;
    double minX = double.infinity;
    double maxX = 0;

    for (final d in _testDrops) {
      // Peak
      double localMax = 0;
      for (final v in d.settlementCurve) {
        if (v.abs() > localMax) localMax = v.abs();
      }
      if (localMax > maxSettle) maxSettle = localMax;

      // X-range from trimmed window
      if (d.settlementCurve.isEmpty) continue;
      final range = _getImpactRange(d.settlementCurve);
      final n = d.settlementCurve.length;
      final times = d.impactTimeCurve.isNotEmpty
          ? d.impactTimeCurve
          : List<double>.generate(n, (i) => i * 25.0);
      final tStart = range[0] < times.length ? times[range[0]] : 0.0;
      final tEnd = range[1] < times.length ? times[range[1]] : 0.0;
      if (tStart < minX) minX = tStart;
      if (tEnd > maxX) maxX = tEnd;
    }

    if (maxSettle == 0) maxSettle = 0.1;
    if (minX == double.infinity) minX = 0;
    if (maxX <= minX) maxX = minX + 100;

    final double chartMaxY = maxSettle * 0.25;
    final double chartMinY = -maxSettle * 1.15;

    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: maxSettle / 3,
          getDrawingHorizontalLine: (value) => FlLine(
            color: value == 0
                ? Colors.white.withOpacity(0.6)
                : Colors.grey.shade900,
            strokeWidth: value == 0 ? 1.5 : 1,
            dashArray: value == 0 ? [4, 4] : null,
          ),
        ),
        titlesData: FlTitlesData(
          show: true,
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              interval: ((maxX - minX) / 4).clamp(0.5, 1000).toDouble(),
              getTitlesWidget: (v, _) => Text(
                v.toStringAsFixed(0),
                style:
                    TextStyle(color: Colors.grey.shade600, fontSize: 8),
              ),
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 40,
              interval: maxSettle / 3,
              getTitlesWidget: (v, _) => Text(
                v.abs().toStringAsFixed(2),
                style:
                    TextStyle(color: Colors.grey.shade600, fontSize: 8),
              ),
            ),
          ),
        ),
        borderData: FlBorderData(show: false),
        minX: minX,
        maxX: maxX,
        minY: chartMinY,
        maxY: chartMaxY,
        lineBarsData: _testDrops.asMap().entries.map((e) {
          final d = e.value;
          final idx = e.key;
          return LineChartBarData(
            spots: _buildSettlementSpots(d),
            isCurved: true,
            curveSmoothness: 0.3,
            color: _colorForIndex(idx),
            barWidth: 2.5,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: _colorForIndex(idx).withOpacity(0.15),
            ),
          );
        }).toList(),
      ),
    );
  }
}