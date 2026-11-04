package com.pusatkupos.pusatkupos.printer

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * USB Host (OTG) untuk printer ESC/POS dengan endpoint BULK OUT. Printer
 * yang membutuhkan driver vendor khusus tidak diklaim kompatibel.
 */
class UsbPrinter(private val activity: Activity) {

    private val manager: UsbManager? =
        activity.getSystemService(Context.USB_SERVICE) as? UsbManager
    private val permissionAction = "${activity.packageName}.PUSATKUPOS_USB_PERMISSION"

    private var connection: UsbDeviceConnection? = null
    private var usbInterface: UsbInterface? = null
    private var endpoint: UsbEndpoint? = null
    private var activeIdentity: String? = null
    private var activeName: String? = null

    private val supported: Boolean
        get() = manager != null &&
            activity.packageManager.hasSystemFeature(android.content.pm.PackageManager.FEATURE_USB_HOST)

    fun discover(): List<Map<String, Any?>> {
        if (!supported) {
            throw PrinterFailure(
                "USB_UNSUPPORTED",
                "Perangkat ini tidak mendukung USB Host (OTG).",
            )
        }
        return manager?.deviceList?.values
            ?.map { describe(it) }
            ?.sortedBy { it["identity"] as String }
            .orEmpty()
    }

    fun connect(identity: String) {
        val usbManager = manager
        if (!supported || usbManager == null) {
            throw PrinterFailure(
                "USB_UNSUPPORTED",
                "Perangkat ini tidak mendukung USB Host (OTG).",
            )
        }
        val normalized = normalizeIdentity(identity)
            ?: throw PrinterFailure(
                "INVALID_ADDRESS",
                "Identitas perangkat USB tidak valid. Pilih printer dari pencarian USB.",
            )
        var device = findDevice(normalized)
            ?: throw PrinterFailure(
                "DEVICE_NOT_FOUND",
                "Printer USB tidak ditemukan. Sambungkan kabel OTG lalu cari ulang.",
            )
        if (!usbManager.hasPermission(device)) {
            when (requestPermission(device)) {
                PermissionResult.GRANTED -> Unit
                PermissionResult.DENIED -> throw PrinterFailure(
                    "USB_PERMISSION_DENIED",
                    "Izin akses USB ditolak. Setujui izin lalu hubungkan kembali.",
                )
                PermissionResult.TIMEOUT -> throw PrinterFailure(
                    "TIMEOUT",
                    "Permintaan izin USB tidak dijawab. Setujui dialog Android lalu coba lagi.",
                )
            }
            device = findDevice(normalized)
                ?: throw PrinterFailure(
                    "DEVICE_NOT_FOUND",
                    "Perangkat USB terputus saat menunggu izin.",
                )
        }
        val selection = selectInterface(device)
            ?: throw PrinterFailure(
                "UNSUPPORTED_USB",
                "Perangkat USB ini tidak menyediakan endpoint BULK OUT untuk ESC/POS.",
            )
        closeConnection()
        val opened = usbManager.openDevice(device)
            ?: throw PrinterFailure(
                "CONNECT_FAILED",
                "Printer USB tidak dapat dibuka. Cabut lalu sambungkan kembali kabel.",
            )
        if (!opened.claimInterface(selection.first, true)) {
            runCatching { opened.close() }
            throw PrinterFailure(
                "CONNECT_FAILED",
                "Interface printer USB sedang dipakai aplikasi lain.",
            )
        }
        connection = opened
        usbInterface = selection.first
        endpoint = selection.second
        activeIdentity = normalized
        activeName = describe(device)["name"] as? String
    }

    fun send(identity: String, bytes: ByteArray) {
        if (bytes.isEmpty()) {
            throw PrinterFailure("INVALID_PAYLOAD", "Data cetak kosong.")
        }
        if (bytes.size > MAX_PRINT_BYTES) {
            throw PrinterFailure(
                "INVALID_PAYLOAD",
                "Data cetak terlalu besar untuk printer USB.",
            )
        }
        val normalized = normalizeIdentity(identity)
        val active = connection
        if (active == null || activeIdentity != normalized) {
            connect(identity)
        }
        val conn = connection
        val target = endpoint
        if (conn == null || target == null) {
            throw PrinterFailure(
                "DISCONNECTED",
                "Printer USB belum terhubung. Hubungkan lalu coba lagi.",
            )
        }
        var offset = 0
        while (offset < bytes.size) {
            val chunk = minOf(bytes.size - offset, WRITE_CHUNK_BYTES)
            val sent = conn.bulkTransfer(target, bytes, offset, chunk, WRITE_TIMEOUT_MS)
            if (sent <= 0) {
                closeConnection()
                throw PrinterFailure(
                    "PRINT_FAILED",
                    "Data struk gagal dikirim ke printer USB (kode $sent).",
                )
            }
            offset += sent
        }
    }

