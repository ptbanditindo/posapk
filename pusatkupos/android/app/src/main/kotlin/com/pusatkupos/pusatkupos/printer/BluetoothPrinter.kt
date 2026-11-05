package com.pusatkupos.pusatkupos.printer

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import java.util.Locale
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * Satu koneksi Bluetooth Classic SPP pada satu waktu. Koneksi hanya menutup
 * socket; pasangan Bluetooth pengguna tidak pernah dihapus.
 */
class BluetoothPrinter(private val activity: Activity) {

    private var socket: BluetoothSocket? = null
    private var activeAddress: String? = null
    private var activeName: String? = null

    private val adapter: BluetoothAdapter?
        get() = (activity.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)
            ?.adapter

    fun ensurePermissions(discovery: Boolean) {
        val missing = missingPermissions(discovery)
        if (missing.isNotEmpty()) {
            throw PrinterFailure(
                "PERMISSION_DENIED",
                if (discovery) {
                    "Izin Bluetooth dan lokasi diperlukan untuk mencari printer. " +
                        "Pilih Izinkan saat aplikasi meminta akses."
                } else {
                    "Izin Bluetooth diperlukan untuk menghubungkan printer."
                },
            )
        }
    }

    fun discover(): List<Map<String, Any?>> {
        val bluetooth = requireAdapter()
        ensureEnabled(bluetooth)
        val merged = LinkedHashMap<String, Map<String, Any?>>()
        bluetooth.bondedDevices.forEach { device ->
            merged[device.address] = describe(device, paired = true)
        }
        discoverNearby(bluetooth).forEach { device ->
            merged.putIfAbsent(device.address, describe(device, paired = false))
        }
        return merged.values.sortedBy { (it["name"] as String).lowercase(Locale.US) }
    }

    fun connect(address: String): Map<String, Any?> {
        val bluetooth = requireAdapter()
        ensureEnabled(bluetooth)
        val normalized = normalizeAddress(address)
            ?: throw PrinterFailure(
                "INVALID_ADDRESS",
                "Alamat Bluetooth printer tidak valid (contoh AA:BB:CC:DD:EE:FF).",
            )
        if (socket?.isConnected == true && activeAddress == normalized) {
            return mapOf("name" to activeName, "address" to normalized)
        }
        closeSocket()
        val device = try {
            bluetooth.getRemoteDevice(normalized)
        } catch (error: IllegalArgumentException) {
            throw PrinterFailure("INVALID_ADDRESS", "Alamat Bluetooth printer tidak valid.")
        }
        if (device.bondState != BluetoothDevice.BOND_BONDED) {
            throw PrinterFailure(
                "DEVICE_NOT_PAIRED",
                "Printer belum dipasangkan. Pasangkan lewat Pengaturan Bluetooth " +
                    "Android, lalu hubungkan kembali.",
            )
        }
        runCatching { bluetooth.cancelDiscovery() }
        val name = runCatching { device.name }.getOrNull()?.trim().orEmpty()
        val created = try {
            device.createRfcommSocketToServiceRecord(SPP_UUID)
        } catch (error: Throwable) {
            throw PrinterFailure(
                "UNSUPPORTED_SPP",
                "Printer tidak menyediakan layanan Bluetooth Classic SPP. " +
                    "Gunakan Bluetooth LE bila printer mendukungnya.",
            )
        }
        socket = created
        try {
            withTimeout(CONNECT_TIMEOUT_MS) { created.connect() }
        } catch (error: PrinterFailure) {
            closeSocket()
            throw error
        } catch (error: Throwable) {
            closeSocket()
            throw PrinterFailure(
                "CONNECT_FAILED",
                "Gagal terhubung ke printer Bluetooth. Pastikan printer menyala, " +
                    "sudah dipasangkan, dan tidak dipakai perangkat lain. " +
                    (error.message ?: ""),
            )
        }
        if (!created.isConnected) {
            closeSocket()
            throw PrinterFailure(
                "CONNECT_FAILED",
                "Printer tidak melaporkan koneksi berhasil. Coba hubungkan ulang.",
            )
        }
        activeAddress = normalized
        activeName = name.ifEmpty { "Printer Bluetooth" }
        return mapOf("name" to activeName, "address" to normalized)
    }

