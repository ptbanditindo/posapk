import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import '../core/dates.dart';
import '../core/ids.dart';
import '../data/app_database.dart';

/// Data uji hanya aktif bila dibangun dengan
/// `--dart-define=PUSATKU_DUMMY_SEED=true`.
const bool dummySeedEnabled = bool.fromEnvironment('PUSATKU_DUMMY_SEED');
const String dummyRole = String.fromEnvironment('PUSATKU_DUMMY_ROLE');

const dummyKasir = (
  username: 'kasir',
  password: 'kasir123456',
  pin: '111111',
);
const dummyMekanik = (
  username: 'mekanik',
  password: 'mekanik123456',
  pin: '222222',
);

const _seedIterations = 10000;

int _rp(int rupiah) => rupiah * 100;

Future<void> seedDummyDataIfEnabled() async {
  if (!dummySeedEnabled) return;
  if (await AppDatabase.instance.getSetting('dev.dummy_seed') == '1') return;

  await _seedAccounts();
  await _seedBusinessData();
  if (dummyRole == 'owner' || dummyRole == 'employee') {
    await AppDatabase.instance.setSetting('app.role', dummyRole);
  }
  await AppDatabase.instance.setSetting('dev.dummy_seed', '1');
}

Future<void> _seedAccounts() async {
  final db = AppDatabase.instance.db;
  final rows = await db.rawQuery(
    'SELECT COUNT(*) AS total FROM employee_accounts',
  );
  if (((rows.first['total'] as int?) ?? 0) > 0) return;
  await _insertAccount(
    username: dummyKasir.username,
    nama: 'Kasir Demo',
    role: 'KASIR',
    password: dummyKasir.password,
    pin: dummyKasir.pin,
    extraPermissions: const ['lihat_laporan', 'cetak_laporan'],
  );
  await _insertAccount(
    username: dummyMekanik.username,
    nama: 'Mekanik Demo',
    role: 'MEKANIK',
    password: dummyMekanik.password,
    pin: dummyMekanik.pin,
  );
}

Future<void> _insertAccount({
  required String username,
  required String nama,
  required String role,
  required String password,
  required String pin,
  List<String> extraPermissions = const [],
}) async {
  final now = nowIso();
  final (passwordHash, passwordSalt) = await _hash(password);
  final (pinHash, pinSalt) = await _hash(pin);
  await AppDatabase.instance.db.insert('employee_accounts', {
    'sync_id': newSyncId(),
    'username': username,
    'nama': nama,
    'role_base': role,
    'extra_permissions_json': jsonEncode(extraPermissions),
    'store_ids_json': jsonEncode(const ['utama']),
    'password_hash': passwordHash,
    'password_salt': passwordSalt,
    'password_iterations': _seedIterations,
    'pin_hash': pinHash,
    'pin_salt': pinSalt,
    'pin_iterations': _seedIterations,
    'must_change_password': 0,
    'aktif': 1,
    'permission_version': 1,
    'created_at': now,
    'updated_at': now,
  });
}

