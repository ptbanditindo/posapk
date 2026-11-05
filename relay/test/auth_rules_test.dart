import 'package:pusatkupos_relay/auth_rules.dart';
import 'package:test/test.dart';

void main() {
  test('perangkat viewer tidak boleh mengirim amplop', () {
    expect(canDeviceSubmitEnvelope('viewer'), isFalse);
    expect(canDeviceSubmitEnvelope('owner'), isTrue);
    expect(canDeviceSubmitEnvelope('employee'), isTrue);
  });

  test('karyawan hanya boleh mengirim entity yang diizinkan', () {
    bool allowed(
      String entity, {
      String action = 'upsert',
      String role = 'TEKNISI',
      Set<String> extras = const {},
    }) {
      return employeeEntityAllowed(
        entity: entity,
        action: action,
        roleBase: role,
        extras: extras,
      );
    }

    expect(allowed('nota'), isTrue);
    expect(allowed('customer'), isTrue);
    expect(allowed('unit'), isTrue);
    expect(allowed('stock_movement'), isTrue);
    expect(allowed('supplier'), isFalse);
    expect(allowed('debt'), isFalse);
    expect(allowed(''), isFalse);
    expect(allowed('nota', action: ''), isFalse);
  });

  test('harga jasa dan stok membutuhkan izin tambahan', () {
    expect(
      employeeEntityAllowed(
        entity: 'harga_jasa',
        action: 'upsert',
        roleBase: 'TEKNISI',
        extras: {},
      ),
      isFalse,
    );
    // Tarif jasa hanya boleh diubah pemilik; izin tambahan tidak membuka.
    expect(
      employeeEntityAllowed(
        entity: 'harga_jasa',
        action: 'upsert',
        roleBase: 'TEKNISI',
        extras: {'ubah_harga_jasa', 'ubah_stok', 'koreksi'},
      ),
      isFalse,
    );
    expect(
      employeeEntityAllowed(
        entity: 'stock',
        action: 'upsert',
        roleBase: 'KASIR',
        extras: {},
      ),
      isFalse,
    );
    // Data barang memuat harga modal, jadi tetap terkunci untuk pemilik.
    expect(
      employeeEntityAllowed(
        entity: 'stock',
        action: 'delta',
        roleBase: 'TEKNISI',
        extras: {},
      ),
      isFalse,
    );
    expect(
      employeeEntityAllowed(
        entity: 'stock',
        action: 'upsert',
        roleBase: 'TEKNISI',
        extras: {'ubah_stok'},
      ),
      isFalse,
    );
  });

  test('follow-up supplier mengikuti peran kasir atau izin followup', () {
    bool followup(String role, Set<String> extras) {
      return employeeEntityAllowed(
        entity: 'supplier_followup',
        action: 'upsert',
        roleBase: role,
        extras: extras,
      );
    }

    expect(followup('TEKNISI', {}), isFalse);
    expect(followup('KASIR', {}), isTrue);
    expect(followup('KEDUANYA', {}), isTrue);
    expect(followup('TEKNISI', {'followup'}), isTrue);
  });

  test('peran dasar memetakan izin entity baru', () {
    expect(
      baseRolePermissions['KASIR'],
      containsAll(['buat_estimasi', 'buat_order']),
    );
    expect(baseRolePermissions['KASIR'], contains('koreksi'));
    expect(baseRolePermissions['MEKANIK'], {'ubah_status'});
    expect(baseRolePermissions['KEDUANYA'], contains('buat_nota'));

    bool allowed(
      String entity, {
      String role = 'KASIR',
      Set<String> extras = const {},
    }) {
      return employeeEntityAllowed(
        entity: entity,
        action: 'upsert',
        roleBase: role,
        extras: extras,
      );
    }

    expect(allowed('estimate'), isTrue);
    expect(allowed('work_order'), isTrue);
    expect(allowed('work_order_status'), isTrue);
    expect(allowed('nota_adjustment'), isTrue);
    expect(allowed('estimate', role: 'MEKANIK'), isFalse);
    expect(allowed('nota_adjustment', role: 'MEKANIK'), isFalse);
    expect(
      allowed('estimate', role: 'MEKANIK', extras: {'buat_estimasi'}),
      isTrue,
    );
    expect(allowed('harga_jasa', extras: {'ubah_harga_jasa'}), isFalse);
    expect(allowed('salary'), isFalse);
  });

  test('petunjuk entity/action yang dibatasi ikut ditandatangani', () {
    expect(
      envelopeHintFields(
        storeId: 'utama',
        senderDeviceId: 'dev-1',
        entity: 'nota',
        action: 'upsert',
        entityId: 'nota-1',
        idempotencyKey: 'idem-1',
      ),
      {
        'store_id': 'utama',
        'sender_device_id': 'dev-1',
        'entity': 'nota',
        'action': 'upsert',
        'entity_id': 'nota-1',
        'idempotency_key': 'idem-1',
      },
    );
  });
}
