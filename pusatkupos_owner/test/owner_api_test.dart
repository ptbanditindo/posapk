import 'package:flutter_test/flutter_test.dart';
import 'package:pusatkupos_owner/owner_api.dart';

void main() {
  test('alamat relay owner wajib https kecuali localhost debug', () {
    final secure = OwnerApi(
      baseUrl: 'https://relay.contoh.com/',
      enrollToken: 'token',
      ownerId: 'owner',
    );
    expect(secure.baseUrl, 'https://relay.contoh.com');

    expect(
      () => OwnerApi(
        baseUrl: 'http://relay.contoh.com',
        enrollToken: 'token',
        ownerId: 'owner',
      ),
      throwsArgumentError,
    );

    final local = OwnerApi(
      baseUrl: 'http://127.0.0.1:8120',
      enrollToken: 'token',
      ownerId: 'owner',
    );
    expect(local.baseUrl, 'http://127.0.0.1:8120');
  });
}