Future<void> _seedBusinessData() async {
  final db = AppDatabase.instance.db;
  final rows = await db.rawQuery(
    'SELECT COUNT(*) AS total FROM customers',
  );
  if (((rows.first['total'] as int?) ?? 0) > 0) return;
  final now = nowIso();

  final budi = await db.insert('customers', {
    'sync_id': newSyncId(),
    'nama': 'Budi Santoso',
    'nomor_hp': '081234567890',
    'alamat': 'Jl. Merdeka No. 10',
    'wa_consent': 1,
    'do_not_contact': 0,
    'created_at': now,
  });
  final siti = await db.insert('customers', {
    'sync_id': newSyncId(),
    'nama': 'Siti Aminah',
    'nomor_hp': '081298765432',
    'alamat': 'Jl. Melati No. 5',
    'wa_consent': 1,
    'do_not_contact': 0,
    'created_at': now,
  });
  final andi = await db.insert('customers', {
    'sync_id': newSyncId(),
    'nama': 'Andi Pratama',
    'nomor_hp': '085712345678',
    'alamat': 'Jl. Kenanga No. 8',
    'wa_consent': 0,
    'do_not_contact': 1,
    'created_at': now,
  });

  final avanza = await db.insert('vehicle_or_units', {
    'sync_id': newSyncId(),
    'customer_id': budi,
    'unit_type': 'MOBIL',
    'nopol': 'B 1234 XYZ',
    'jenis_mobil': 'Toyota Avanza',
    'tahun_mobil': 2018,
    'tipe_radiator': 'AIR',
    'label_radiator': 'Radiator standar',
    'created_at': now,
  });
  final beat = await db.insert('vehicle_or_units', {
    'sync_id': newSyncId(),
    'customer_id': siti,
    'unit_type': 'MOTOR',
    'nopol': 'B 5678 ABC',
    'jenis_mobil': 'Honda Beat',
    'tahun_mobil': 2020,
    'tipe_radiator': 'UDARA',
    'label_radiator': 'Pendingin udara',
    'created_at': now,
  });
  await db.insert('vehicle_or_units', {
    'sync_id': newSyncId(),
    'customer_id': andi,
    'unit_type': 'MOBIL',
    'nopol': 'B 9012 DEF',
    'jenis_mobil': 'Mitsubishi L300',
    'tahun_mobil': 2015,
    'tipe_radiator': 'AIR',
    'label_radiator': 'Radiator besar',
    'created_at': now,
  });

  final oli = await _stock(
    kode: 'OLI-10W40',
    nama: 'Oli Mesin 10W-40',
    modal: 60000,
    jual: 85000,
    jumlah: 24,
  );
  final filter = await _stock(
    kode: 'FLT-OLI',
    nama: 'Filter Oli',
    modal: 22000,
    jual: 35000,
    jumlah: 50,
  );
  final busi = await _stock(
    kode: 'BSI-IRD',
    nama: 'Busi Iridium',
    modal: 28000,
    jual: 45000,
    jumlah: 100,
  );
  await _stock(
    kode: 'RAD-CLT',
    nama: 'Air Radiator Coolant',
    modal: 15000,
    jual: 25000,
    jumlah: 40,
  );
  await _stock(
    kode: 'KMP-REM',
    nama: 'Kampas Rem Depan',
    modal: 80000,
    jual: 120000,
    jumlah: 20,
  );

  final servisRingan = await _service('Servis Ringan', 75000);
  final gantiOli = await _service('Ganti Oli', 25000);
  final tuneUp = await _service('Tune Up', 150000);

  final budiRecord = await db.insert('service_records', {
    'sync_id': newSyncId(),
    'unit_id': avanza,
    'no_nota': 'DEMO-0001',
    'waktu_service': now,
    'keluhan_awal': 'Servis ringan dan ganti oli',
    'catatan_pengerjaan': 'Oli dan filter oli diganti',
    'biaya_jasa': _rp(100000),
    'total_part': _rp(120000),
    'diskon': 0,
    'total_servis': _rp(220000),
    'metode_bayar': 'CASH',
    'bayar': _rp(220000),
    'kembalian': 0,
    'status_bayar': 'LUNAS',
    'jenis_bayar': 'LUNAS',
    'total_dibayar': _rp(220000),
    'sisa_bayar': 0,
    'status': 'AKTIF',
    'created_by': 'Kasir Demo',
    'mechanic': 'Mekanik Demo',
    'created_at': now,
    'updated_at': now,
  });
  await _job(budiRecord, servisRingan, 'Servis ringan', 75000);
  await _job(budiRecord, gantiOli, 'Ganti oli', 25000);
  await _part(budiRecord, oli, 'Oli Mesin 10W-40', 85000, 60000, 'DEMO-0001');
  await _part(budiRecord, filter, 'Filter Oli', 35000, 22000, 'DEMO-0001');
  await _payment(budiRecord, 220000, 'CASH', 'Kasir Demo');

  final sitiRecord = await db.insert('service_records', {
    'sync_id': newSyncId(),
    'unit_id': beat,
    'no_nota': 'DEMO-0002',
    'waktu_service': now,
    'keluhan_awal': 'Tune up dan ganti busi',
    'catatan_pengerjaan': 'Busi diganti, tune up selesai',
    'biaya_jasa': _rp(150000),
    'total_part': _rp(45000),
    'diskon': 0,
    'total_servis': _rp(195000),
    'metode_bayar': 'CASH',
    'bayar': _rp(100000),
    'kembalian': 0,
    'status_bayar': 'KREDIT',
    'jenis_bayar': 'KREDIT',
    'total_dibayar': _rp(100000),
    'sisa_bayar': _rp(95000),
    'status': 'AKTIF',
    'created_by': 'Kasir Demo',
    'mechanic': 'Mekanik Demo',
    'created_at': now,
    'updated_at': now,
  });
  await _job(sitiRecord, tuneUp, 'Tune up', 150000);
  await _part(sitiRecord, busi, 'Busi Iridium', 45000, 28000, 'DEMO-0002');
  await _payment(sitiRecord, 100000, 'DP', 'Kasir Demo');
}

