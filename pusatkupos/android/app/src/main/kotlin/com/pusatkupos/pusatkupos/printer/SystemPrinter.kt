package com.pusatkupos.pusatkupos.printer

import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.os.Bundle
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.print.PageRange
import android.print.PrintAttributes
import android.print.PrintDocumentAdapter
import android.print.PrintDocumentInfo
import android.print.PrintJob
import android.print.PrintManager
import android.print.pdf.PrintedPdfDocument
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.roundToInt

/** Membungkus Android Print Framework untuk struk teks 58/80 mm. */
class SystemPrinter(private val activity: Activity) {

    private val manager: PrintManager? =
        activity.getSystemService(Context.PRINT_SERVICE) as? PrintManager
    private val jobs = LinkedHashMap<Int, PrintJob>()
    private var nextJobId = 0

    val isSupported: Boolean
        get() = manager != null

    fun submit(
        title: String,
        text: String,
        paperMm: Int,
    ): Map<String, Any?> {
        val printManager = manager ?: throw PrinterFailure(
            "SYSTEM_PRINT_UNAVAILABLE",
            "Android Print tidak tersedia. Gunakan Bluetooth, jaringan, atau USB.",
        )
        val lines = sanitize(text.split('\n'))
        if (lines.isEmpty()) {
            throw PrinterFailure(
                "INVALID_PAYLOAD",
                "Struk tidak memiliki teks untuk dicetak.",
            )
        }
        val width = if (paperMm == 80) 80 else 58
        val safeTitle = title.trim().take(80).ifEmpty { "Struk PusatkuPOS" }
        val pages = lines.chunked(linesPerPage(width))
        val latch = CountDownLatch(1)
        val result = AtomicReference<Map<String, Any?>?>()
        val failure = AtomicReference<Throwable?>()
        activity.runOnUiThread {
            try {
                val adapter = ThermalAdapter(
                    context = activity.applicationContext,
                    title = safeTitle,
                    lines = lines,
                    paperWidth = width,
                )
                val job = printManager.print(safeTitle, adapter, attributes(width))
                val jobId = synchronized(this) {
                    nextJobId += 1
                    jobs[nextJobId] = job
                    while (jobs.size > 10) {
                        jobs.remove(jobs.keys.first())
                    }
                    nextJobId
                }
                result.set(
                    mapOf(
                        "jobId" to jobId,
                        "title" to safeTitle,
                        "paperWidth" to width,
                        "pages" to pages.size,
                        "lines" to lines.size,
                    ),
                )
            } catch (error: Throwable) {
                failure.set(error)
            } finally {
                latch.countDown()
            }
        }
        val opened = try {
            latch.await(15_000L, TimeUnit.MILLISECONDS)
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
        if (!opened) {
            throw PrinterFailure(
                "TIMEOUT",
                "Dialog cetak Android tidak merespons. Coba lagi.",
            )
        }
        failure.get()?.let {
            throw PrinterFailure(
                "SYSTEM_PRINT_FAILED",
                "Dialog cetak Android gagal dibuka. Pastikan layanan cetak tersedia.",
            )
        }
        return result.get() ?: throw PrinterFailure(
            "SYSTEM_PRINT_FAILED",
            "Pekerjaan cetak Android tidak dapat dibuat.",
        )
    }

    private fun sanitize(lines: List<String>): List<String> {
        val clean = lines.map { it.replace(CONTROL_CHARS, " ").trimEnd() }
        val start = clean.indexOfFirst { it.isNotBlank() }
        if (start < 0) return emptyList()
        val end = clean.indexOfLast { it.isNotBlank() }
        return clean.subList(start, end + 1).toList()
    }

    private fun columns(paperMm: Int): Int = if (paperMm == 80) 48 else 32

    private fun textSize(paperMm: Int): Float = if (paperMm == 80) 9f else 8f

    private fun lineHeight(paperMm: Int): Float = if (paperMm == 80) 11f else 10f

    private fun pageHeightPt(): Int = (100f * PT_PER_INCH / MM_PER_INCH).roundToInt()

    private fun linesPerPage(paperMm: Int): Int {
        val usable = pageHeightPt() - (MARGIN_PT * 2)
        return (usable / lineHeight(paperMm)).toInt().coerceAtLeast(1)
    }

    private fun attributes(paperMm: Int): PrintAttributes {
        val media = PrintAttributes.MediaSize(
            "thermal_${paperMm}mm",
            "Thermal ${paperMm}mm",
            (paperMm * MILS_PER_INCH / MM_PER_INCH).roundToInt(),
            (100f * MILS_PER_INCH / MM_PER_INCH).roundToInt(),
        )
        return PrintAttributes.Builder()
            .setMediaSize(media)
            .setMinMargins(PrintAttributes.Margins.NO_MARGINS)
            .build()
    }

    private inner class ThermalAdapter(
        private val context: Context,
        private val title: String,
        lines: List<String>,
        private val paperWidth: Int,
    ) : PrintDocumentAdapter() {

        private val pages = lines.chunked(linesPerPage(paperWidth))

        override fun onLayout(
            oldAttributes: PrintAttributes?,
            newAttributes: PrintAttributes?,
            cancellationSignal: CancellationSignal?,
            callback: LayoutResultCallback,
            extras: Bundle?,
        ) {
            if (cancellationSignal?.isCanceled == true) {
                callback.onLayoutCancelled()
                return
            }
            if (pages.isEmpty()) {
                callback.onLayoutFailed("Data struk kosong.")
                return
            }
            val info = PrintDocumentInfo.Builder(title)
                .setContentType(PrintDocumentInfo.CONTENT_TYPE_DOCUMENT)
                .setPageCount(pages.size)
                .build()
            callback.onLayoutFinished(info, true)
        }

        override fun onWrite(
            ranges: Array<out PageRange>?,
            destination: ParcelFileDescriptor,
            cancellationSignal: CancellationSignal?,
            callback: WriteResultCallback,
        ) {
            val document = PrintedPdfDocument(context, attributes(paperWidth))
            try {
                val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    color = Color.BLACK
                    typeface = Typeface.MONOSPACE
                    textSize = textSize(paperWidth)
                }
                val height = lineHeight(paperWidth)
                var drawn = 0
                for ((index, pageLines) in pages.withIndex()) {
                    if (cancellationSignal?.isCanceled == true) {
                        callback.onWriteCancelled()
                        return
                    }
                    if (!covers(ranges, index)) continue
                    val page = document.startPage(index + 1)
                    page.canvas.drawColor(Color.WHITE)
                    var y = MARGIN_PT + paint.textSize
                    pageLines.forEach { line ->
                        page.canvas.drawText(line, MARGIN_PT, y, paint)
                        y += height
                    }
                    document.finishPage(page)
                    drawn += 1
                }
                if (drawn == 0) {
                    callback.onWriteFailed("Tidak ada halaman struk yang diminta.")
                    return
                }
                FileOutputStream(destination.fileDescriptor).use { output ->
                    document.writeTo(output)
                }
                callback.onWriteFinished(arrayOf(PageRange.ALL_PAGES))
            } catch (error: IOException) {
                callback.onWriteFailed("Gagal menyiapkan dokumen struk.")
            } catch (error: Throwable) {
                callback.onWriteFailed("Dokumen struk gagal dibuat.")
            } finally {
                document.close()
            }
        }

        private fun covers(ranges: Array<out PageRange>?, pageIndex: Int): Boolean {
            if (ranges == null || ranges.isEmpty()) return true
            if (ranges.any { it == PageRange.ALL_PAGES }) return true
            return ranges.any { pageIndex >= it.start && pageIndex <= it.end }
        }
    }

    companion object {
        private const val MM_PER_INCH = 25.4f
        private const val PT_PER_INCH = 72f
        private const val MILS_PER_INCH = 1000f
        private const val MARGIN_PT = 8f
        private val CONTROL_CHARS = Regex("[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1F\\x7F]")
    }
}
