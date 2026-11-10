import 'package:flutter/material.dart';

import '../../data/store_registry.dart';

class StoreSwitcherDialog extends StatelessWidget {
  const StoreSwitcherDialog({
    super.key,
    required this.stores,
    required this.activeId,
  });

  final List<StoreRecord> stores;
  final String activeId;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Pilih toko aktif'),
      content: SizedBox(
        width: 420,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final store in stores)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  store.storeId == activeId
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: store.storeId == activeId
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                title: Text(store.nama),
                subtitle: Text(
                  store.alamat.isEmpty ? store.storeId : store.alamat,
                ),
                onTap: () => Navigator.pop(context, store),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Batal'),
        ),
      ],
    );
  }
}