Future<int> _stock({
  required String kode,
  required String nama,
  required int modal,
  required int jual,
  required int jumlah,
}) async {
  final db = AppDatabase.instance.db;
  final id = await db.insert('stock_items', {
    'sync_id': newSyncId(),
    'kode': kode,
    'nama': nama,
    'harga_modal': _rp(modal),
    'harga_jual': _rp(jual),
    'jumlah': jumlah,
    'jumlah_milli': jumlah * 1000,
    'stok_minimum': 5,
    'satuan': 'pcs',
    'desimal': 0,
    'created_at': nowIso(),
  });
  await db.insert('stock_movements', {
    'sync_id': newSyncId(),
    'stock_item_id': id,
    'nama_item': nama,
    'jenis': 'MASUK',
    'jumlah': jumlah,
    'jumlah_milli': jumlah * 1000,
    'alasan': 'Stok awal data uji',
    'created_at': nowIso(),
  });
  return id;
}

Future<int> _service(String nama, int harga) {
  return AppDatabase.instance.db.insert('harga_jasa', {
    'sync_id': newSyncId(),
    'nama': nama,
    'harga_standar': _rp(harga),
    'created_at': nowIso(),
  });
}

Future<void> _job(int recordId, int jasaId, String deskripsi, int harga) {
  return AppDatabase.instance.db.insert('service_jobs', {
    'sync_id': newSyncId(),
    'service_record_id': recordId,
    'harga_jasa_id': jasaId,
    'deskripsi': deskripsi,
    'jumlah': 1,
    'harga': _rp(harga),
    'subtotal': _rp(harga),
  });
}

Future<void> _part(
  int recordId,
  int stockId,
  String nama,
  int harga,
  int modal,
  String noNota,
) async {
  final db = AppDatabase.instance.db;
  await db.insert('service_parts', {
    'sync_id': newSyncId(),
    'service_record_id': recordId,
    'stock_item_id': stockId,
    'nama_part': nama,
    'jumlah': 1,
    'harga_satuan': _rp(harga),
    'subtotal': _rp(harga),
    'harga_modal': _rp(modal),
  });
  await db.rawUpdate(
    'UPDATE stock_items SET jumlah = jumlah - 1, '
    'jumlah_milli = jumlah_milli - 1000 WHERE id = ?',
    [stockId],
  );
  await db.insert('stock_movements', {
    'sync_id': newSyncId(),
    'stock_item_id': stockId,
    'nama_item': nama,
    'jenis': 'KELUAR',
    'jumlah': -1,
    'jumlah_milli': -1000,
    'alasan': 'Penjualan $noNota',
    'service_record_id': recordId,
    'created_at': nowIso(),
  });
}

Future<void> _payment(
  int recordId,
  int nominal,
  String jenis,
  String operator,
) {
  return AppDatabase.instance.db.insert('service_payments', {
    'sync_id': newSyncId(),
    'service_record_id': recordId,
    'jenis': jenis,
    'metode': 'CASH',
    'nominal': _rp(nominal),
    'waktu': nowIso(),
    'operator': operator,
  });
}

Future<(String, String)> _hash(String value) async {
  final random = Random.secure();
  final saltBytes = List<int>.generate(16, (_) => random.nextInt(256));
  final salt = base64UrlEncode(saltBytes);
  final key = await Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: _seedIterations,
    bits: 256,
  ).deriveKey(
    secretKey: SecretKey(utf8.encode(value)),
    nonce: saltBytes,
  );
  return (base64UrlEncode(await key.extractBytes()), salt);
}
