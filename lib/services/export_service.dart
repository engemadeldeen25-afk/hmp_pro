import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:csv/csv.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../models/models.dart';
import 'units_service.dart';

class ExportService {
  // ============================================================
  //  TRIM CURVE TO IMPACT WINDOW (same as app)
  // ============================================================
  static List<int> _impactRange(List<double> data,
      {double threshold = 0.20}) {
    final n = data.length;
    if (n < 2) return [0, n - 1];

    double peakVal = 0;
    int peakIdx = 0;
    for (int i = 0; i < n; i++) {
      if (data[i].abs() > peakVal) {
        peakVal = data[i].abs();
        peakIdx = i;
      }
    }
    if (peakVal == 0) return [0, n - 1];

    final t = peakVal * threshold;

    int startIdx = 0;
    for (int i = peakIdx; i >= 0; i--) {
      if (data[i].abs() < t) {
        startIdx = i;
        break;
      }
    }
    int endIdx = n - 1;
    for (int i = peakIdx; i < n; i++) {
      if (data[i].abs() < t) {
        endIdx = i;
        break;
      }
    }

    if (endIdx <= startIdx) return [0, n - 1];
    return [startIdx, endIdx];
  }

  // ============================================================
  //  CSV - SIMPLE DROP LIST
  // ============================================================
  static Future<File> buildCsv(
    List<Drop> drops,
    String title, {
    UserProfile? profile,
  }) async {
    final rows = <List<dynamic>>[];
    if (profile != null && profile.companyName.isNotEmpty) {
      rows.add([profile.companyName]);
      rows.add([]);
    }
    rows.add([title]);
    rows.add([]);
    rows.add([
      'Drop #',
      'Date',
      'Time',
      'EVD (${UnitsService.evdUnit()})',
      'Deflection (${UnitsService.deflectionUnit()})',
      'Acceleration (g)',
      'Velocity (${UnitsService.velocityUnit()})',
      'S/V',
    ]);
    for (final d in drops) {
      rows.add([
        d.dropNumber,
        DateFormat('yyyy-MM-dd').format(d.time),
        DateFormat('HH:mm:ss').format(d.time),
        UnitsService.evd(d.evd).toStringAsFixed(2),
        UnitsService.deflection(d.deflection).toStringAsFixed(4),
        d.acceleration.toStringAsFixed(4),
        UnitsService.velocity(d.velocity).toStringAsFixed(4),
        d.sOverV.toStringAsFixed(4),
      ]);
    }

    final csv = const ListToCsvConverter().convert(rows);
    final dir = await getApplicationDocumentsDirectory();
    final f = File(
        '${dir.path}/HMP_PRO_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.csv');
    await f.writeAsString(csv);
    return f;
  }

