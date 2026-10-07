import 'dart:io';
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
  //  TRIM CURVE (same 20% threshold as app)
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
  //  CSV - GROUP (chart-ready)
  // ============================================================
  static Future<File> buildGroupCsv(
    TestGroup group, {
    required String siteName,
    required String jobName,
    required String locationName,
    UserProfile? profile,
  }) async {
    final rows = <List<dynamic>>[];
    if (profile != null && profile.companyName.isNotEmpty) {
      rows.add([profile.companyName]);
      if (profile.engineerName.isNotEmpty) {
        rows.add(['Engineer: ${profile.engineerName}']);
      }
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
    }
    rows.add([]);

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
    rows.add(['S/V Max', group.maxSOverV.toStringAsFixed(4)]);
    rows.add(['S/V Mean', group.avgSOverV.toStringAsFixed(4)]);
    rows.add([]);
    rows.add([]);

    rows.add(['SETTLEMENT vs IMPACT TIME (${UnitsService.deflectionUnit()})']);
    final settleHeader = <dynamic>['Impact Time (ms)'];
    for (int i = 0; i < group.drops.length; i++) {
      settleHeader.add('Drop ${i + 1}');
    }
    rows.add(settleHeader);

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
    final timesS = <double>{};
    for (final l in settleData) {
      for (final e in l) {
        timesS.add(e.key);
      }
    }
    final sortedS = timesS.toList()..sort();
    for (final t in sortedS) {
      final row = <dynamic>[t.toStringAsFixed(0)];
      for (final l in settleData) {
        double? v;
        for (final e in l) {
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

    rows.add(['VELOCITY vs IMPACT TIME (${UnitsService.velocityUnit()})']);
    final velHeader = <dynamic>['Impact Time (ms)'];
    for (int i = 0; i < group.drops.length; i++) {
      velHeader.add('Drop ${i + 1}');
    }
    rows.add(velHeader);

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
    final timesV = <double>{};
    for (final l in velData) {
      for (final e in l) {
        timesV.add(e.key);
      }
    }
    final sortedV = timesV.toList()..sort();
    for (final t in sortedV) {
      final row = <dynamic>[t.toStringAsFixed(0)];
      for (final l in velData) {
        double? v;
        for (final e in l) {
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
    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (context) {
          return [
            pw.Text(title,
                style: pw.TextStyle(
                    fontSize: 14, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 12),
            _styledTable(
              headers: ['Drop', 'Time', 'EVD', 'Defl', 'Acc', 'Vel', 'S/V'],
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
            ),
          ];
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
  //  PDF - GROUP REPORT WITH EMBEDDED CHART IMAGES
  //  (images are captured by the app, passed here)
  // ============================================================
  static Future<File> buildGroupPdfWithImages(
    TestGroup group, {
    required String siteName,
    required String jobName,
    required String locationName,
    UserProfile? profile,
    Uint8List? settlementChartImage,
    Uint8List? velocityChartImage,
  }) async {
    final pdf = pw.Document();

    pw.MemoryImage? logo;
    if (profile != null && profile.logoPath != null) {
      try {
        final bytes = await File(profile.logoPath!).readAsBytes();
        logo = pw.MemoryImage(bytes);
      } catch (_) {}
    }

    final passed = group.avgEvd >= 40;

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        build: (context) {
          final w = <pw.Widget>[];

          // ---- HEADER ----
          w.add(pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              if (logo != null) ...[
                pw.Image(logo, width: 55, height: 55),
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
                          color: PdfColors.blue900),
                    ),
                    if (profile?.engineerName.isNotEmpty == true)
                      pw.Text('Engineer: ${profile!.engineerName}',
                          style: const pw.TextStyle(fontSize: 9)),
                  ],
                ),
              ),
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Text('TEST GROUP REPORT',
                      style: pw.TextStyle(
                          fontSize: 11,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColors.blue900)),
                  pw.Text(
                    DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now()),
                    style: const pw.TextStyle(fontSize: 8),
                  ),
                ],
              ),
            ],
          ));
          w.add(pw.Divider(color: PdfColors.grey400));
          w.add(pw.SizedBox(height: 8));

          // ---- INFO CARD ----
          w.add(pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(
              color: PdfColors.grey100,
              borderRadius: pw.BorderRadius.circular(5),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                _infoLine('Site', siteName),
                _infoLine('Job', jobName),
                _infoLine('Location', locationName),
                _infoLine('Date',
                    DateFormat('yyyy-MM-dd HH:mm:ss').format(group.time)),
                _infoLine('Plate',
                    '${group.plateDiameterMm.toStringAsFixed(0)} mm'),
                _infoLine('Unit System', UnitsService.system),
                if (group.hasLocation)
                  _infoLine('GPS',
                      '${group.latitude.toStringAsFixed(6)}, ${group.longitude.toStringAsFixed(6)}'),
              ],
            ),
          ));
          w.add(pw.SizedBox(height: 12));

          // ---- PASS/FAIL BADGE ----
          w.add(pw.Container(
            padding: const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: pw.BoxDecoration(
              color: passed ? PdfColors.green700 : PdfColors.red700,
              borderRadius: pw.BorderRadius.circular(15),
            ),
            child: pw.Row(
              mainAxisSize: pw.MainAxisSize.min,
              children: [
                pw.Text(passed ? 'VALID TEST' : 'INVALID TEST',
                    style: pw.TextStyle(
                        color: PdfColors.white,
                        fontWeight: pw.FontWeight.bold,
                        fontSize: 11)),
                pw.SizedBox(width: 10),
                pw.Text(
                  'EVD Mean: ${UnitsService.evd(group.avgEvd).toStringAsFixed(2)} ${UnitsService.evdUnit()}',
                  style:
                      const pw.TextStyle(color: PdfColors.white, fontSize: 10),
                ),
              ],
            ),
          ));
          w.add(pw.SizedBox(height: 14));

          // ---- TEST DATA TABLE ----
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
                      UnitsService.deflection(d.deflection).toStringAsFixed(4),
                      UnitsService.velocity(d.velocity).toStringAsFixed(4),
                      UnitsService.evd(d.evd).toStringAsFixed(2),
                      d.acceleration.toStringAsFixed(4),
                      d.sOverV.toStringAsFixed(4),
                    ])
                .toList(),
          ));
          w.add(pw.SizedBox(height: 16));

          // ---- SETTLEMENT CHART IMAGE ----
          if (settlementChartImage != null) {
            w.add(_sectionTitle(
                'SETTLEMENT vs IMPACT TIME (${UnitsService.deflectionUnit()})'));
            w.add(pw.SizedBox(height: 6));
            w.add(pw.Container(
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PdfColors.grey400, width: 0.5),
                borderRadius: pw.BorderRadius.circular(4),
              ),
              child: pw.Image(pw.MemoryImage(settlementChartImage)),
            ));
            w.add(pw.SizedBox(height: 14));
          }

          // ---- VELOCITY CHART IMAGE ----
          if (velocityChartImage != null) {
            w.add(_sectionTitle(
                'VELOCITY vs IMPACT TIME (${UnitsService.velocityUnit()})'));
            w.add(pw.SizedBox(height: 6));
            w.add(pw.Container(
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PdfColors.grey400, width: 0.5),
                borderRadius: pw.BorderRadius.circular(4),
              ),
              child: pw.Image(pw.MemoryImage(velocityChartImage)),
            ));
            w.add(pw.SizedBox(height: 14));
          }

          // ---- AVERAGES ----
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
              ['S/V Max', group.maxSOverV.toStringAsFixed(4)],
              ['S/V Mean', group.avgSOverV.toStringAsFixed(4)],
            ],
          ));

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

  static pw.Widget _infoLine(String label, String value) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 1),
      child: pw.Row(
        children: [
          pw.SizedBox(
              width: 100,
              child: pw.Text(label,
                  style: const pw.TextStyle(
                      fontSize: 9, color: PdfColors.grey700))),
          pw.Expanded(
              child: pw.Text(value,
                  style: pw.TextStyle(
                      fontSize: 10, fontWeight: pw.FontWeight.bold))),
        ],
      ),
    );
  }

  static pw.Widget _sectionTitle(String text) {
    return pw.Container(
      padding: const pw.EdgeInsets.only(bottom: 3),
      decoration: const pw.BoxDecoration(
        border: pw.Border(
            bottom: pw.BorderSide(color: PdfColors.blue900, width: 0.8)),
      ),
      child: pw.Text(text,
          style: pw.TextStyle(
              fontSize: 11,
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.blue900)),
    );
  }

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
          color: PdfColors.white),
      headerDecoration:
          const pw.BoxDecoration(color: PdfColor.fromInt(0xFF1E88E5)),
      cellStyle: const pw.TextStyle(fontSize: 9),
      cellAlignment: pw.Alignment.center,
      cellPadding: const pw.EdgeInsets.all(5),
      border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
      oddRowDecoration: const pw.BoxDecoration(color: PdfColors.grey100),
    );
  }
}