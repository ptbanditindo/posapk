import 'package:sqflite/sqflite.dart';

import '../core/dates.dart';
import '../core/ids.dart';
import '../core/phone.dart';
import 'app_database.dart';

const supplierStatuses = [
  'DIPESAN',
  'DIKIRIM',
  'TIDAK_TERSEDIA',
  'ARSIP',
];

const supplierStatusLabels = {
  'DIPESAN': 'Dipesan',
  'DIKIRIM': 'Dikirim',
  'TIDAK_TERSEDIA': 'Tidak tersedia',
  'ARSIP': 'Arsip',
  'BELUM': 'Belum dipesan',
};

class SupplierService {
  SupplierService._();

  static final SupplierService instance = SupplierService._();

  Future<List<Map<String, Object?>>> listSuppliers({
    String query = '',
    bool activeOnly = false,
  }) async {
    final term = query.trim();
    final escaped = escapeLike(term);
    final rows = await AppDatabase.instance.db.rawQuery(
      '''
      SELECT s.*,
        (SELECT COUNT(*) FROM supplier_items i WHERE i.supplier_id = s.id)
          AS jumlah_barang
      FROM suppliers s
      WHERE (? = '' OR s.nama LIKE ? ESCAPE '\\')
        ${activeOnly ? 'AND s.aktif = 1' : ''}
      ORDER BY s.nama COLLATE NOCASE
      ''',
      [term, '%$escaped%'],
    );
    return rows;
  }

