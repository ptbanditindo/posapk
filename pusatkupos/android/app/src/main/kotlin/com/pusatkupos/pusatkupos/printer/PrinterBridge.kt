package com.pusatkupos.pusatkupos.printer

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class PrinterFailure(val code: String, message: String) : Exception(message)

/**
 * Jembatan transport printer native. Semua operasi socket/USB berjalan di
 * thread latar agar UI Flutter tidak membeku; hasil dikirim balik ke main
 * thread.
 */
class PrinterBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL)
    private val executor = Executors.newSingleThreadExecutor()
    private val bluetooth = BluetoothPrinter(activity)
    private val usb = UsbPrinter(activity)
    private val system = SystemPrinter(activity)
    private var pendingPermission: MethodChannel.Result? = null
    private var nsdManager: NsdManager? = null
    private var nsdListener: NsdManager.DiscoveryListener? = null

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "requestPermissions" ->
                ensurePermissions(call.argument<Boolean>("discovery") == true, result)

            "scanBluetoothClassic" -> runAsync(result) {
                bluetooth.ensurePermissions(discovery = true)
                mapOf("devices" to bluetooth.discover())
            }

            "connectBluetoothClassic" -> runAsync(result) {
                bluetooth.ensurePermissions(discovery = false)
                val address = call.argument<String>("address").orEmpty()
                mapOf("device" to bluetooth.connect(address))
            }

            "sendBluetoothClassic" -> runAsync(result) {
                bluetooth.send(call.argument<ByteArray>("bytes") ?: ByteArray(0))
                null
            }

            "disconnectBluetoothClassic" -> runAsync(result) {
                bluetooth.disconnect()
                null
            }

            "scanUsb" -> runAsync(result) {
                mapOf("devices" to usb.discover())
            }

            "connectUsb" -> runAsync(result) {
                usb.connect(call.argument<String>("identity").orEmpty())
                null
            }

            "sendUsb" -> runAsync(result) {
                usb.send(
                    call.argument<String>("identity").orEmpty(),
                    call.argument<ByteArray>("bytes") ?: ByteArray(0),
                )
                null
            }

            "disconnectUsb" -> runAsync(result) {
                usb.disconnect()
                null
            }

            "scanNetwork" -> {
                executor.execute {
                    val devices = try {
                        discoverNetwork()
                    } catch (_: Throwable) {
                        emptyList<Map<String, Any?>>()
                    }
                    activity.runOnUiThread {
                        result.success(mapOf("devices" to devices))
                    }
                }
            }

            "printSystem" -> runAsync(result) {
                system.submit(
                    title = call.argument<String>("title").orEmpty(),
                    text = call.argument<String>("text").orEmpty(),
                    paperMm = call.argument<Int>("paperMm") ?: 58,
                )
            }

            "status" -> result.success(status())
            else -> result.notImplemented()
        }
    }

    fun onRequestPermissionsResult(
        requestCode: Int,
        grantResults: IntArray,
    ) {
        if (requestCode != PERMISSION_REQUEST) return
        val pending = pendingPermission ?: return
        pendingPermission = null
        if (grantResults.isNotEmpty() &&
            grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        ) {
            pending.success(null)
        } else {
            pending.error(
                "PERMISSION_DENIED",
                "Izin Bluetooth ditolak. Setujui izin saat aplikasi meminta akses.",
                null,
            )
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        bluetooth.disconnect()
        usb.disconnect()
        stopNetworkDiscovery()
        executor.shutdownNow()
    }

    private fun ensurePermissions(discovery: Boolean, result: MethodChannel.Result) {
        val missing = missingPermissions(discovery)
        if (missing.isEmpty()) {
            result.success(null)
            return
        }
        if (pendingPermission != null) {
            result.error(
                "PERMISSION_PENDING",
                "Permintaan izin sebelumnya belum dijawab.",
                null,
            )
            return
        }
        pendingPermission = result
        activity.requestPermissions(missing.toTypedArray(), PERMISSION_REQUEST)
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

    private fun status(): Map<String, Any?> {
        val bt = bluetooth.status()
        val usbStatus = usb.status()
        return mapOf(
            "bluetooth" to bt,
            "usb" to usbStatus,
            "system" to mapOf(
                "supported" to system.isSupported,
                "permissionsGranted" to missingPermissions(false).isEmpty(),
                "connected" to system.isSupported,
            ),
        )
    }

    private fun discoverNetwork(): List<Map<String, Any?>> {
        val manager = activity.getSystemService(Context.NSD_SERVICE) as? NsdManager
            ?: return emptyList()
        val found = LinkedHashMap<String, Map<String, Any?>>()
        val finished = CountDownLatch(1)
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String?) = Unit

            override fun onServiceFound(service: NsdServiceInfo?) {
                val info = service ?: return
                runCatching {
                    manager.resolveService(info, object : NsdManager.ResolveListener {
                        override fun onResolveFailed(serviceInfo: NsdServiceInfo?, errorCode: Int) =
                            Unit

                        override fun onServiceResolved(resolved: NsdServiceInfo?) {
                            val host = resolved?.host?.hostAddress ?: return
                            if (host.contains(':')) return
                            val name = resolved.serviceName?.trim().orEmpty()
                            found[host] = mapOf(
                                "name" to name.ifEmpty { "Printer Jaringan" },
                                "address" to host,
                                "detail" to "Port ${resolved.port}",
                                "port" to resolved.port,
                            )
                        }
                    })
                }
            }

            override fun onServiceLost(service: NsdServiceInfo?) = Unit

            override fun onDiscoveryStopped(serviceType: String?) {
                finished.countDown()
            }

            override fun onStartDiscoveryFailed(serviceType: String?, errorCode: Int) {
                finished.countDown()
            }

            override fun onStopDiscoveryFailed(serviceType: String?, errorCode: Int) {
                finished.countDown()
            }
        }
        return try {
            stopNetworkDiscovery()
            nsdManager = manager
            nsdListener = listener
            manager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
            finished.await(DISCOVERY_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            found.values.toList()
        } finally {
            stopNetworkDiscovery()
        }
    }

    private fun stopNetworkDiscovery() {
        val manager = nsdManager
        val listener = nsdListener
        nsdManager = null
        nsdListener = null
        if (manager != null && listener != null) {
            runCatching { manager.stopServiceDiscovery(listener) }
        }
    }

    private fun runAsync(result: MethodChannel.Result, block: () -> Any?) {
        executor.execute {
            try {
                val value = block()
                activity.runOnUiThread { result.success(value) }
            } catch (error: PrinterFailure) {
                activity.runOnUiThread { result.error(error.code, error.message, null) }
            } catch (error: SecurityException) {
                activity.runOnUiThread {
                    result.error(
                        "PERMISSION_DENIED",
                        "Izin printer belum lengkap. Pilih Izinkan saat aplikasi meminta akses.",
                        null,
                    )
                }
            } catch (error: Throwable) {
                activity.runOnUiThread {
                    result.error(
                        "PRINTER_ERROR",
                        error.message?.trim()?.ifEmpty { null }
                            ?: "Perintah printer gagal dijalankan.",
                        null,
                    )
                }
            }
        }
    }

    companion object {
        const val CHANNEL = "pusatkupos/printer"
        private const val PERMISSION_REQUEST = 7301
        private const val SERVICE_TYPE = "_pdl-datastream._tcp"
        private const val DISCOVERY_TIMEOUT_MS = 6_000L
    }
}
