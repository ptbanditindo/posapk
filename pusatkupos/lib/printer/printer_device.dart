/// Hasil pencarian perangkat printer dari adapter transport.
class PrinterDevice {
  const PrinterDevice({
    required this.connectionType,
    required this.name,
    required this.address,
    this.transport = '',
    this.paired = true,
    this.supported = true,
    this.detail = '',
  });

  final String connectionType;
  final String name;
  final String address;
  final String transport;
  final bool paired;
  final bool supported;
  final String detail;

  String get label {
    if (detail.isEmpty) return name;
    return '$name · $detail';
  }

  factory PrinterDevice.fromMap(
    String connectionType,
    Map<Object?, Object?> map, {
    String transport = '',
  }) {
    return PrinterDevice(
      connectionType: connectionType,
      name: '${map['name'] ?? 'Printer'}',
      address: '${map['address'] ?? ''}',
      transport: '${map['transport'] ?? transport}',
      paired: map['paired'] != false,
      supported: map['supported'] != false,
      detail: '${map['detail'] ?? ''}',
    );
  }
}
