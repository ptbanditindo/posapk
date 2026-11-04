import 'dart:io';

Future<void> sendNetwork(String host, int port, List<int> bytes) async {
  final socket = await Socket.connect(
    host.trim(),
    port,
    timeout: const Duration(seconds: 6),
  );
  try {
    socket.add(bytes);
    await socket.flush();
  } finally {
    await socket.close();
    socket.destroy();
  }
}