    fun send(address: String, bytes: ByteArray) {
        if (bytes.isEmpty()) {
            throw PrinterFailure("INVALID_PAYLOAD", "Data cetak kosong.")
        }
        if (bytes.size > MAX_PRINT_BYTES) {
            throw PrinterFailure(
                "INVALID_PAYLOAD",
                "Data cetak terlalu besar untuk printer Bluetooth.",
            )
        }
        val normalized = normalizeAddress(address)
            ?: throw PrinterFailure(
                "INVALID_ADDRESS",
                "Alamat Bluetooth printer tidak valid (contoh AA:BB:CC:DD:EE:FF).",
            )
        if (socket?.isConnected != true || activeAddress != normalized) {
            connect(normalized)
        }
        val current = socket
        if (current == null || current.isConnected != true) {
            closeSocket()
            throw PrinterFailure(
                "DISCONNECTED",
                "Printer Bluetooth belum terhubung. Hubungkan lalu coba lagi.",
            )
        }
        val chunks = (bytes.size + WRITE_CHUNK_BYTES - 1) / WRITE_CHUNK_BYTES
        val timeout = (PRINT_TIMEOUT_MS + chunks * (WRITE_GAP_MS + 20L))
            .coerceAtMost(MAX_PRINT_TIMEOUT_MS)
        try {
            withTimeout(timeout) {
                val output = current.outputStream
                var offset = 0
                while (offset < bytes.size) {
                    val chunk = minOf(bytes.size - offset, WRITE_CHUNK_BYTES)
                    output.write(bytes, offset, chunk)
                    output.flush()
                    offset += chunk
                    if (offset < bytes.size) Thread.sleep(WRITE_GAP_MS)
                }
            }
        } catch (error: PrinterFailure) {
            closeSocket()
            throw error
        } catch (error: Throwable) {
            closeSocket()
            throw PrinterFailure(
                "PRINT_FAILED",
                "Gagal mengirim struk ke printer Bluetooth. " +
                    (error.message ?: "Periksa koneksi printer."),
            )
        }
    }

    fun disconnect() = closeSocket()

    fun status(): Map<String, Any?> {
        val bluetooth = adapter ?: return mapOf(
            "supported" to false,
            "permissionsGranted" to true,
            "enabled" to false,
            "connected" to false,
            "message" to "Perangkat ini tidak memiliki Bluetooth.",
        )
        val permitted = missingPermissions(discovery = false).isEmpty()
        val enabled = runCatching { bluetooth.isEnabled }.getOrDefault(false)
        return mapOf(
            "supported" to true,
            "permissionsGranted" to permitted,
            "enabled" to enabled,
            "connected" to (socket?.isConnected == true),
            "address" to activeAddress,
            "name" to activeName,
            "message" to when {
                !permitted -> "Izin Bluetooth belum diberikan."
                !enabled -> "Bluetooth perangkat sedang nonaktif."
                socket?.isConnected == true -> null
                else -> "Printer belum terhubung."
            },
        )
    }

