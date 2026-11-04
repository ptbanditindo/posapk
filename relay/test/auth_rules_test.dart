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
    expect(employeeEntityAllowed(
      entity: 'harga_jasa',
      action: 'upsert',
      roleBase: 'TEKNISI',
      extras: {},
    ), isFalse);
    expect(employeeEntityAllowed(
      entity: 'harga_jasa',
      action: 'upsert',
      roleBase: 'TEKNISI',
      extras: {'ubah_harga_jasa'},
    ), isTrue);
    expect(employeeEntityAllowed(
      entity: 'stock',
      action: 'upsert',
      roleBase: 'KASIR',
      extras: {},
    ), isFalse);
    expect(employeeEntityAllowed(
      entity: 'stock',
      action: 'delta',
      roleBase: 'TEKNISI',
      extras: {},
    ), isTrue);
    expect(employeeEntityAllowed(
      entity: 'stock',
      action: 'upsert',
      roleBase: 'TEKNISI',
      extras: {'ubah_stok'},
    ), isTrue);
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
