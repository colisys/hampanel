package work.dawncall.hampanel

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

/**
 * Bridges the Android Storage Access Framework for the file page: picking a
 * local file to upload and saving a downloaded file via CREATE_DOCUMENT.
 * No broad storage permission is requested; access is granted per URI.
 */
class MainActivity : FlutterActivity() {
    private var pendingPick: MethodChannel.Result? = null
    private var pendingSaveResult: MethodChannel.Result? = null
    private var pendingSaveBytes: ByteArray? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pick" -> openPicker(result)
                    "save" -> openSaver(call, result)
                    "openUrl" -> openUrl(call, result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun openUrl(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        if (url.isNullOrBlank()) {
            result.error("bad_args", "缺少链接", null)
            return
        }
        try {
            startActivity(
                Intent(Intent.ACTION_VIEW, Uri.parse(url))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            result.success(null)
        } catch (error: Exception) {
            result.error("open_failed", error.message ?: "无法打开链接", null)
        }
    }

    private fun openPicker(result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("busy", "另一个文件操作正在进行", null)
            return
        }
        pendingPick = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivityForResult(intent, REQ_PICK)
    }

    private fun openSaver(call: MethodCall, result: MethodChannel.Result) {
        val name = call.argument<String>("name") ?: "hampanel-download"
        val bytes = call.argument<ByteArray>("bytes")
        if (bytes == null) {
            result.error("bad_args", "缺少文件内容", null)
            return
        }
        if (pendingSaveResult != null) {
            result.error("busy", "另一个文件操作正在进行", null)
            return
        }
        pendingSaveResult = result
        pendingSaveBytes = bytes
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/octet-stream"
            putExtra(Intent.EXTRA_TITLE, name)
        }
        startActivityForResult(intent, REQ_SAVE)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            REQ_PICK -> finishPick(resultCode, data)
            REQ_SAVE -> finishSave(resultCode, data)
        }
    }

    private fun finishPick(resultCode: Int, data: Intent?) {
        val result = pendingPick ?: return
        pendingPick = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        try {
            val bytes = contentResolver.openInputStream(uri)?.use { stream ->
                val out = ByteArrayOutputStream()
                val buffer = ByteArray(64 * 1024)
                var total = 0
                while (true) {
                    val read = stream.read(buffer)
                    if (read <= 0) break
                    total += read
                    if (total > MAX_BYTES) {
                        throw IllegalStateException("文件超过 256 MiB 上限")
                    }
                    out.write(buffer, 0, read)
                }
                out.toByteArray()
            } ?: throw IllegalStateException("无法读取所选文件")
            result.success(mapOf("name" to displayName(uri), "bytes" to bytes))
        } catch (error: Exception) {
            result.error("read_failed", error.message ?: "读取失败", null)
        }
    }

    private fun finishSave(resultCode: Int, data: Intent?) {
        val result = pendingSaveResult ?: return
        val bytes = pendingSaveBytes ?: ByteArray(0)
        pendingSaveResult = null
        pendingSaveBytes = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(false)
            return
        }
        try {
            contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                ?: throw IllegalStateException("无法写入目标文件")
            result.success(true)
        } catch (error: Exception) {
            result.error("write_failed", error.message ?: "写入失败", null)
        }
    }

    private fun displayName(uri: Uri): String {
        val projection = arrayOf(OpenableColumns.DISPLAY_NAME)
        contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0) {
                    val name = cursor.getString(index)
                    if (!name.isNullOrBlank()) return name
                }
            }
        }
        return uri.lastPathSegment?.substringAfterLast('/') ?: "file"
    }

    companion object {
        private const val CHANNEL = "work.dawncall.hampanel/files"
        private const val REQ_PICK = 4101
        private const val REQ_SAVE = 4102
        private const val MAX_BYTES = 256 * 1024 * 1024
    }
}