  // ============================================================
  //  CSV - GROUP (chart-ready structure)
  // ============================================================
  static Future<File> buildGroupCsv(
    TestGroup group, {
    required String siteName,
    required String jobName,
    required String locationName,
    UserProfile? profile,
  }) async {
    final rows = <List<dynamic>>[];

    // ---- Header ----
    if (profile != null && profile.companyName.isNotEmpty) {
      rows.add([profile.companyName]);
      if (profile.engineerName.isNotEmpty) {
        rows.add(['Engineer: ${profile.engineerName}']);
      }
      if (profile.phone.isNotEmpty) rows.add(['Phone: ${profile.phone}']);
      if (profile.email.isNotEmpty) rows.add(['Email: ${profile.email}']);
      rows.add([]);
    }

    rows.add(['HMP PRO — TEST GROUP REPORT']);
    rows.add([]);
    rows.add(['Site', siteName]);
    rows.add(['Job', jobName]);
    rows.add(['Location', locationName]);
    rows.add(['Date', DateFormat('yyyy-MM-dd HH:mm:ss').format(group.time)]);
    rows.add(['Plate Diameter (mm)', group.plateDiameterMm.toStringAsFixed(0)]);
    rows.add(['Unit System', UnitsService.system]);
    if (group.hasLocation) {
      rows.add([
        'GPS',
        '${group.latitude.toStringAsFixed(6)}, ${group.longitude.toStringAsFixed(6)}'
      ]);
      rows.add(['GPS Accuracy (m)', group.accuracy.toStringAsFixed(1)]);
    }
    rows.add([]);

    // ---- Test Data Table ----
    rows.add(['TEST DATA']);
    rows.add([
      'Test #',
      'Time',
      'Settlement (${UnitsService.deflectionUnit()})',
      'Velocity (${UnitsService.velocityUnit()})',
      'EVD (${UnitsService.evdUnit()})',
      'Acceleration (g)',
      'S/V',
    ]);
    for (final d in group.drops) {
      rows.add([
        d.dropNumber,
        DateFormat('HH:mm:ss').format(d.time),
        UnitsService.deflection(d.deflection).toStringAsFixed(4),
        UnitsService.velocity(d.velocity).toStringAsFixed(4),
        UnitsService.evd(d.evd).toStringAsFixed(2),
        d.acceleration.toStringAsFixed(4),
        d.sOverV.toStringAsFixed(4),
      ]);
    }
    rows.add([]);

    // ---- Averages Table ----
    rows.add(['GROUP AVERAGES']);
    rows.add([
      'Avg Settlement (${UnitsService.deflectionUnit()})',
      UnitsService.deflection(group.avgDeflection).toStringAsFixed(4)
    ]);
    rows.add([
      'Avg Velocity (${UnitsService.velocityUnit()})',
      UnitsService.velocity(group.avgVelocity).toStringAsFixed(4)
    ]);
    rows.add([
      'Avg EVD (${UnitsService.evdUnit()})',
      UnitsService.evd(group.avgEvd).toStringAsFixed(2)
    ]);
    rows.add([
      'Avg Acceleration (g)',
      group.avgAcceleration.toStringAsFixed(4)
    ]);
    rows.add(['S/V Max', group.maxSOverV.toStringAsFixed(4)]);
    rows.add(['S/V Mean', group.avgSOverV.toStringAsFixed(4)]);
    rows.add([]);
    rows.add([]);

    // ---- Settlement vs Impact Time (chart-ready) ----
    rows.add(['SETTLEMENT vs IMPACT TIME (${UnitsService.deflectionUnit()})']);
    rows.add([
      'Impact Time (ms)',
      for (int i = 0; i < group.drops.length; i++)
        'Drop ${i + 1} (${UnitsService.deflectionUnit()})',
    ]);

    // Collect data per drop for settlement
    final settleData = <List<MapEntry<double, double>>>[];
    for (final d in group.drops) {
      final entries = <MapEntry<double, double>>[];
      if (d.settlementCurve.isNotEmpty) {
        final range = _impactRange(d.settlementCurve);
        final n = d.settlementCurve.length;
        final times = d.impactTimeCurve.isNotEmpty
            ? d.impactTimeCurve
            : List<double>.generate(n, (i) => i * 25.0);
        for (int i = range[0]; i <= range[1]; i++) {
          final x = i < times.length ? times[i] : i * 25.0;
          final y = UnitsService.deflection(d.settlementCurve[i].abs());
          entries.add(MapEntry(x, y));
        }
      }
      settleData.add(entries);
    }

    // Union of all time points
    final allTimesSettle = <double>{};
    for (final list in settleData) {
      for (final e in list) allTimesSettle.add(e.key);
    }
    final sortedTimesSettle = allTimesSettle.toList()..sort();

    for (final t in sortedTimesSettle) {
      final row = <dynamic>[t.toStringAsFixed(0)];
      for (final list in settleData) {
        double? v;
        for (final e in list) {
          if ((e.key - t).abs() < 0.01) {
            v = e.value;
            break;
          }
        }
        row.add(v != null ? v.toStringAsFixed(4) : '');
      }
      rows.add(row);
    }

    rows.add([]);
    rows.add([]);

    // ---- Velocity vs Impact Time (chart-ready) ----
    rows.add(['VELOCITY vs IMPACT TIME (${UnitsService.velocityUnit()})']);
    rows.add([
      'Impact Time (ms)',
      for (int i = 0; i < group.drops.length; i++)
        'Drop ${i + 1} (${UnitsService.velocityUnit()})',
    ]);

    final velData = <List<MapEntry<double, double>>>[];
    for (final d in group.drops) {
      final entries = <MapEntry<double, double>>[];
      if (d.velocityCurve.isNotEmpty) {
        final range = _impactRange(d.settlementCurve);
        final n = d.velocityCurve.length;
        final times = d.impactTimeCurve.isNotEmpty
            ? d.impactTimeCurve
            : List<double>.generate(n, (i) => i * 25.0);
        for (int i = range[0]; i <= range[1] && i < n; i++) {
          final x = i < times.length ? times[i] : i * 25.0;
          final y = UnitsService.velocity(d.velocityCurve[i]);
          entries.add(MapEntry(x, y));
        }
      }
      velData.add(entries);
    }

    final allTimesVel = <double>{};
    for (final list in velData) {
      for (final e in list) allTimesVel.add(e.key);
    }
    final sortedTimesVel = allTimesVel.toList()..sort();

    for (final t in sortedTimesVel) {
      final row = <dynamic>[t.toStringAsFixed(0)];
      for (final list in velData) {
        double? v;
        for (final e in list) {
          if ((e.key - t).abs() < 0.01) {
            v = e.value;
            break;
          }
        }
        row.add(v != null ? v.toStringAsFixed(4) : '');
      }
      rows.add(row);
    }

    final csv = const ListToCsvConverter().convert(rows);
    final dir = await getApplicationDocumentsDirectory();
    final f = File(
        '${dir.path}/HMP_GROUP_${DateFormat('yyyyMMdd_HHmmss').format(group.time)}.csv');
    await f.writeAsString(csv);
    return f;
  }