    private fun discoverNearby(bluetooth: BluetoothAdapter): List<BluetoothDevice> {
        val found = LinkedHashMap<String, BluetoothDevice>()
        val finished = CountDownLatch(1)
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                when (intent?.action) {
                    BluetoothDevice.ACTION_FOUND -> {
                        val device = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            intent.getParcelableExtra(
                                BluetoothDevice.EXTRA_DEVICE,
                                BluetoothDevice::class.java,
                            )
                        } else {
                            @Suppress("DEPRECATION")
                            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                        }
                        if (device != null) found[device.address] = device
                    }

                    BluetoothAdapter.ACTION_DISCOVERY_FINISHED -> finished.countDown()
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(BluetoothDevice.ACTION_FOUND)
            addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED)
        }
        return try {
            registerReceiver(receiver, filter, exported = true)
            runCatching { bluetooth.cancelDiscovery() }
            if (!bluetooth.startDiscovery()) {
                throw PrinterFailure(
                    "DISCOVERY_FAILED",
                    "Pencarian printer tidak dapat dimulai. Matikan lalu nyalakan " +
                        "Bluetooth, kemudian coba lagi.",
                )
            }
            finished.await(DISCOVERY_WINDOW_MS, TimeUnit.MILLISECONDS)
            found.values.toList()
        } finally {
            runCatching { bluetooth.cancelDiscovery() }
            runCatching { activity.unregisterReceiver(receiver) }
        }
    }

    private fun describe(device: BluetoothDevice, paired: Boolean): Map<String, Any?> {
        val name = runCatching { device.name }.getOrNull()?.trim().orEmpty()
        return mapOf(
            "name" to name.ifEmpty { "Printer Bluetooth" },
            "address" to device.address.uppercase(Locale.US),
            "paired" to paired,
            "detail" to if (paired) "SPP · sudah dipasangkan" else "SPP · baru ditemukan",
        )
    }

    private fun requireAdapter(): BluetoothAdapter =
        adapter ?: throw PrinterFailure(
            "BLUETOOTH_UNSUPPORTED",
            "Perangkat ini tidak memiliki Bluetooth.",
        )

    private fun ensureEnabled(bluetooth: BluetoothAdapter) {
        val enabled = runCatching { bluetooth.isEnabled }.getOrDefault(false)
        if (!enabled) {
            throw PrinterFailure(
                "BLUETOOTH_DISABLED",
                "Bluetooth perangkat sedang nonaktif. Aktifkan Bluetooth lalu coba lagi.",
            )
        }
    }

    private fun missingPermissions(discovery: Boolean): List<String> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return emptyList()
        val required = buildList {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                add(Manifest.permission.BLUETOOTH_CONNECT)
                if (discovery) add(Manifest.permission.BLUETOOTH_SCAN)
            } else if (discovery) {
                add(Manifest.permission.ACCESS_FINE_LOCATION)
            }
        }
        return required.filter {
            activity.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
    }

    private fun registerReceiver(
        receiver: BroadcastReceiver,
        filter: IntentFilter,
        exported: Boolean,
    ) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.registerReceiver(
                receiver,
                filter,
                if (exported) Context.RECEIVER_EXPORTED else Context.RECEIVER_NOT_EXPORTED,
            )
        } else {
            @Suppress("DEPRECATION")
            activity.registerReceiver(receiver, filter)
        }
    }

    private fun closeSocket() {
        val current = socket
        socket = null
        activeAddress = null
        activeName = null
        runCatching { current?.close() }
    }

    private fun <T> withTimeout(timeoutMs: Long, action: () -> T): T {
        val result = AtomicReference<T?>()
        val failure = AtomicReference<Throwable?>()
        val worker = Thread {
            try {
                result.set(action())
            } catch (error: Throwable) {
                failure.set(error)
            }
        }
        worker.isDaemon = true
        worker.name = "pusatkupos-bt-printer"
        worker.start()
        worker.join(timeoutMs)
        if (worker.isAlive) {
            closeSocket()
            worker.join(1_000L)
            throw PrinterFailure(
                "TIMEOUT",
                "Printer tidak merespons tepat waktu. Pastikan printer menyala " +
                    "dan dalam jangkauan, lalu coba lagi.",
            )
        }
        failure.get()?.let { throw it }
        return result.get() as T
    }

    private fun normalizeAddress(value: String): String? {
        val clean = value.trim().uppercase(Locale.US)
        return if (ADDRESS_PATTERN.matches(clean)) clean else null
    }

    companion object {
        val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
        private val ADDRESS_PATTERN =
            Regex("^([0-9A-F]{2}:){5}[0-9A-F]{2}$")
        private const val CONNECT_TIMEOUT_MS = 15_000L
        private const val PRINT_TIMEOUT_MS = 20_000L
        private const val MAX_PRINT_TIMEOUT_MS = 120_000L
        private const val DISCOVERY_WINDOW_MS = 8_000L
        private const val WRITE_CHUNK_BYTES = 128
        private const val WRITE_GAP_MS = 20L
        private const val MAX_PRINT_BYTES = 512 * 1024
    }
}