  Future<int> saveSupplier({
    int? id,
    required String nama,
    String? nomorHp,
    String? alamat,
    String? catatan,
    bool aktif = true,
  }) async {
    final cleanName = nama.trim();
    if (cleanName.length < 2) {
      throw ArgumentError('Nama supplier minimal 2 karakter.');
    }
    final duplicate = await AppDatabase.instance.db.query(
      'suppliers',
      columns: ['id', 'nama'],
      where: 'LOWER(nama) = LOWER(?)',
      whereArgs: [cleanName],
      limit: 1,
    );
    if (duplicate.isNotEmpty && duplicate.first['id'] != id) {
      throw StateError(
        'Supplier "${duplicate.first['nama']}" sudah ada.',
      );
    }
    final now = nowIso();
    final phone = (nomorHp ?? '').trim();
    final payload = {
      'nama': cleanName,
      'nomor_hp': phone.isEmpty ? null : normalizePhone(phone),
      'alamat': _clean(alamat),
      'catatan': _clean(catatan),
      'aktif': aktif ? 1 : 0,
      'updated_at': now,
    };
    if (id != null) {
      final rows = await AppDatabase.instance.db.query(
        'suppliers',
        columns: ['id'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Supplier tidak ditemukan.');
      await AppDatabase.instance.db.update(
        'suppliers',
        payload,
        where: 'id = ?',
        whereArgs: [id],
      );
      return id;
    }
    return AppDatabase.instance.db.insert('suppliers', {
      ...payload,
      'sync_id': newSyncId(),
      'created_at': now,
    });
  }

  Future<void> deleteSupplier(int id) async {
    final db = AppDatabase.instance.db;
    await db.transaction((txn) async {
      await txn.delete(
        'supplier_followups',
        where: 'supplier_id = ?',
        whereArgs: [id],
      );
      await txn.delete(
        'supplier_items',
        where: 'supplier_id = ?',
        whereArgs: [id],
      );
      await txn.delete('suppliers', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<Set<int>> supplierIdsForItem(int stockItemId) async {
    final rows = await AppDatabase.instance.db.query(
      'supplier_items',
      columns: ['supplier_id'],
      where: 'stock_item_id = ?',
      whereArgs: [stockItemId],
    );
    return rows.map((row) => row['supplier_id'] as int).toSet();
  }

  Future<void> syncItemSuppliers(
    int stockItemId,
    Set<int> supplierIds,
  ) async {
    final db = AppDatabase.instance.db;
    await db.transaction((txn) async {
      final current = await txn.query(
        'supplier_items',
        columns: ['supplier_id'],
        where: 'stock_item_id = ?',
        whereArgs: [stockItemId],
      );
      final existing = current
          .map((row) => row['supplier_id'] as int)
          .toSet();
      for (final supplierId in existing.difference(supplierIds)) {
        await txn.delete(
          'supplier_items',
          where: 'supplier_id = ? AND stock_item_id = ?',
          whereArgs: [supplierId, stockItemId],
        );
      }
      for (final supplierId in supplierIds.difference(existing)) {
        await txn.insert(
          'supplier_items',
          {
            'sync_id': newSyncId(),
            'supplier_id': supplierId,
            'stock_item_id': stockItemId,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    });
  }

  Future<List<Map<String, Object?>>> lowStockItems({int? supplierId}) async {
    final rows = await AppDatabase.instance.db.rawQuery(
      '''
      SELECT st.id AS stock_item_id, st.kode, st.nama, st.satuan,
        COALESCE(st.jumlah_milli, st.jumlah * 1000) AS jumlah_milli,
        st.stok_minimum,
        s.id AS supplier_id, s.nama AS supplier_nama, s.nomor_hp,
        COALESCE(f.status, 'BELUM') AS status, f.catatan AS catatan
      FROM stock_items st
      JOIN supplier_items i ON i.stock_item_id = st.id
      JOIN suppliers s ON s.id = i.supplier_id
      LEFT JOIN supplier_followups f
        ON f.supplier_id = s.id AND f.stock_item_id = st.id
      WHERE COALESCE(st.jumlah_milli, st.jumlah * 1000) <=
        (CASE WHEN st.stok_minimum > 0 THEN st.stok_minimum ELSE 3 END) * 1000
        ${supplierId == null ? '' : 'AND s.id = $supplierId'}
      ORDER BY s.nama COLLATE NOCASE, st.nama COLLATE NOCASE
      ''',
    );
    return rows;
  }

  Future<List<Map<String, Object?>>> followupRows({int? supplierId}) async {
    final rows = await AppDatabase.instance.db.rawQuery(
      '''
      SELECT st.id AS stock_item_id, st.nama, st.satuan,
        COALESCE(st.jumlah_milli, st.jumlah * 1000) AS jumlah_milli,
        st.stok_minimum,
        s.id AS supplier_id, s.nama AS supplier_nama, s.nomor_hp,
        COALESCE(f.status, 'BELUM') AS status,
        f.catatan AS catatan, f.updated_at
      FROM supplier_items i
      JOIN suppliers s ON s.id = i.supplier_id
      JOIN stock_items st ON st.id = i.stock_item_id
      LEFT JOIN supplier_followups f
        ON f.supplier_id = i.supplier_id AND f.stock_item_id = i.stock_item_id
      ${supplierId == null ? '' : 'WHERE s.id = $supplierId'}
      ORDER BY s.nama COLLATE NOCASE, st.nama COLLATE NOCASE
      ''',
    );
    return rows;
  }

  Future<void> setFollowupStatus({
    required int supplierId,
    required int stockItemId,
    required String status,
    String? catatan,
  }) async {
    if (!supplierStatuses.contains(status)) {
      throw ArgumentError('Status supplier tidak dikenal.');
    }
    final now = nowIso();
    final existing = await AppDatabase.instance.db.query(
      'supplier_followups',
      columns: ['id'],
      where: 'supplier_id = ? AND stock_item_id = ?',
      whereArgs: [supplierId, stockItemId],
      limit: 1,
    );
    if (existing.isEmpty) {
      await AppDatabase.instance.db.insert('supplier_followups', {
        'sync_id': newSyncId(),
        'supplier_id': supplierId,
        'stock_item_id': stockItemId,
        'status': status,
        'catatan': _clean(catatan),
        'updated_at': now,
      });
      return;
    }
    await AppDatabase.instance.db.update(
      'supplier_followups',
      {
        'status': status,
        'catatan': _clean(catatan),
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [existing.first['id']],
    );
  }

  static String? _clean(String? value) {
    final text = (value ?? '').trim();
    return text.isEmpty ? null : text;
  }
}
