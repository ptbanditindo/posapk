import '../core/dates.dart';
import '../printer/printer_config.dart';
import '../printer/printer_service.dart';
import 'app_database.dart';
import 'receipt_service.dart';

/// Satu percobaan cetak struk yang disimpan lokal.
class PrintJob {
  const PrintJob({
    required this.id,
    required this.recordId,
    required this.noNota,
    required this.width,
    required this.status,
    required this.attempts,
    required this.lastError,
    required this.createdAt,
    this.printedAt,
  });

  final int id;
  final int recordId;
  final String noNota;
  final int width;
  final String status;
  final int attempts;
  final String lastError;
  final DateTime? createdAt;
  final DateTime? printedAt;

  bool get pending => status == 'PENDING';
  bool get failed => status == 'FAILED';
  bool get printed => status == 'PRINTED';

  String get label => switch (status) {
        'PRINTED' => 'Tercetak',
        'FAILED' => 'Gagal dicetak',
        _ => 'Menunggu dicetak',
      };

  static PrintJob fromRow(Map<String, Object?> row) {
    return PrintJob(
      id: (row['id'] as num?)?.toInt() ?? 0,
      recordId: (row['record_id'] as num?)?.toInt() ?? 0,
      noNota: '${row['no_nota'] ?? ''}',
      width: (row['width'] as num?)?.toInt() ?? 32,
      status: '${row['status'] ?? 'PENDING'}',
      attempts: (row['attempts'] as num?)?.toInt() ?? 0,
      lastError: '${row['last_error'] ?? ''}',
      createdAt: DateTime.tryParse('${row['created_at'] ?? ''}'),
      printedAt: DateTime.tryParse('${row['printed_at'] ?? ''}'),
    );
  }
}

/// Antrean cetak per nota. Job gagal tidak pernah membuang struk: pengguna
/// dapat membuka nota lagi dan menekan Cetak untuk mencoba ulang.
class PrintQueueService {
  PrintQueueService._();

  static final PrintQueueService instance = PrintQueueService._();

  Future<int> _width(ReceiptDocument? document) async {
    if (document != null) return document.width;
    final printer = await PrinterStore.instance.primary();
    return printer?.width ?? 32;
  }

  /// Membuat atau memakai ulang job yang belum selesai untuk nota yang sama
  /// sehingga ketukan ganda tidak menumpuk antrean dan job gagal dapat
  /// dicoba ulang tanpa kehilangan riwayat percobaannya.
  Future<PrintJob> enqueue(
    int recordId, {
    ReceiptDocument? document,
    int? width,
  }) async {
    final db = AppDatabase.instance.db;
    final existing = await db.query(
      'print_jobs',
      where: "record_id = ? AND doc_type = 'nota' "
          "AND status IN ('PENDING', 'FAILED')",
      whereArgs: [recordId],
      orderBy: 'created_at DESC, id DESC',
      limit: 1,
    );
    if (existing.isNotEmpty) return PrintJob.fromRow(existing.first);

    final rows = await db.query(
      'service_records',
      columns: ['sync_id', 'no_nota'],
      where: 'id = ?',
      whereArgs: [recordId],
      limit: 1,
    );
    final record = rows.isEmpty ? const <String, Object?>{} : rows.first;
    final resolvedWidth = width ?? await _width(document);
    final now = nowIso();
    final id = await db.insert('print_jobs', {
      'record_id': recordId,
      'record_sync_id': '${record['sync_id'] ?? ''}',
      'no_nota': '${record['no_nota'] ?? ''}',
      'doc_type': 'nota',
      'width': resolvedWidth,
      'status': 'PENDING',
      'attempts': 0,
      'last_error': '',
      'created_at': now,
      'updated_at': now,
    });
    return PrintJob(
      id: id,
      recordId: recordId,
      noNota: '${record['no_nota'] ?? ''}',
      width: resolvedWidth,
      status: 'PENDING',
      attempts: 0,
      lastError: '',
      createdAt: DateTime.tryParse(now),
    );
  }

  /// Mencetak struk untuk [recordId] dan memperbarui status job.
  Future<PrintResult> printReceipt(
    int recordId, {
    ReceiptDocument? document,
    int? width,
  }) async {
    final job = await enqueue(recordId, document: document, width: width);
    return printJob(job, document: document);
  }

  /// Mencoba ulang job yang sudah ada tanpa membuat job baru.
  Future<PrintResult> printJob(
    PrintJob job, {
    ReceiptDocument? document,
  }) async {
    final db = AppDatabase.instance.db;
    ReceiptDocument? resolved = document;
    if (resolved == null) {
      try {
        resolved = await ReceiptService.instance.build(
          job.recordId,
          width: job.width,
        );
      } catch (error) {
        return _fail(job, 'Struk tidak dapat disiapkan: $error');
      }
    }
    PrintResult result;
    try {
      result = await PrinterService.instance.printReceipt(resolved);
    } catch (error) {
      return _fail(job, 'Printer gagal: $error');
    }
    final now = nowIso();
    await db.update(
      'print_jobs',
      {
        'attempts': job.attempts + 1,
        'status': result.ok ? 'PRINTED' : 'FAILED',
        'last_error': result.ok ? '' : result.message,
        'printed_at': result.ok ? now : null,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [job.id],
    );
    if (result.ok) {
      // Kegagalan lama untuk nota yang sama sudah tidak relevan setelah
      // cetak berhasil.
      await db.update(
        'print_jobs',
        {'status': 'SUPERSEDED', 'updated_at': now},
        where: "record_id = ? AND status = 'FAILED' AND id <> ?",
        whereArgs: [job.recordId, job.id],
      );
    }
    return result;
  }

  Future<PrintResult> _fail(PrintJob job, String message) async {
    final now = nowIso();
    await AppDatabase.instance.db.update(
      'print_jobs',
      {
        'attempts': job.attempts + 1,
        'status': 'FAILED',
        'last_error': message,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [job.id],
    );
    return PrintResult(ok: false, message: message);
  }

  Future<PrintJob?> latest(int recordId) async {
    final rows = await AppDatabase.instance.db.query(
      'print_jobs',
      where: 'record_id = ?',
      whereArgs: [recordId],
      orderBy: 'created_at DESC, id DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : PrintJob.fromRow(rows.first);
  }

  Future<int> failedCount() async {
    final rows = await AppDatabase.instance.db.rawQuery(
      "SELECT COUNT(*) AS jumlah FROM print_jobs WHERE status = 'FAILED'",
    );
    return (rows.first['jumlah'] as num?)?.toInt() ?? 0;
  }

  Future<int> pendingCount() async {
    final rows = await AppDatabase.instance.db.rawQuery(
      "SELECT COUNT(*) AS jumlah FROM print_jobs WHERE status = 'PENDING'",
    );
    return (rows.first['jumlah'] as num?)?.toInt() ?? 0;
  }
}