    fun disconnect() = closeConnection()

    fun status(): Map<String, Any?> {
        if (!supported) {
            return mapOf(
                "supported" to false,
                "connected" to false,
                "message" to "Perangkat ini tidak mendukung USB Host (OTG).",
            )
        }
        val active = connection
        return mapOf(
            "supported" to true,
            "connected" to (active != null),
            "identity" to activeIdentity,
            "name" to activeName,
            "message" to if (active == null) "Printer USB belum terhubung." else null,
        )
    }

    private fun findDevice(identity: String): UsbDevice? {
        return manager?.deviceList?.values?.firstOrNull {
            identityOf(it) == identity
        }
    }

    private fun describe(device: UsbDevice): Map<String, Any?> {
        val name = runCatching { device.productName }
            .getOrNull()
            ?.takeIf { it.isNotBlank() }
            ?: String.format(Locale.ROOT, "USB %04X:%04X", device.vendorId, device.productId)
        val selection = selectInterface(device)
        return mapOf(
            "identity" to identityOf(device),
            "name" to name,
            "address" to identityOf(device),
            "supported" to (selection != null),
            "detail" to if (selection == null) {
                "Tanpa endpoint BULK OUT"
            } else {
                "USB · BULK OUT"
            },
        )
    }

    private fun identityOf(device: UsbDevice): String =
        String.format(Locale.ROOT, "usb:%04x:%04x", device.vendorId, device.productId)

    private fun selectInterface(device: UsbDevice): Pair<UsbInterface, UsbEndpoint>? {
        var fallback: Pair<UsbInterface, UsbEndpoint>? = null
        for (index in 0 until device.interfaceCount) {
            val iface = device.getInterface(index)
            for (endpointIndex in 0 until iface.endpointCount) {
                val candidate = iface.getEndpoint(endpointIndex)
                val bulkOut = candidate.direction == UsbConstants.USB_DIR_OUT &&
                    candidate.type == UsbConstants.USB_ENDPOINT_XFER_BULK
                if (!bulkOut) continue
                if (iface.interfaceClass == UsbConstants.USB_CLASS_PRINTER) {
                    return iface to candidate
                }
                if (fallback == null) fallback = iface to candidate
            }
        }
        return fallback
    }

    private fun normalizeIdentity(value: String): String? {
        val match = IDENTITY_PATTERN.matchEntire(value.trim()) ?: return null
        val vendor = match.groupValues[1].toInt(16)
        val product = match.groupValues[2].toInt(16)
        return String.format(Locale.ROOT, "usb:%04x:%04x", vendor, product)
    }

    private fun requestPermission(device: UsbDevice): PermissionResult {
        val usbManager = manager ?: return PermissionResult.DENIED
        if (usbManager.hasPermission(device)) return PermissionResult.GRANTED
        val answered = CountDownLatch(1)
        val granted = AtomicBoolean(false)
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action != permissionAction) return
                val target = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
                }
                if (target != null && target.deviceId != device.deviceId) return
                granted.set(intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false))
                answered.countDown()
            }
        }
        try {
            registerReceiver(receiver)
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    PendingIntent.FLAG_MUTABLE
                } else {
                    0
                }
            val pending = PendingIntent.getBroadcast(
                activity,
                0,
                Intent(permissionAction).setPackage(activity.packageName),
                flags,
            )
            activity.runOnUiThread {
                runCatching { usbManager.requestPermission(device, pending) }
            }
            if (!answered.await(PERMISSION_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                return PermissionResult.TIMEOUT
            }
            return if (granted.get()) {
                PermissionResult.GRANTED
            } else {
                PermissionResult.DENIED
            }
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()
            return PermissionResult.TIMEOUT
        } finally {
            runCatching { activity.unregisterReceiver(receiver) }
        }
    }

    private fun registerReceiver(receiver: BroadcastReceiver) {
        val filter = IntentFilter(permissionAction)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            activity.registerReceiver(receiver, filter)
        }
    }

    private fun closeConnection() {
        val active = connection
        val iface = usbInterface
        connection = null
        usbInterface = null
        endpoint = null
        activeIdentity = null
        activeName = null
        if (active != null && iface != null) {
            runCatching { active.releaseInterface(iface) }
        }
        runCatching { active?.close() }
    }

    private enum class PermissionResult { GRANTED, DENIED, TIMEOUT }

    companion object {
        private val IDENTITY_PATTERN =
            Regex("^usb:([0-9A-Fa-f]{4}):([0-9A-Fa-f]{4})$", RegexOption.IGNORE_CASE)
        private const val PERMISSION_TIMEOUT_MS = 60_000L
        private const val WRITE_CHUNK_BYTES = 8 * 1024
        private const val WRITE_TIMEOUT_MS = 5_000
        private const val MAX_PRINT_BYTES = 512 * 1024
    }
}
