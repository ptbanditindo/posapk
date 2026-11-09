import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_harness.dart';

void main() {
  testWidgets('harness widget merender halaman kerangka', (tester) async {
    await pumpTestWidget(
      tester,
      const Scaffold(body: Center(child: Text('kerangka alur kritis'))),
    );

    expect(find.text('kerangka alur kritis'), findsOneWidget);
  });
}
