import 'dart:convert';

import 'app_database.dart';
import 'receipt_template.dart';

/// Pengaturan struk v2. Satu JSON di `app_meta` menggantikan 25 kunci
/// `receipt.<field>` lama. Data lama tetap dibaca sebagai migrasi satu arah.
class ReceiptSettings {
  ReceiptSettings._();

  static final ReceiptSettings instance = ReceiptSettings._();

  static const templateKey = 'receipt.template.v2';

  Future<ReceiptTemplate> load() async {
    final raw = await AppDatabase.instance.getSetting(templateKey);
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          return ReceiptTemplate.fromJson(decoded.cast<String, Object?>());
        }
      } catch (_) {
        // JSON rusak: pakai nilai lama agar struk tetap dapat dicetak.
      }
    }
    return _migrateLegacy();
  }

  Future<void> save(ReceiptTemplate template) async {
    template.validate();
    await AppDatabase.instance.setSetting(
      templateKey,
      jsonEncode(template.toJson()),
    );
  }

  Future<void> reset() => save(ReceiptTemplate.defaults());

  Future<ReceiptTemplate> _migrateLegacy() async {
    final db = AppDatabase.instance;
    Future<bool> toggle(String key) async =>
        (await db.getSetting('receipt.$key') ?? '1') == '1';
    final showTagline = await toggle('tagline');
    final showAlamat = await toggle('alamat');
    final showKontak = await toggle('kontak');
    final showJasa = await toggle('jasa');
    final showPart = await toggle('part');
    final showWarranty = await toggle('garansi');
    final showBank = await toggle('rekening');
    final showFooter = await toggle('footer');
    final meta = <String, bool>{};
    for (final key in receiptMetaFields.keys) {
      meta[key] = await toggle(key);
    }
    final totals = <String, bool>{};
    for (final key in receiptTotalFields.keys) {
      totals[key] = await toggle(key);
    }
    final footerText = await db.getSetting('struk.footer');
    final rekening = await db.getSetting('bengkel.rekening');
    final footerLines = (footerText ?? 'Terima kasih')
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    return ReceiptTemplate(
      showTagline: showTagline,
      showAlamat: showAlamat,
      showKontak: showKontak,
      showJasa: showJasa,
      showPart: showPart,
      metaFields: meta,
      totalFields: totals,
      warrantyShowStatus: showWarranty,
      warrantyShowNote: showWarranty,
      bankCatatan: (rekening ?? '').trim(),
      blockVisible: {
        'items': showJasa || showPart,
        'warranty': showWarranty,
        'bank': showBank,
        'footer': showFooter,
      },
      footerLines: footerLines,
    );
  }
}