  // ============================================================
  //  PDF - SIMPLE DROP LIST
  // ============================================================
  static Future<File> buildPdf(
    List<Drop> drops,
    String title, {
    UserProfile? profile,
  }) async {
    final pdf = pw.Document();
    pw.MemoryImage? logo;
    if (profile != null && profile.logoPath != null) {
      try {
        final bytes = await File(profile.logoPath!).readAsBytes();
        logo = pw.MemoryImage(bytes);
      } catch (_) {}
    }

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (context) {
          final widgets = <pw.Widget>[];

          widgets.add(_pdfHeader(profile, logo, 'TEST REPORT'));
          widgets.add(pw.SizedBox(height: 16));
          widgets.add(pw.Text(title,
              style: pw.TextStyle(
                  fontSize: 13, fontWeight: pw.FontWeight.bold)));
          widgets.add(pw.SizedBox(height: 12));
          widgets.add(_styledTable(
            headers: [
              'Drop',
              'Time',
              'EVD',
              'Defl',
              'Acc',
              'Vel',
              'S/V'
            ],
            data: drops
                .map((d) => [
                      d.dropNumber.toString(),
                      DateFormat('HH:mm:ss').format(d.time),
                      UnitsService.evd(d.evd).toStringAsFixed(1),
                      UnitsService.deflection(d.deflection)
                          .toStringAsFixed(3),
                      d.acceleration.toStringAsFixed(3),
                      UnitsService.velocity(d.velocity).toStringAsFixed(3),
                      d.sOverV.toStringAsFixed(3),
                    ])
                .toList(),
          ));

          return widgets;
        },
      ),
    );

    final dir = await getApplicationDocumentsDirectory();
    final f = File(
        '${dir.path}/HMP_PRO_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.pdf');
    await f.writeAsBytes(await pdf.save());
    return f;
  }

  // ============================================================
  //  PDF - GROUP WITH EMBEDDED CHARTS
  // ============================================================
  static Future<File> buildGroupPdf(
    TestGroup group, {
    required String siteName,
    required String jobName,
    required String locationName,
    UserProfile? profile,
  }) async {
    final pdf = pw.Document();

    // Load logo if available
    pw.MemoryImage? logo;
    if (profile != null && profile.logoPath != null) {
      try {
        final bytes = await File(profile.logoPath!).readAsBytes();
        logo = pw.MemoryImage(bytes);
      } catch (_) {}
    }

    // Compute max values
    double maxSettle = 0;
    double maxVel = 0;
    for (final d in group.drops) {
      for (final v in d.settlementCurve) {
        if (v.abs() > maxSettle) maxSettle = v.abs();
      }
      for (final v in d.velocityCurve) {
        if (v.abs() > maxVel) maxVel = v.abs();
      }
    }

    final passed = group.avgEvd >= 40;

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        build: (context) {
          final w = <pw.Widget>[];

          // ---------- HEADER ----------
          w.add(_pdfHeader(profile, logo, 'TEST GROUP REPORT'));
          w.add(pw.SizedBox(height: 14));

          // ---------- PROJECT INFO CARD ----------
          w.add(
            pw.Container(
              padding: const pw.EdgeInsets.all(12),
              decoration: pw.BoxDecoration(
                color: PdfColors.grey100,
                border: pw.Border.all(color: PdfColors.grey400, width: 0.5),
                borderRadius: pw.BorderRadius.circular(6),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  _infoLine('Site', siteName),
                  _infoLine('Job', jobName),
                  _infoLine('Location', locationName),
                  _infoLine(
                      'Date', DateFormat('yyyy-MM-dd HH:mm:ss').format(group.time)),
                  _infoLine('Plate Diameter',
                      '${group.plateDiameterMm.toStringAsFixed(0)} mm'),
                  _infoLine('Unit System', UnitsService.system),
                  if (group.hasLocation)
                    _infoLine('GPS',
                        '${group.latitude.toStringAsFixed(6)}, ${group.longitude.toStringAsFixed(6)}'),
                ],
              ),
            ),
          );
          w.add(pw.SizedBox(height: 12));

          // ---------- PASS/FAIL BADGE ----------
          w.add(
            pw.Container(
              padding: pw.EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: pw.BoxDecoration(
                color: passed ? PdfColors.green700 : PdfColors.red700,
                borderRadius: pw.BorderRadius.circular(20),
              ),
              child: pw.Row(
                mainAxisSize: pw.MainAxisSize.min,
                children: [
                  pw.Text(
                    passed ? '✓ VALID TEST' : '✗ INVALID TEST',
                    style: pw.TextStyle(
                      color: PdfColors.white,
                      fontWeight: pw.FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                  pw.SizedBox(width: 12),
                  pw.Text(
                    'EVD Mean: ${UnitsService.evd(group.avgEvd).toStringAsFixed(2)} ${UnitsService.evdUnit()}',
                    style: pw.TextStyle(
                      color: PdfColors.white,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          );
          w.add(pw.SizedBox(height: 16));

          // ---------- TEST DATA TABLE ----------
          w.add(_sectionTitle('TEST DATA'));
          w.add(pw.SizedBox(height: 6));
          w.add(_styledTable(
            headers: [
              'Test',
              'Settle (${UnitsService.deflectionUnit()})',
              'Velocity (${UnitsService.velocityUnit()})',
              'EVD (${UnitsService.evdUnit()})',
              'Acc (g)',
              'S/V',
            ],
            data: group.drops
                .map((d) => [
                      'Test ${d.dropNumber}',
                      UnitsService.deflection(d.deflection)
                          .toStringAsFixed(4),
                      UnitsService.velocity(d.velocity)
                          .toStringAsFixed(4),
                      UnitsService.evd(d.evd).toStringAsFixed(2),
                      d.acceleration.toStringAsFixed(4),
                      d.sOverV.toStringAsFixed(4),
                    ])
                .toList(),
          ));
          w.add(pw.SizedBox(height: 16));

          // ---------- SETTLEMENT CHART ----------
          w.add(_sectionTitle(
              'SETTLEMENT vs IMPACT TIME (${UnitsService.deflectionUnit()})'));
          w.add(pw.SizedBox(height: 6));
          w.add(_pdfChart(
            drops: group.drops,
            isSettlement: true,
            maxValue: maxSettle * 1.15,
            yUnit: UnitsService.deflectionUnit(),
          ));
          w.add(pw.SizedBox(height: 16));

          // ---------- VELOCITY CHART ----------
          w.add(_sectionTitle(
              'VELOCITY vs IMPACT TIME (${UnitsService.velocityUnit()})'));
          w.add(pw.SizedBox(height: 6));
          w.add(_pdfChart(
            drops: group.drops,
            isSettlement: false,
            maxValue: maxVel * 1.15,
            yUnit: UnitsService.velocityUnit(),
          ));
          w.add(pw.SizedBox(height: 16));

          // ---------- AVERAGES TABLE ----------
          w.add(_sectionTitle('GROUP AVERAGES'));
          w.add(pw.SizedBox(height: 6));
          w.add(_styledTable(
            headers: ['Metric', 'Value'],
            data: [
              [
                'Settlement Mean (${UnitsService.deflectionUnit()})',
                UnitsService.deflection(group.avgDeflection)
                    .toStringAsFixed(4)
              ],
              [
                'Velocity Mean (${UnitsService.velocityUnit()})',
                UnitsService.velocity(group.avgVelocity).toStringAsFixed(4)
              ],
              [
                'EVD Mean (${UnitsService.evdUnit()})',
                UnitsService.evd(group.avgEvd).toStringAsFixed(2)
              ],
              [
                'Acceleration Mean (g)',
                group.avgAcceleration.toStringAsFixed(4)
              ],
              ['S/V Max', group.maxSOverV.toStringAsFixed(4)],
              ['S/V Mean', group.avgSOverV.toStringAsFixed(4)],
            ],
          ));
          w.add(pw.SizedBox(height: 20));

          // ---------- FOOTER ----------
          w.add(_pdfFooter(profile));

          return w;
        },
      ),
    );

    final dir = await getApplicationDocumentsDirectory();
    final f = File(
        '${dir.path}/HMP_GROUP_${DateFormat('yyyyMMdd_HHmmss').format(group.time)}.pdf');
    await f.writeAsBytes(await pdf.save());
    return f;
  }

  // ============================================================
  //  PDF HEADER
  // ============================================================
  static pw.Widget _pdfHeader(
      UserProfile? profile, pw.MemoryImage? logo, String title) {
    return pw.Container(
      padding: const pw.EdgeInsets.only(bottom: 12),
      decoration: const pw.BoxDecoration(
        border: pw.Border(
          bottom: pw.BorderSide(color: PdfColors.grey400, width: 1),
        ),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          if (logo != null) ...[
            pw.Image(logo, width: 50, height: 50),
            pw.SizedBox(width: 12),
          ],
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  profile?.companyName.isNotEmpty == true
                      ? profile!.companyName
                      : 'HMP PRO',
                  style: pw.TextStyle(
                    fontSize: 16,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.blue900,
                  ),
                ),
                if (profile?.engineerName.isNotEmpty == true)
                  pw.Text('Engineer: ${profile!.engineerName}',
                      style: const pw.TextStyle(fontSize: 9)),
                if (profile?.phone.isNotEmpty == true ||
                    profile?.email.isNotEmpty == true)
                  pw.Text(
                    '${profile?.phone ?? ''}  ${profile?.email ?? ''}',
                    style: const pw.TextStyle(fontSize: 9),
                  ),
              ],
            ),
          ),
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text(title,
                  style: pw.TextStyle(
                    fontSize: 11,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.blue900,
                  )),
              pw.SizedBox(height: 2),
              pw.Text(
                DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now()),
                style: const pw.TextStyle(
                    fontSize: 8, color: PdfColors.grey700),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ============================================================
  //  PDF FOOTER
  // ============================================================
  static pw.Widget _pdfFooter(UserProfile? profile) {
    return pw.Container(
      padding: const pw.EdgeInsets.only(top: 8),
      decoration: const pw.BoxDecoration(
        border: pw.Border(
          top: pw.BorderSide(color: PdfColors.grey400, width: 0.5),
        ),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            'Generated by HMP PRO v3.0 — Industrial LWD System',
            style: const pw.TextStyle(
                fontSize: 7, color: PdfColors.grey600),
          ),
          pw.Text(
            profile?.website ?? '',
            style: const pw.TextStyle(
                fontSize: 7, color: PdfColors.grey600),
          ),
        ],
      ),
    );
  }

  static pw.Widget _infoLine(String label, String value) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
      child: pw.Row(
        children: [
          pw.SizedBox(
            width: 110,
            child: pw.Text(label,
                style: const pw.TextStyle(
                    fontSize: 9, color: PdfColors.grey700)),
          ),
          pw.Expanded(
            child: pw.Text(value,
                style: pw.TextStyle(
                    fontSize: 10,
                    fontWeight: pw.FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  static pw.Widget _sectionTitle(String text) {
    return pw.Container(
      padding: pw.EdgeInsets.only(bottom: 4),
      decoration: const pw.BoxDecoration(
        border: pw.Border(
          bottom: pw.BorderSide(color: PdfColors.grey400, width: 0.5),
        ),
      ),
      child: pw.Text(text,
          style: pw.TextStyle(
            fontSize: 11,
            fontWeight: pw.FontWeight.bold,
            color: PdfColors.blue900,
          )),
    );
  }

  // ============================================================
  //  STYLED TABLE
  // ============================================================
  static pw.Widget _styledTable({
    required List<String> headers,
    required List<List<String>> data,
  }) {
    return pw.TableHelper.fromTextArray(
      headers: headers,
      data: data,
      headerStyle: pw.TextStyle(
        fontWeight: pw.FontWeight.bold,
        fontSize: 9,
        color: PdfColors.white,
      ),
      headerDecoration: const pw.BoxDecoration(
        color: PdfColor.fromInt(0xFF1E88E5),
      ),
      cellStyle: const pw.TextStyle(fontSize: 9),
      cellAlignment: pw.Alignment.center,
      cellPadding: const pw.EdgeInsets.all(5),
      border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
      oddRowDecoration: const pw.BoxDecoration(color: PdfColors.grey100),
    );
  }

  // ============================================================
  //  EMBEDDED PDF LINE CHART (drawn on canvas)
  // ============================================================
  static pw.Widget _pdfChart({
    required List<Drop> drops,
    required bool isSettlement,
    required double maxValue,
    required String yUnit,
  }) {
    const double width = 515;
    const double height = 220;

    // Colors matching the app
    final colors = [
      PdfColor.fromInt(0xFF00E5FF),  // Cyan
      PdfColor.fromInt(0xFFFFA726),  // Orange
      PdfColor.fromInt(0xFF66BB6A),  // Green
    ];

    return pw.Container(
      width: width,
      height: height,
      decoration: pw.BoxDecoration(
        color: const PdfColor.fromInt(0xFF0A192F),
        border: pw.Border.all(color: PdfColors.grey600, width: 0.5),
        borderRadius: pw.BorderRadius.circular(4),
      ),
      padding: const pw.EdgeInsets.all(4),
      child: pw.CustomPaint(
        size: PdfPoint(width, height),
        painter: (PdfGraphics canvas, PdfPoint size) {
          // Chart area (inside canvas)
          const double paddingLeft = 40;
          const double paddingRight = 12;
          const double paddingTop = 12;
          const double paddingBottom = 24;

          final chartLeft = paddingLeft;
          final chartRight = size.x - paddingRight;
          final chartTop = paddingTop;
          final chartBottom = size.y - paddingBottom;
          final chartWidth = chartRight - chartLeft;
          final chartHeight = chartBottom - chartTop;

          // ---- Background ----
          canvas
            ..setColor(const PdfColor.fromInt(0xFF0A192F))
            ..drawRect(0, 0, size.x, size.y)
            ..fillPath();

          // ---- Compute X range ----
          double minTime = double.infinity;
          double maxTime = 0;
          for (final d in drops) {
            final data =
                isSettlement ? d.settlementCurve : d.velocityCurve;
            if (data.isEmpty) continue;
            final range = _impactRange(d.settlementCurve);
            final n = data.length;
            final times = d.impactTimeCurve.isNotEmpty
                ? d.impactTimeCurve
                : List<double>.generate(n, (i) => i * 25.0);
            if (range[0] < times.length &&
                times[range[0]] < minTime) minTime = times[range[0]];
            if (range[1] < times.length &&
                times[range[1]] > maxTime) maxTime = times[range[1]];
          }
          if (minTime == double.infinity) minTime = 0;
          if (maxTime <= minTime) maxTime = minTime + 100;

          // ---- Grid lines (horizontal) ----
          canvas
            ..setColor(const PdfColor.fromInt(0xFF1A2540))
            ..setLineWidth(0.3);
          for (int i = 0; i <= 4; i++) {
            final y = chartTop + chartHeight * i / 4;
            canvas
              ..moveTo(chartLeft, y)
              ..lineTo(chartRight, y)
              ..strokePath();
          }

          // ---- Zero reference line (dashed) ----
          // For settlement: zero is at top of chart (Y-max area is 0)
          // For velocity: zero is in middle
          final double zeroY;
          if (isSettlement) {
            zeroY = chartTop;
          } else {
            zeroY = chartTop + chartHeight / 2;
          }
          canvas
            ..setColor(const PdfColor.fromInt(0xFF808080))
            ..setLineWidth(0.5)
            ..moveTo(chartLeft, zeroY)
            ..lineTo(chartRight, zeroY)
            ..strokePath();

          // ---- Y-axis labels ----
          canvas.setColor(PdfColors.white);
          for (int i = 0; i <= 4; i++) {
            final y = chartTop + chartHeight * i / 4;
            final labelValue = maxValue - (maxValue * 2) * (i / 4);
            final label = labelValue.abs().toStringAsFixed(2);
            // Simple text - we just place a small line marker
            canvas
              ..setLineWidth(1)
              ..moveTo(chartLeft - 3, y)
              ..lineTo(chartLeft, y)
              ..strokePath();
            // Use pw.Text approach instead - handled by outer Row
          }

          // ---- X-axis line ----
          canvas
            ..setColor(const PdfColor.fromInt(0xFF808080))
            ..setLineWidth(0.7)
            ..moveTo(chartLeft, chartBottom)
            ..lineTo(chartRight, chartBottom)
            ..strokePath();

          // ---- Draw each drop's curve ----
          for (int di = 0; di < drops.length; di++) {
            final d = drops[di];
            final data = isSettlement ? d.settlementCurve : d.velocityCurve;
            if (data.isEmpty) continue;

            final range = _impactRange(d.settlementCurve);
            final startIdx = range[0];
            final endIdx = range[1];

            final n = data.length;
            final times = d.impactTimeCurve.isNotEmpty
                ? d.impactTimeCurve
                : List<double>.generate(n, (i) => i * 25.0);

            final color = colors[di % colors.length];
            canvas
              ..setColor(color)
              ..setLineWidth(1.4);

            bool first = true;
            for (int i = startIdx; i <= endIdx && i < n; i++) {
              final xTime = i < times.length ? times[i] : i * 25.0;
              double xRatio = (xTime - minTime) / (maxTime - minTime);
              if (xRatio < 0) xRatio = 0;
              if (xRatio > 1) xRatio = 1;

              final x = chartLeft + chartWidth * xRatio;

              double value = data[i].abs();
              // Normalize to 0..1, where 1 = maxValue
              double yRatio = value / maxValue;
              if (yRatio > 1) yRatio = 1;
              if (yRatio < 0) yRatio = 0;

              // Settlement: dip downward (from top)
              // Velocity: dip downward too for consistency
              final y = chartTop + chartHeight * yRatio;

              if (first) {
                canvas.moveTo(x, y);
                first = false;
              } else {
                canvas.lineTo(x, y);
              }
            }
            canvas.strokePath();
          }
        },
      ),
    );
  }
}