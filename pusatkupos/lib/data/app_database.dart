import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

import '../core/dates.dart';
import '../core/ids.dart';
import 'models.dart';

class AppDatabase {
  AppDatabase();

  static final AppDatabase instance = AppDatabase();

  Database? _db;
  String? _path;

  Database get db {
    final value = _db;
    if (value == null) {
      throw StateError('Database belum dibuka.');
    }
    return value;
  }

  String get databasePath {
    final value = _path;
    if (value == null) {
      throw StateError('Database belum dibuka.');
    }
    return value;
  }

  bool get isOpen => _db != null;

  Future<void> init() async {
    if (_db != null) return;
    if (kIsWeb) {
      databaseFactory = databaseFactoryFfiWeb;
      _path = 'pusatkupos.db';
    } else {
      if (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux) {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
      }
      final dir = await getApplicationSupportDirectory();
      _path = p.join(dir.path, 'pusatkupos.db');
    }
    await _open();
  }

  Future<void> initForTest(String path) async {
    await close();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    _path = path;
    await _open();
  }

  Future<void> _open() async {
    _db = await databaseFactory.openDatabase(
      _path!,
      options: OpenDatabaseOptions(
        version: 3,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: _createSchema,
        onUpgrade: _upgrade,
      ),
    );
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  Future<void> reopen() async {
    await close();
    await _open();
  }

  Future<void> checkpoint() async {
    await db.rawQuery('PRAGMA wal_checkpoint(FULL)');
  }

  Future<void> _createSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE app_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE customers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_id TEXT NOT NULL UNIQUE,
        nama TEXT NOT NULL,
        nomor_hp TEXT NOT NULL,
        alamat TEXT,
        wa_consent INTEGER NOT NULL DEFAULT 1,
        do_not_contact INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX ix_customers_nama ON customers(nama)',
    );
    await db.execute('''
      CREATE TABLE vehicle_or_units (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_id TEXT NOT NULL UNIQUE,
        customer_id INTEGER NOT NULL,
        unit_type TEXT NOT NULL,
        nopol TEXT,
        jenis_mobil TEXT,
        tahun_mobil INTEGER,
        tipe_radiator TEXT,
        label_radiator TEXT,
        created_at TEXT NOT NULL,
        FOREIGN KEY (customer_id) REFERENCES customers(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE stock_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_id TEXT NOT NULL UNIQUE,
        kode TEXT NOT NULL UNIQUE,
        nama TEXT NOT NULL,
        harga_modal INTEGER NOT NULL DEFAULT 0,
        harga_jual INTEGER NOT NULL DEFAULT 0,
        jumlah INTEGER NOT NULL DEFAULT 0,
        stok_minimum INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX ix_stock_items_nama ON stock_items(nama)',
    );
    await db.execute('''
      CREATE TABLE harga_jasa (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_id TEXT NOT NULL UNIQUE,
        nama TEXT NOT NULL,
        harga_standar INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE service_records (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_id TEXT NOT NULL UNIQUE,
        unit_id INTEGER NOT NULL,
        no_nota TEXT NOT NULL UNIQUE,
        request_id TEXT UNIQUE,
        waktu_service TEXT NOT NULL,
        keluhan_awal TEXT NOT NULL,
        catatan_pengerjaan TEXT,
        biaya_jasa INTEGER NOT NULL DEFAULT 0,
        total_part INTEGER NOT NULL DEFAULT 0,
        diskon INTEGER NOT NULL DEFAULT 0,
        total_servis INTEGER NOT NULL DEFAULT 0,
        metode_bayar TEXT NOT NULL DEFAULT 'CASH',
        bayar INTEGER NOT NULL DEFAULT 0,
        kembalian INTEGER NOT NULL DEFAULT 0,
        status_bayar TEXT NOT NULL DEFAULT 'LUNAS',
        jenis_bayar TEXT NOT NULL DEFAULT 'LUNAS',
        total_dibayar INTEGER NOT NULL DEFAULT 0,
        sisa_bayar INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'AKTIF',
        void_reason TEXT,
        voided_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (unit_id) REFERENCES vehicle_or_units(id)
      )
    ''');
    await db.execute(
      'CREATE INDEX ix_service_records_waktu ON service_records(waktu_service)',
    );
    await db.execute('''
      CREATE TABLE service_jobs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_id TEXT,
        service_record_id INTEGER NOT NULL,
        harga_jasa_id INTEGER,
        deskripsi TEXT NOT NULL,
        jumlah INTEGER NOT NULL,
        harga INTEGER NOT NULL,
        subtotal INTEGER NOT NULL,
        FOREIGN KEY (service_record_id) REFERENCES service_records(id)
          ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE service_parts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_id TEXT,
        service_record_id INTEGER NOT NULL,
        stock_item_id INTEGER,
        nama_part TEXT NOT NULL,
        jumlah INTEGER NOT NULL,
        harga_satuan INTEGER NOT NULL,
        subtotal INTEGER NOT NULL,
        harga_modal INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (service_record_id) REFERENCES service_records(id)
          ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE service_payments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_id TEXT,
        service_record_id INTEGER NOT NULL,
        jenis TEXT NOT NULL DEFAULT 'PELUNASAN',
        metode TEXT NOT NULL DEFAULT 'CASH',
        nominal INTEGER NOT NULL,
        waktu TEXT NOT NULL,
        operator TEXT NOT NULL DEFAULT 'Pemilik',
        request_id TEXT UNIQUE,
        catatan TEXT,
        FOREIGN KEY (service_record_id) REFERENCES service_records(id)
          ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE stock_movements (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_id TEXT,
        stock_item_id INTEGER,
        nama_item TEXT,
        jenis TEXT NOT NULL,
        jumlah INTEGER NOT NULL,
        alasan TEXT,
        service_record_id INTEGER,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE nota_counters (
        tanggal TEXT PRIMARY KEY,
        terakhir INTEGER NOT NULL DEFAULT 0
      )
    ''');
    final now = nowIso();
    await db.insert('app_settings', {
      'key': 'bengkel.nama',
      'value': 'PUSATKU POS',
    });
    await db.insert('app_settings', {
      'key': 'bengkel.alamat',
      'value': '',
    });
    await db.insert('app_settings', {'key': 'app.created_at', 'value': now});
    await _createSyncSchema(db);
    await _addSyncIds(db);
  }

  Future<void> _addSyncIds(Database db) async {
    for (final table in const [
      'service_jobs',
      'service_parts',
      'service_payments',
      'stock_movements',
    ]) {
      final columns = await db.rawQuery('PRAGMA table_info($table)');
      if (!columns.any((column) => column['name'] == 'sync_id')) {
        await db.execute('ALTER TABLE $table ADD COLUMN sync_id TEXT');
      }
      await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS ux_${table}_sync_id ON $table(sync_id)',
      );
    }
  }

  Future<void> _upgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createSyncSchema(db);
    }
    if (oldVersion < 3) {
      await _addSyncIds(db);
    }
  }

  Future<void> _createSyncSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS owner_identity (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        owner_id TEXT NOT NULL,
        public_key TEXT NOT NULL,
        recovery_hash TEXT,
        recovery_salt TEXT,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS license (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        plan TEXT NOT NULL DEFAULT 'free',
        period_end TEXT,
        device_limit INTEGER NOT NULL DEFAULT 1,
        provider TEXT NOT NULL DEFAULT 'manual',
        token TEXT,
        activated_at TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS employee_accounts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_id TEXT NOT NULL UNIQUE,
        username TEXT NOT NULL UNIQUE,
        nama TEXT NOT NULL,
        role_base TEXT NOT NULL DEFAULT 'KASIR',
        extra_permissions_json TEXT NOT NULL DEFAULT '[]',
        store_ids_json TEXT NOT NULL DEFAULT '[]',
        password_hash TEXT NOT NULL,
        password_salt TEXT NOT NULL,
        password_iterations INTEGER NOT NULL DEFAULT 120000,
        pin_hash TEXT,
        pin_salt TEXT,
        pin_iterations INTEGER NOT NULL DEFAULT 120000,
        must_change_password INTEGER NOT NULL DEFAULT 1,
        aktif INTEGER NOT NULL DEFAULT 1,
        permission_version INTEGER NOT NULL DEFAULT 1,
        last_login_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS permission_audits (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        actor TEXT NOT NULL,
        target_account_id INTEGER,
        action TEXT NOT NULL,
        detail_json TEXT NOT NULL DEFAULT '{}',
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS devices (
        id TEXT PRIMARY KEY,
        owner_id TEXT NOT NULL,
        nama TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'owner',
        employee_account_id INTEGER,
        public_key TEXT NOT NULL,
        encryption_key TEXT NOT NULL,
        token_hash TEXT NOT NULL UNIQUE,
        created_at TEXT NOT NULL,
        last_seen_at TEXT,
        revoked_at TEXT,
        revoked_reason TEXT NOT NULL DEFAULT ''
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS login_guards (
        scope TEXT PRIMARY KEY,
        failures INTEGER NOT NULL DEFAULT 0,
        lock_until TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_outbox (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        device_id TEXT NOT NULL,
        seq INTEGER NOT NULL,
        hlc_wall INTEGER NOT NULL,
        hlc_counter INTEGER NOT NULL,
        idempotency_key TEXT NOT NULL UNIQUE,
        entity TEXT NOT NULL,
        entity_id TEXT NOT NULL DEFAULT '',
        action TEXT NOT NULL,
        payload_json TEXT NOT NULL DEFAULT '{}',
        status TEXT NOT NULL DEFAULT 'pending',
        retry_count INTEGER NOT NULL DEFAULT 0,
        error TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL,
        sent_at TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_cursor (
        store_id TEXT NOT NULL,
        device_id TEXT NOT NULL,
        last_seq INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (store_id, device_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS applied_deltas (
        idempotency_key TEXT PRIMARY KEY,
        envelope_id TEXT NOT NULL DEFAULT '',
        entity TEXT NOT NULL DEFAULT '',
        entity_id TEXT NOT NULL DEFAULT '',
        applied_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_conflicts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        entity TEXT NOT NULL,
        entity_id TEXT NOT NULL DEFAULT '',
        reason TEXT NOT NULL,
        detail_json TEXT NOT NULL DEFAULT '{}',
        created_at TEXT NOT NULL,
        resolved_at TEXT
      )
    ''');
  }

  Future<String?> getSetting(String key) async {
    final rows = await db.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> setSetting(String key, String value) async {
    await db.insert(
      'app_settings',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteSetting(String key) async {
    await db.delete('app_settings', where: 'key = ?', whereArgs: [key]);
  }

  Future<List<Customer>> listCustomers({String query = ''}) async {
    final term = query.trim();
    final rows = await db.query(
      'customers',
      where: term.isEmpty ? null : 'nama LIKE ? OR nomor_hp LIKE ?',
      whereArgs: term.isEmpty ? null : ['%$term%', '%$term%'],
      orderBy: 'nama COLLATE NOCASE',
    );
    return rows.map(Customer.fromRow).toList();
  }

  Future<int> addCustomer({
    required String nama,
    required String nomorHp,
    String? alamat,
  }) {
    return db.insert('customers', {
      'sync_id': newSyncId(),
      'nama': nama.trim(),
      'nomor_hp': nomorHp.trim(),
      'alamat': (alamat ?? '').trim().isEmpty ? null : alamat!.trim(),
      'created_at': nowIso(),
    });
  }

  Future<List<VehicleUnit>> listUnits(int customerId) async {
    final rows = await db.query(
      'vehicle_or_units',
      where: 'customer_id = ?',
      whereArgs: [customerId],
      orderBy: 'id DESC',
    );
    return rows.map(VehicleUnit.fromRow).toList();
  }

  Future<int> addUnit({
    required int customerId,
    required String unitType,
    String? nopol,
    String? jenisMobil,
    int? tahunMobil,
    String? tipeRadiator,
    String? labelRadiator,
  }) {
    return db.insert('vehicle_or_units', {
      'sync_id': newSyncId(),
      'customer_id': customerId,
      'unit_type': unitType,
      'nopol': _nullable(nopol),
      'jenis_mobil': _nullable(jenisMobil),
      'tahun_mobil': tahunMobil,
      'tipe_radiator': _nullable(tipeRadiator),
      'label_radiator': _nullable(labelRadiator),
      'created_at': nowIso(),
    });
  }

  Future<List<StockItem>> listStock({String query = ''}) async {
    final term = query.trim();
    final rows = await db.query(
      'stock_items',
      where: term.isEmpty ? null : 'nama LIKE ? OR kode LIKE ?',
      whereArgs: term.isEmpty ? null : ['%$term%', '%$term%'],
      orderBy: 'nama COLLATE NOCASE',
    );
    return rows.map(StockItem.fromRow).toList();
  }

  Future<int> saveStockItem({
    int? id,
    required String kode,
    required String nama,
    required int hargaModalCents,
    required int hargaJualCents,
    required int jumlah,
    required int stokMinimum,
  }) async {
    final payload = {
      'kode': kode.trim(),
      'nama': nama.trim(),
      'harga_modal': hargaModalCents,
      'harga_jual': hargaJualCents,
      'jumlah': jumlah,
      'stok_minimum': stokMinimum,
    };
    if (id != null) {
      await db.update('stock_items', payload, where: 'id = ?', whereArgs: [id]);
      return id;
    }
    return db.insert('stock_items', {
      ...payload,
      'sync_id': newSyncId(),
      'created_at': nowIso(),
    });
  }

  Future<void> stockIn({
    required StockItem item,
    required int qty,
    String? alasan,
  }) async {
    if (qty <= 0) throw ArgumentError('Jumlah stok masuk minimal 1.');
    await db.transaction((txn) async {
      await txn.rawUpdate(
        'UPDATE stock_items SET jumlah = jumlah + ? WHERE id = ?',
        [qty, item.id],
      );
      await txn.insert('stock_movements', {
        'sync_id': newSyncId(),
        'stock_item_id': item.id,
        'nama_item': item.nama,
        'jenis': 'MASUK',
        'jumlah': qty,
        'alasan': (alasan ?? '').trim().isEmpty ? 'Tambah stok' : alasan!.trim(),
        'created_at': nowIso(),
      });
    });
  }

  Future<List<ServiceCatalog>> listCatalog() async {
    final rows = await db.query(
      'harga_jasa',
      orderBy: 'nama COLLATE NOCASE',
    );
    return rows.map(ServiceCatalog.fromRow).toList();
  }

  Future<int> saveCatalog({
    int? id,
    required String nama,
    required int hargaCents,
  }) async {
    if (id != null) {
      await db.update(
        'harga_jasa',
        {'nama': nama.trim(), 'harga_standar': hargaCents},
        where: 'id = ?',
        whereArgs: [id],
      );
      return id;
    }
    return db.insert('harga_jasa', {
      'sync_id': newSyncId(),
      'nama': nama.trim(),
      'harga_standar': hargaCents,
      'created_at': nowIso(),
    });
  }

  Future<void> deleteCatalog(int id) async {
    await db.delete('harga_jasa', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> createTransaction({
    required int unitId,
    required String keluhan,
    required List<JobDraft> jobs,
    required List<PartDraft> parts,
    required int diskonCents,
    required String metodeBayar,
    required int bayarCents,
    String? requestId,
    String? catatan,
  }) async {
    if (jobs.isEmpty && parts.isEmpty) {
      throw ArgumentError('Tambahkan minimal satu jasa atau part.');
    }
    return db.transaction((txn) async {
      if ((requestId ?? '').trim().isNotEmpty) {
        final existing = await txn.query(
          'service_records',
          columns: ['id'],
          where: 'request_id = ?',
          whereArgs: [requestId!.trim()],
          limit: 1,
        );
        if (existing.isNotEmpty) return existing.first['id'] as int;
      }
      for (final part in parts) {
        if (part.jumlah <= 0) {
          throw ArgumentError('Jumlah part harus lebih dari nol.');
        }
        final rows = await txn.query(
          'stock_items',
          where: 'id = ?',
          whereArgs: [part.stockItemId],
          limit: 1,
        );
        if (rows.isEmpty) {
          throw StateError('Barang ${part.nama} tidak ditemukan.');
        }
        final stock = StockItem.fromRow(rows.first);
        if (stock.jumlah < part.jumlah) {
          throw StateError(
            'Stok ${stock.nama} tidak cukup (tersisa ${stock.jumlah}).',
          );
        }
        part
          ..nama = stock.nama
          ..modalCents = stock.hargaModalCents;
      }
      final biayaJasa = jobs.fold<int>(0, (sum, job) => sum + job.subtotalCents);
      final totalPart =
          parts.fold<int>(0, (sum, part) => sum + part.subtotalCents);
      final bruto = biayaJasa + totalPart;
      final diskon = diskonCents.clamp(0, bruto).toInt();
      final total = bruto - diskon;
      final dibayar = bayarCents.clamp(0, total).toInt();
      final kembalian = bayarCents > total ? bayarCents - total : 0;
      final sisa = total - dibayar;
      final statusBayar = sisa == 0 ? 'LUNAS' : 'KREDIT';
      final now = nowIso();
      final noNota = await _nextNota(txn);
      final recordId = await txn.insert('service_records', {
        'sync_id': newSyncId(),
        'unit_id': unitId,
        'no_nota': noNota,
        'request_id': (requestId ?? '').trim().isEmpty
            ? null
            : requestId!.trim(),
        'waktu_service': now,
        'keluhan_awal': keluhan.trim(),
        'catatan_pengerjaan': _nullable(catatan),
        'biaya_jasa': biayaJasa,
        'total_part': totalPart,
        'diskon': diskon,
        'total_servis': total,
        'metode_bayar': metodeBayar,
        'bayar': bayarCents,
        'kembalian': kembalian,
        'status_bayar': statusBayar,
        'jenis_bayar': statusBayar,
        'total_dibayar': dibayar,
        'sisa_bayar': sisa,
        'created_at': now,
        'updated_at': now,
      });
      for (final job in jobs) {
        await txn.insert('service_jobs', {
          'sync_id': newSyncId(),
          'service_record_id': recordId,
          'deskripsi': job.deskripsi.trim(),
          'jumlah': job.jumlah,
          'harga': job.hargaCents,
          'subtotal': job.subtotalCents,
        });
      }
      for (final part in parts) {
        await txn.insert('service_parts', {
          'sync_id': newSyncId(),
          'service_record_id': recordId,
          'stock_item_id': part.stockItemId,
          'nama_part': part.nama,
          'jumlah': part.jumlah,
          'harga_satuan': part.hargaCents,
          'subtotal': part.subtotalCents,
          'harga_modal': part.modalCents,
        });
        await txn.rawUpdate(
          'UPDATE stock_items SET jumlah = jumlah - ? WHERE id = ?',
          [part.jumlah, part.stockItemId],
        );
        await txn.insert('stock_movements', {
          'sync_id': newSyncId(),
          'stock_item_id': part.stockItemId,
          'nama_item': part.nama,
          'jenis': 'KELUAR',
          'jumlah': -part.jumlah,
          'alasan': 'Penjualan $noNota',
          'service_record_id': recordId,
          'created_at': now,
        });
      }
      if (bayarCents > 0) {
        await txn.insert('service_payments', {
          'sync_id': newSyncId(),
          'service_record_id': recordId,
          'jenis': 'PELUNASAN',
          'metode': metodeBayar,
          'nominal': dibayar,
          'waktu': now,
          'operator': 'Pemilik',
          'request_id': '${requestId ?? noNota}-bayar',
          'catatan': null,
        });
      }
      return recordId;
    });
  }

  Future<String> _nextNota(Transaction txn) async {
    final key = dateOnly.format(DateTime.now());
    final prefixRows = await txn.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['device.nota_prefix'],
      limit: 1,
    );
    var prefix =
        prefixRows.isEmpty ? '' : prefixRows.first['value'] as String? ?? '';
    if (prefix.isEmpty) {
      prefix = newNotaPrefix();
      await txn.insert(
        'app_settings',
        {'key': 'device.nota_prefix', 'value': prefix},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await txn.rawInsert(
      'INSERT OR IGNORE INTO nota_counters(tanggal, terakhir) VALUES(?, 0)',
      [key],
    );
    final rows = await txn.query(
      'nota_counters',
      where: 'tanggal = ?',
      whereArgs: [key],
      limit: 1,
    );
    final next = ((rows.first['terakhir'] as int?) ?? 0) + 1;
    await txn.update(
      'nota_counters',
      {'terakhir': next},
      where: 'tanggal = ?',
      whereArgs: [key],
    );
    return 'INV-$key-$prefix-${next.toString().padLeft(4, '0')}';
  }

  Future<List<ServiceRecordSummary>> listRecords({
    DateTime? from,
    DateTime? to,
    String query = '',
    int limit = 100,
  }) async {
    final start = from ?? DateTime(2000);
    final end = to ?? DateTime(2100);
    final term = query.trim();
    final rows = await db.rawQuery(
      '''
      SELECT r.*, c.nama AS customer_nama,
        COALESCE(NULLIF(TRIM(COALESCE(u.nopol, '') || ' ' ||
          COALESCE(u.jenis_mobil, '') || ' ' ||
          COALESCE(u.label_radiator, '')), ''), u.unit_type) AS unit_label
      FROM service_records r
      JOIN vehicle_or_units u ON u.id = r.unit_id
      JOIN customers c ON c.id = u.customer_id
      WHERE r.waktu_service BETWEEN ? AND ?
        ${term.isEmpty ? '' : 'AND (r.no_nota LIKE ? OR c.nama LIKE ?)'}
      ORDER BY r.waktu_service DESC
      LIMIT ?
      ''',
      [
        isoStartOfDay(start),
        isoEndOfDay(end),
        if (term.isNotEmpty) ...[ '%$term%', '%$term%' ],
        limit,
      ],
    );
    return rows.map(ServiceRecordSummary.fromRow).toList();
  }

  Future<RecordDetail?> recordDetail(int id) async {
    final rows = await db.rawQuery(
      '''
      SELECT r.*, c.nama AS customer_nama,
        COALESCE(NULLIF(TRIM(COALESCE(u.nopol, '') || ' ' ||
          COALESCE(u.jenis_mobil, '') || ' ' ||
          COALESCE(u.label_radiator, '')), ''), u.unit_type) AS unit_label
      FROM service_records r
      JOIN vehicle_or_units u ON u.id = r.unit_id
      JOIN customers c ON c.id = u.customer_id
      WHERE r.id = ?
      LIMIT 1
      ''',
      [id],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final jobRows = await db.query(
      'service_jobs',
      where: 'service_record_id = ?',
      whereArgs: [id],
      orderBy: 'id',
    );
    final partRows = await db.query(
      'service_parts',
      where: 'service_record_id = ?',
      whereArgs: [id],
      orderBy: 'id',
    );
    final paymentRows = await db.query(
      'service_payments',
      where: 'service_record_id = ?',
      whereArgs: [id],
      orderBy: 'waktu',
    );
    return RecordDetail(
      record: ServiceRecordSummary.fromRow(row),
      jobs: jobRows
          .map(
            (item) => JobDraft(
              deskripsi: item['deskripsi'] as String,
              jumlah: item['jumlah'] as int,
              hargaCents: item['harga'] as int,
            ),
          )
          .toList(),
      parts: partRows
          .map(
            (item) => PartDraft(
              stockItemId: item['stock_item_id'] as int? ?? 0,
              nama: item['nama_part'] as String,
              jumlah: item['jumlah'] as int,
              hargaCents: item['harga_satuan'] as int,
              modalCents: item['harga_modal'] as int? ?? 0,
            ),
          )
          .toList(),
      payments: paymentRows
          .map(
            (item) => PaymentRow(
              id: item['id'] as int,
              jenis: item['jenis'] as String,
              metode: item['metode'] as String,
              nominalCents: item['nominal'] as int,
              waktu: DateTime.parse(item['waktu'] as String),
              catatan: item['catatan'] as String?,
            ),
          )
          .toList(),
      requestId: row['request_id'] as String?,
      catatan: row['catatan_pengerjaan'] as String?,
      jenisBayar: row['jenis_bayar'] as String? ?? 'LUNAS',
      totalDibayarCents: row['total_dibayar'] as int? ?? 0,
      sisaCents: row['sisa_bayar'] as int? ?? 0,
      voidReason: row['void_reason'] as String?,
    );
  }

  Future<void> voidRecord(int id, String reason) async {
    await db.transaction((txn) async {
      final rows = await txn.query(
        'service_records',
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Nota tidak ditemukan.');
      if (rows.first['voided_at'] != null) return;
      final parts = await txn.query(
        'service_parts',
        where: 'service_record_id = ?',
        whereArgs: [id],
      );
      final now = nowIso();
      for (final part in parts) {
        final stockId = part['stock_item_id'] as int?;
        if (stockId == null) continue;
        final qty = part['jumlah'] as int;
        await txn.rawUpdate(
          'UPDATE stock_items SET jumlah = jumlah + ? WHERE id = ?',
          [qty, stockId],
        );
        await txn.insert('stock_movements', {
          'sync_id': newSyncId(),
          'stock_item_id': stockId,
          'nama_item': part['nama_part'],
          'jenis': 'MASUK',
          'jumlah': qty,
          'alasan': 'Void nota ${rows.first['no_nota']}',
          'service_record_id': id,
          'created_at': now,
        });
      }
      await txn.update(
        'service_records',
        {
          'status': 'VOID',
          'voided_at': now,
          'void_reason': reason.trim(),
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    });
  }

  Future<ReportSummary> reportSummary(DateTime from, DateTime to) async {
    final rows = await db.rawQuery(
      '''
      SELECT COUNT(*) AS transaksi,
        COALESCE(SUM(biaya_jasa), 0) AS total_jasa,
        COALESCE(SUM(total_part), 0) AS total_part,
        COALESCE(SUM(diskon), 0) AS diskon,
        COALESCE(SUM(total_servis), 0) AS total,
        COALESCE(SUM(total_dibayar), 0) AS dibayar,
        COALESCE(SUM(sisa_bayar), 0) AS piutang
      FROM service_records
      WHERE waktu_service BETWEEN ? AND ? AND status != 'VOID'
      ''',
      [isoStartOfDay(from), isoEndOfDay(to)],
    );
    final row = rows.first;
    return ReportSummary(
      transaksi: row['transaksi'] as int? ?? 0,
      totalJasaCents: row['total_jasa'] as int? ?? 0,
      totalPartCents: row['total_part'] as int? ?? 0,
      diskonCents: row['diskon'] as int? ?? 0,
      totalCents: row['total'] as int? ?? 0,
      dibayarCents: row['dibayar'] as int? ?? 0,
      piutangCents: row['piutang'] as int? ?? 0,
    );
  }

  Future<DashboardData> dashboard() async {
    final today = DateTime.now();
    final todayRecords = await listRecords(from: today, to: today, limit: 200);
    final active = todayRecords.where((row) => !row.isVoid).toList();
    final revenue = active.fold<int>(0, (sum, row) => sum + row.totalCents);
    final lowRows = await db.rawQuery(
      'SELECT COUNT(*) AS total FROM stock_items WHERE jumlah <= stok_minimum',
    );
    final receivableRows = await db.rawQuery(
      '''
      SELECT COALESCE(SUM(sisa_bayar), 0) AS total
      FROM service_records
      WHERE status != 'VOID' AND sisa_bayar > 0
      ''',
    );
    return DashboardData(
      todayRecords: active,
      todayRevenueCents: revenue,
      todayCount: active.length,
      lowStockCount: lowRows.first['total'] as int? ?? 0,
      receivableCents: receivableRows.first['total'] as int? ?? 0,
      recent: await listRecords(limit: 8),
    );
  }

  static String? _nullable(String? value) {
    final text = (value ?? '').trim();
    return text.isEmpty ? null : text;
  }
}
