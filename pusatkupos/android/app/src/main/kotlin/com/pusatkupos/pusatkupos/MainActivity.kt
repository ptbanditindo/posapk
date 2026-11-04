package com.pusatkupos.pusatkupos

import com.pusatkupos.pusatkupos.printer.PrinterBridge
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    private var printerBridge: PrinterBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        printerBridge = PrinterBridge(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        printerBridge?.onRequestPermissionsResult(requestCode, grantResults)
    }

    override fun onDestroy() {
        printerBridge?.dispose()
        printerBridge = null
        super.onDestroy()
    }
}
