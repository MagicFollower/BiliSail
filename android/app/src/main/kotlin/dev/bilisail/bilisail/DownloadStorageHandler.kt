package dev.bilisail.bilisail

import android.app.Activity
import android.Manifest
import android.content.ActivityNotFoundException
import android.content.ContentUris
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.CancellationSignal
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.Settings
import android.system.Os
import android.system.OsConstants
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Publishes only owned files; legacy provider URIs remain readable/deletable. */
internal class DownloadStorageHandler(private val activity: Activity, messenger: BinaryMessenger) {
    private val resolver = activity.contentResolver
    private val prefs = activity.getSharedPreferences("download_storage_v1", Activity.MODE_PRIVATE)
    private val channel = MethodChannel(messenger, "dev.bilisail/download_storage")
    private val worker = Executors.newFixedThreadPool(5)
    private val main = Handler(Looper.getMainLooper())
    private val cancellations = ConcurrentHashMap<String, AtomicBoolean>()
    private val leases = ConcurrentHashMap<String, ParcelFileDescriptor>()
    private val taskLocks = ConcurrentHashMap<String, Any>()
    private val closed = AtomicBoolean(false)
    private var picker: MethodChannel.Result? = null
    private val requestCode = 5714
    private val mediaNames = setOf("video.m4s", "audio.m4s", "media.mp4", "media.mkv")
    private val sidecarNames = setOf("manifest.json", "extras.json", "cover.img")
    private val textNames = setOf("manifest.json", "extras.json")
    private val mimes = mapOf(
        "audio.m4s" to "audio/mp4",
        "media.mkv" to "video/x-matroska",
        "manifest.json" to "application/json",
        "extras.json" to "application/json",
        "cover.img" to "application/octet-stream",
    )

    private fun mimeFor(name: String): String = mimes[name] ?: "video/mp4"

    /**
     * The readable per-part folder name suggested by Dart. Re-sanitized here
     * because the caller is not the only party that can name a folder: a
     * separator or dot-prefix would escape the BiliSail subtree.
     */
    private fun folderName(call: MethodCall): String {
        val raw = call.argument<String>("folder") ?: throw IllegalArgumentException()
        val name = raw.replace(Regex("[\\\\/:*?\"<>|\\u0000-\\u001F\\u007F]+"), " ")
            .replace(Regex("\\s+"), " ").trim().trimEnd('.', ' ')
        require(name.isNotEmpty() && name != ".." && !name.startsWith("."))
        require(name.toByteArray(Charsets.UTF_8).size <= 200)
        return name
    }

    /** Appends `-2`, `-3`, … until the store has nothing under that name. */
    private fun unique(base: String, taken: (String) -> Boolean): String {
        if (!taken(base)) return base
        for (suffix in 2..99) {
            val candidate = "$base-$suffix"
            if (!taken(candidate)) return candidate
        }
        throw IOException("同名的下载文件夹过多，请清理后重试")
    }

    /** True when MediaStore already has rows in that Download/BiliSail folder. */
    private fun hasMediaStoreRows(relative: String): Boolean {
        val projection = arrayOf(MediaStore.MediaColumns._ID)
        resolver.query(
            MediaStore.Files.getContentUri("external"), projection,
            "${MediaStore.MediaColumns.RELATIVE_PATH} = ?", arrayOf(relative), null,
        )?.use { return it.count > 0 } ?: return false
    }

    /** True when the chosen SAF tree already has a direct child with this name. */
    private fun hasTreeChild(tree: Uri, name: String): Boolean =
        treeChildren(tree, DocumentsContract.getTreeDocumentId(tree)).contains(name)

    private fun treeChildren(tree: Uri, documentId: String): List<String> {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, documentId)
        val names = ArrayList<String>()
        resolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)
            ?.use { while (it.moveToNext()) names.add(it.getString(0) ?: "") }
        return names
    }

    /**
     * Lists the published per-part folders one level under the destination.
     * A folder qualifies only when it holds our own `manifest.json`, so a
     * user's unrelated subtree is never treated as downloadable content, and
     * the walk never recurses.
     */
    private fun listFolders(call: MethodCall): Map<String, Any?> {
        val destination = call.argument<String>("destination")
            ?: prefs.getString("destination", null)
            ?: throw IllegalArgumentException()
        val folders = when {
            destination.startsWith("file:") ->
                fileFolders(externalDirectory(Uri.parse(destination).path!!))
            destination == "downloads" -> mediaStoreFolders()
            else -> treeFolders(root(destination))
        }
        return mapOf("destination" to destination, "folders" to folders)
    }

    private fun fileInfo(
        name: String,
        uri: String,
        bytes: Long,
        modifiedMs: Long,
    ) = mapOf(
        "name" to name,
        "uri" to uri,
        "bytes" to bytes,
        "modifiedMs" to modifiedMs,
    )

    private fun isLink(file: File): Boolean = try {
        OsConstants.S_ISLNK(Os.lstat(file.path).st_mode)
    } catch (_: java.io.FileNotFoundException) {
        true
    }

    private fun fileFolders(parent: File): List<Map<String, Any?>> {
        val children = parent.listFiles()?.sortedBy { it.name.lowercase() } ?: return emptyList()
        return children.filter {
            it.isDirectory && !isLink(it) && File(it, "manifest.json").isFile
        }.map { folder ->
            val files = folder.listFiles()?.filter { it.isFile && !isLink(it) }?.map { file ->
                fileInfo(
                    file.name,
                    Uri.fromFile(file).toString(),
                    file.length(),
                    file.lastModified(),
                )
            } ?: emptyList()
            mapOf("key" to folder.absolutePath, "name" to folder.name, "files" to files)
        }
    }

    private fun mediaStoreFolders(): List<Map<String, Any?>> {
        val columns = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.RELATIVE_PATH,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.DATE_MODIFIED,
        )
        val grouped = LinkedHashMap<String, MutableList<Map<String, Any?>>>()
        resolver.query(
            MediaStore.Files.getContentUri("external"), columns,
            "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?",
            arrayOf("${Environment.DIRECTORY_DOWNLOADS}/BiliSail/%"), null,
        )?.use { cursor ->
            val id = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
            val relative = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.RELATIVE_PATH)
            val name = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
            val size = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
            val modified = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED)
            while (cursor.moveToNext()) {
                val uri = ContentUris.withAppendedId(
                    MediaStore.Files.getContentUri("external"), cursor.getLong(id),
                )
                grouped.getOrPut(cursor.getString(relative) ?: "") { mutableListOf() }.add(
                    fileInfo(
                        cursor.getString(name) ?: "",
                        uri.toString(),
                        if (cursor.isNull(size)) 0L else cursor.getLong(size),
                        (if (cursor.isNull(modified)) 0L else cursor.getLong(modified)) * 1000,
                    ),
                )
            }
        }
        return grouped.entries.filter { entry ->
            entry.value.any { it["name"] == "manifest.json" }
        }.map { entry ->
            mapOf(
                "key" to entry.key,
                "name" to entry.key.trimEnd('/').substringAfterLast('/'),
                "files" to entry.value,
            )
        }
    }

    private fun treeFolders(tree: Uri): List<Map<String, Any?>> {
        val treeId = DocumentsContract.getTreeDocumentId(tree)
        val folders = ArrayList<Map<String, Any?>>()
        val childColumns = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
        )
        val entries = ArrayList<Pair<String, String>>()
        resolver.query(
            DocumentsContract.buildChildDocumentsUriUsingTree(tree, treeId),
            childColumns, null, null, null,
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                if (cursor.getString(2) != DocumentsContract.Document.MIME_TYPE_DIR) continue
                val documentId = cursor.getString(0) ?: continue
                entries.add(documentId to (cursor.getString(1) ?: ""))
            }
        }
        val fileColumns = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )
        for ((documentId, display) in entries) {
            val files = ArrayList<Map<String, Any?>>()
            resolver.query(
                DocumentsContract.buildChildDocumentsUriUsingTree(tree, documentId),
                fileColumns, null, null, null,
            )?.use { child ->
                while (child.moveToNext()) {
                    val childId = child.getString(0) ?: continue
                    files.add(
                        fileInfo(
                            child.getString(1) ?: "",
                            DocumentsContract.buildDocumentUriUsingTree(tree, childId).toString(),
                            if (child.isNull(2)) 0L else child.getLong(2),
                            if (child.isNull(3)) 0L else child.getLong(3),
                        ),
                    )
                }
            }
            if (files.any { it["name"] == "manifest.json" }) {
                folders.add(mapOf("key" to documentId, "name" to display, "files" to files))
            }
        }
        return folders
    }

    /**
     * Proves [uri] is one of our own text sidecars directly inside [folder],
     * under the destination the caller claims. Shared by the manifest reader and
     * the sidecar copy so neither can be pointed at an arbitrary file.
     */
    private fun requirePublishedSidecar(
        destination: String,
        folder: String,
        uri: Uri,
    ) {
        if (destination.startsWith("file:")) {
            require(uri.scheme == "file")
            val directory = File(folder)
            externalDirectory(directory.parentFile?.path ?: throw IllegalArgumentException())
            val file = File(uri.path ?: throw IllegalArgumentException())
            require(file.parentFile?.absolutePath == directory.absolutePath)
            require(file.name in textNames)
            require(!isLink(file) && file.isFile)
            return
        }
        if (destination == "downloads") {
            require(uri.authority == MediaStore.AUTHORITY)
            resolver.query(
                uri,
                arrayOf(
                    MediaStore.MediaColumns.RELATIVE_PATH,
                    MediaStore.MediaColumns.DISPLAY_NAME,
                ),
                null, null, null,
            )?.use {
                if (!it.moveToFirst()) throw java.io.FileNotFoundException()
                require(it.getString(0) == folder)
                require((it.getString(1) ?: "") in textNames)
            } ?: throw java.io.FileNotFoundException()
            return
        }
        val tree = Uri.parse(destination)
        require(uri.authority == tree.authority)
        val folderUri = DocumentsContract.buildDocumentUriUsingTree(tree, folder)
        require(DocumentsContract.isChildDocument(resolver, folderUri, uri))
        resolver.query(
            uri, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null,
        )?.use {
            if (!it.moveToFirst()) throw java.io.FileNotFoundException()
            require((it.getString(0) ?: "") in textNames)
        } ?: throw java.io.FileNotFoundException()
    }

    /**
     * Streams a published sidecar back into the task's private directory, so an
     * imported part plays with its danmaku and subtitles exactly like a part
     * this install downloaded. Copied rather than read into a string because the
     * sidecar is allowed to reach tens of megabytes.
     */
    private fun copyPublished(call: MethodCall) {
        val destination = call.argument<String>("destination") ?: throw IllegalArgumentException()
        val folder = call.argument<String>("folder") ?: throw IllegalArgumentException()
        val raw = call.argument<String>("uri") ?: throw IllegalArgumentException()
        val target = call.argument<String>("targetPath") ?: throw IllegalArgumentException()
        val limit = (call.argument<Int>("maxBytes") ?: 33554432).toLong()
        val uri = Uri.parse(raw)
        requirePublishedSidecar(destination, folder, uri)
        if (destination == "downloads") {
            resolver.query(uri, arrayOf(MediaStore.MediaColumns.SIZE), null, null, null)?.use {
                if (it.moveToFirst() && !it.isNull(0)) require(it.getLong(0) <= limit)
            }
        }
        val file = File(target)
        require(file.parentFile?.isDirectory == true && file.name in textNames)
        val temp = File("${file.path}.tmp")
        try {
            resolver.openInputStream(uri).use { input ->
                input ?: throw java.io.FileNotFoundException()
                temp.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var total = 0L
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        total += read
                        if (total > limit) throw IOException("附属文件过大，已放弃复制")
                        output.write(buffer, 0, read)
                    }
                    output.flush()
                    (output as? java.io.FileOutputStream)?.fd?.sync()
                }
            }
            if (file.exists() && !file.delete()) throw IOException("替换离线附属文件失败")
            if (!temp.renameTo(file)) throw IOException("写入离线附属文件失败")
        } catch (e: Exception) {
            temp.delete()
            throw e
        }
    }

    /**
     * Reads one published text file after re-proving it is a direct child of a
     * folder that [listFolders] just returned, and that its name is one of the
     * two text sidecars. The channel must not turn into a general file reader
     * for anything the caller can name.
     */
    private fun readPublishedText(call: MethodCall): String {
        val destination = call.argument<String>("destination") ?: throw IllegalArgumentException()
        val folder = call.argument<String>("folder") ?: throw IllegalArgumentException()
        val raw = call.argument<String>("uri") ?: throw IllegalArgumentException()
        val limit = call.argument<Int>("maxBytes") ?: 262144
        require(limit in 1..1048576)
        val uri = Uri.parse(raw)
        requirePublishedSidecar(destination, folder, uri)
        if (destination.startsWith("file:")) {
            val file = File(uri.path ?: throw IllegalArgumentException())
            require(file.length() <= limit)
            return file.readText()
        }
        if (destination == "downloads") {
            resolver.query(uri, arrayOf(MediaStore.MediaColumns.SIZE), null, null, null)?.use {
                if (it.moveToFirst() && !it.isNull(0)) require(it.getLong(0) <= limit)
            }
        }
        resolver.openInputStream(uri).use { input ->
            input ?: throw java.io.FileNotFoundException()
            val buffer = ByteArray(limit + 1)
            var total = 0
            while (total <= limit) {
                val read = input.read(buffer, total, buffer.size - total)
                if (read < 0) break
                total += read
            }
            if (total > limit) throw IOException("清单文件过大")
            return String(buffer, 0, total, Charsets.UTF_8)
        }
    }

    /**
     * Re-adopts a folder this app published under an earlier install. The media
     * and sidecars are still there, but the journal that made them ours lived
     * in app preferences and is gone with the app data, so verification,
     * playback and deletion would all fail. The scan supplies the listing it
     * just read; every URI is re-checked against the destination exactly as
     * publish would before the journal is written, so a file the user moved or
     * truncated is refused rather than trusted.
     */
    private fun adopt(call: MethodCall) {
        val key = key(call)
        val destination = call.argument<String>("destination") ?: throw IllegalArgumentException()
        val folder = call.argument<String>("folder") ?: throw IllegalArgumentException()
        val files = call.argument<Map<String, String>>("files") ?: throw IllegalArgumentException()
        require(files.keys.all { it in mediaNames || it in sidecarNames })
        require(files.keys.any { it in mediaNames })
        val existing = read(key)
        if (existing != null && existing.getBoolean("ready") && items(existing) == files) return
        if (existing != null) deleteRecord(key, existing)
        val record = JSONObject()
            .put("destination", destination)
            .put("taskId", call.argument<String>("id")!!)
            .put("ready", true)
            .put("items", JSONObject(files))
        when {
            destination.startsWith("file:") -> record.put("folderPath", folder)
            destination == "downloads" -> record.put("relativePath", folder)
            else -> record.put("folderDocId", folder)
        }
        save(key, record)
        try {
            for ((_, value) in files) {
                val uri = Uri.parse(value)
                checkBoundary(record, uri)
                readable(uri).close()
            }
        } catch (e: Exception) {
            // Leave no half-adopted journal behind.
            deleteRecord(key, record)
            throw e
        }
    }

    init { channel.setMethodCallHandler(::call) }

    private fun call(call: MethodCall, result: MethodChannel.Result) {
        if (closed.get()) { result.error("storage", "存储服务已关闭", null); return }
        if (call.method == "hasDestination") {
            val destination = prefs.getString("destination", null)
            result.success(when (destination) {
                null -> false
                else -> destination.startsWith("file:") && hasStorageAccess()
            })
            return
        }
        if (call.method == "requestAccess") {
            requestAccess(result)
            return
        }
        if (call.method == "cancel") {
            cancellations[key(call)]?.set(true); result.success(null); return
        }
        val cancel = if (call.method == "publish") AtomicBoolean(false) else null
        if (cancel != null) cancellations[key(call)] = cancel
        worker.execute {
            try {
                val value: Any? = when (call.method) {
                    "listDirectories" -> listDirectories(call.argument<String>("directory"))
                    "listFolders" -> listFolders(call)
                    "readText" -> readPublishedText(call)
                    "copyPublished" -> copyPublished(call)
                    "adopt" -> synchronized(taskLocks.getOrPut(key(call)) { Any() }) { adopt(call); null }
                    "choose" -> {
                        val folder = externalDirectory(call.argument<String>("directory") ?: throw IllegalArgumentException())
                        val probe = File.createTempFile(".bilisail-access-", ".tmp", folder)
                        try { probe.outputStream().use { it.fd.sync() } } finally { probe.delete() }
                        if (!prefs.edit().putString("destination", Uri.fromFile(folder).toString()).commit()) {
                            throw IOException("保存下载位置失败")
                        }
                        null
                    }
                    "destination" -> {
                        val destination = prefs.getString("destination", null)
                        if (destination?.startsWith("file:") == true) externalDirectory(Uri.parse(destination).path!!)
                        else if (destination != null && destination != "downloads") root(destination, write = true)
                        destination
                    }
                    "publish" -> synchronized(taskLocks.getOrPut(key(call)) { Any() }) { publish(call, cancel!!) }
                    "verify" -> synchronized(taskLocks.getOrPut(key(call)) { Any() }) { verify(call); null }
                    "delete" -> synchronized(taskLocks.getOrPut(key(call)) { Any() }) { delete(call); null }
                    "openMedia" -> openMedia(call.argument<String>("uri")!!)
                    "closeMedia" -> { leases.remove(call.argument<String>("lease"))?.close(); null }
                    else -> throw IllegalArgumentException("不支持的存储操作")
                }
                main.post { runCatching { result.success(value) } }
            } catch (e: Throwable) {
                // Throwable, not Exception: an OutOfMemoryError or a
                // NoClassDefFoundError from a virtualized provider used to
                // escape here, and an uncaught throwable on any thread closes
                // the whole process. The caller gets a storage failure it can
                // show instead of an app that disappears.
                val message = when (e) {
                    is SecurityException -> "下载位置授权已失效，请在设置中重新选择原目录"
                    is java.io.FileNotFoundException -> "公共音视频文件不存在，或存储设备已离线"
                    is UnsupportedOperationException -> "此位置不支持本地视频随机读取，请选择设备上的目录"
                    is IllegalArgumentException -> "下载文件归属或保存位置无效"
                    else -> e.message ?: e.javaClass.simpleName
                }
                main.post {
                    runCatching {
                        result.error(if (e is SecurityException) "permission" else "storage", message, null)
                    }
                }
            } finally {
                if (cancel != null) cancellations.remove(key(call), cancel)
            }
        }
    }

    private fun finishPicker(value: Boolean) { picker?.success(value); picker = null }

    private fun hasStorageAccess(): Boolean = if (Build.VERSION.SDK_INT >= 30) {
        Environment.isExternalStorageManager()
    } else {
        activity.checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED &&
            activity.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestAccess(result: MethodChannel.Result) {
        if (picker != null) { result.error("busy", "请先完成存储授权", null); return }
        if (hasStorageAccess()) { result.success(true); return }
        picker = result
        try {
            if (Build.VERSION.SDK_INT >= 30) {
                try {
                    activity.startActivityForResult(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                        Uri.parse("package:${activity.packageName}")), requestCode)
                } catch (_: ActivityNotFoundException) {
                    activity.startActivityForResult(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION), requestCode)
                }
            } else if (prefs.getBoolean("requested_storage", false) &&
                !activity.shouldShowRequestPermissionRationale(Manifest.permission.WRITE_EXTERNAL_STORAGE) &&
                !activity.shouldShowRequestPermissionRationale(Manifest.permission.READ_EXTERNAL_STORAGE)) {
                activity.startActivityForResult(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:${activity.packageName}")), requestCode)
            } else {
                prefs.edit().putBoolean("requested_storage", true).apply()
                activity.requestPermissions(arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE,
                    Manifest.permission.WRITE_EXTERNAL_STORAGE), requestCode)
            }
        } catch (_: Exception) { picker?.error("permission", "无法打开存储授权窗口，请在系统设置中允许文件访问", null); picker = null }
    }

    fun onActivityResult(code: Int): Boolean {
        if (code != requestCode) return false
        finishPicker(hasStorageAccess())
        return true
    }

    fun onPermissionResult(code: Int) {
        if (code == requestCode) finishPicker(hasStorageAccess())
    }

    private fun storageRoots(): List<File> {
        val primary = Environment.getExternalStorageDirectory().absoluteFile
        val additional = activity.getExternalFilesDirs(null).mapNotNull {
            it?.parentFile?.parentFile?.parentFile?.parentFile?.absoluteFile
        }
        return (listOf(primary) + additional).distinctBy { it.path }.filter { it.isDirectory }
    }

    // Platform storage roots may have system aliases. Trust those exact anchors,
    // but reject symlinks, dot segments and Android's private trees below them.
    private fun externalDirectory(path: String): File {
        if (!hasStorageAccess()) throw SecurityException()
        require(File(path).isAbsolute && path.split('/').none { it == "." || it == ".." })
        val folder = File(path).absoluteFile
        val boundary = storageRoots().firstOrNull { folder == it || folder.path.startsWith(it.path + "/") }
            ?: throw IOException("存储设备已离线或此目录不在共享存储中")
        val relative = folder.path.removePrefix(boundary.path).trimStart('/')
        require(relative != "Android" && !relative.startsWith("Android/"))
        var component = folder
        while (component != boundary) {
            if (!component.exists()) throw IOException("文件夹已不存在或存储设备已离线")
            require(!OsConstants.S_ISLNK(Os.lstat(component.path).st_mode))
            component = component.parentFile ?: throw IllegalArgumentException()
        }
        if (!folder.isDirectory || !folder.canRead()) throw IOException("无法读取此文件夹")
        return folder
    }

    private fun folderInfo(folder: File): Map<String, String> = mapOf("path" to folder.path, "name" to folder.name)

    private fun listDirectories(path: String?): Map<String, Any?> {
        if (!hasStorageAccess()) throw SecurityException()
        if (path == null) return mapOf("directory" to null, "parent" to null,
            "folders" to storageRoots().mapIndexed { index, folder ->
                mapOf("path" to folder.path, "name" to if (index == 0) "内部存储" else "存储设备 ${folder.name}")
            })
        val folder = externalDirectory(path)
        val children = folder.listFiles() ?: throw IOException("无法读取此文件夹")
        val directories = children.asSequence().filter {
            it.isDirectory && it.name != "Android" && !it.name.startsWith(".") &&
                !OsConstants.S_ISLNK(Os.lstat(it.path).st_mode)
        }.take(2001).toList().sortedBy { it.name.lowercase() }
        return mapOf("directory" to folderInfo(folder),
            "parent" to if (storageRoots().any { it == folder }) null else folder.parent,
            "folders" to directories.take(2000).map(::folderInfo), "truncated" to (directories.size > 2000))
    }

    private fun key(call: MethodCall): String {
        val id = call.argument<String>("id") ?: throw IllegalArgumentException()
        require(Regex("[0-9a-f]{32}").matches(id))
        val scope = call.argument<String>("scope") ?: throw IllegalArgumentException()
        val digest = MessageDigest.getInstance("SHA-256").digest(scope.toByteArray())
            .joinToString("") { "%02x".format(it) }
        return "task_${digest}_$id"
    }

    private fun read(key: String): JSONObject? = prefs.getString(key, null)?.let(::JSONObject)
    private fun save(key: String, record: JSONObject) {
        if (!prefs.edit().putString(key, record.toString()).commit()) throw IOException("保存公共文件索引失败")
    }
    private fun items(record: JSONObject): Map<String, String> {
        val obj = record.getJSONObject("items")
        return obj.keys().asSequence().associateWith { obj.getString(it) }
    }
    private fun root(destination: String, write: Boolean = false): Uri {
        val tree = Uri.parse(destination)
        require(tree.scheme == "content" && DocumentsContract.isTreeUri(tree))
        if (resolver.persistedUriPermissions.none { it.uri == tree && it.isReadPermission && (!write || it.isWritePermission) }) {
            throw SecurityException()
        }
        val document = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        try {
            resolver.query(document, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID), null, null, null)?.use {
                if (!it.moveToFirst()) throw IOException("保存目录或存储设备不可用，请连接后重试")
            } ?: throw IOException("保存目录或存储设备不可用，请连接后重试")
        } catch (_: java.io.FileNotFoundException) {
            throw IOException("保存目录或存储设备不可用，请连接后重试")
        }
        return document
    }

    private fun checkBoundary(record: JSONObject, uri: Uri) {
        val destination = record.getString("destination")
        require(items(record).containsValue(uri.toString()))
        if (destination.startsWith("file:")) {
            require(uri.scheme == "file")
            val name = items(record).entries.first { it.value == uri.toString() }.key
            // Journals written before per-part folders stored "<taskId>_<name>"
            // flat in the destination; they stay verifiable and deletable.
            val file = if (record.has("folderPath"))
                File(externalDirectory(record.getString("folderPath")), name)
            else File(externalDirectory(Uri.parse(destination).path!!), "${record.getString("taskId")}_$name")
            require(uri == Uri.fromFile(file))
            if (!file.exists()) throw java.io.FileNotFoundException()
            require(!OsConstants.S_ISLNK(Os.lstat(file.path).st_mode) && file.isFile)
        } else if (destination == "downloads") {
            require(uri.scheme == "content")
            require(Build.VERSION.SDK_INT >= 29 && uri.authority == MediaStore.AUTHORITY)
            resolver.query(uri, arrayOf(MediaStore.MediaColumns.RELATIVE_PATH), null, null, null)?.use {
                if (!it.moveToFirst()) throw java.io.FileNotFoundException()
                require(it.getString(0) == record.getString("relativePath"))
            } ?: throw java.io.FileNotFoundException()
        } else {
            require(uri.scheme == "content")
            val parent = if (record.has("folderDocId")) DocumentsContract.buildDocumentUriUsingTree(
                Uri.parse(destination), record.getString("folderDocId")) else root(destination)
            resolver.query(uri, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID), null, null, null)?.use {
                if (!it.moveToFirst()) throw java.io.FileNotFoundException()
            } ?: throw java.io.FileNotFoundException()
            require(uri.authority == parent.authority && DocumentsContract.isChildDocument(resolver, parent, uri))
        }
    }

    private fun readable(uri: Uri): ParcelFileDescriptor {
        if (uri.scheme == "file") return ParcelFileDescriptor.open(File(uri.path!!), ParcelFileDescriptor.MODE_READ_ONLY)
        val signal = CancellationSignal()
        val timeout = Runnable { signal.cancel() }
        main.postDelayed(timeout, 15000)
        val fd = try {
            resolver.openFileDescriptor(uri, "r", signal) ?: throw java.io.FileNotFoundException()
        } finally { main.removeCallbacks(timeout) }
        try { Os.lseek(fd.fileDescriptor, 0, OsConstants.SEEK_CUR) }
        catch (_: Exception) { fd.close(); throw UnsupportedOperationException() }
        return fd
    }

    private fun verify(call: MethodCall) {
        val record = read(key(call)) ?: throw IllegalArgumentException()
        require(record.getBoolean("ready") && record.getString("destination") == call.argument<String>("destination"))
        val actual = items(record)
        require(actual == call.argument<Map<String, String>>("uris"))
        for ((name, value) in actual) {
            val uri = Uri.parse(value)
            try { checkBoundary(record, uri); readable(uri).close() }
            catch (e: java.io.FileNotFoundException) {
                throw IOException("公共${labelOf(name)}文件不存在或设备已离线")
            }
        }
    }

    private fun labelOf(name: String): String = when (name) {
        "audio.m4s" -> "音频"
        "video.m4s" -> "视频"
        "media.mp4", "media.mkv" -> "合并媒体"
        "extras.json" -> "弹幕字幕"
        "cover.img" -> "封面"
        else -> "清单"
    }

    private fun publish(call: MethodCall, cancelled: AtomicBoolean): Map<String, String> {
        val key = key(call)
        val destination = call.argument<String>("destination") ?: throw IllegalArgumentException()
        val files = call.argument<Map<String, String>>("files") ?: throw IllegalArgumentException()
        val media = files.keys.filter { it in mediaNames }.toSet()
        require(files.keys.all { it in mediaNames || it in sidecarNames })
        require(media == setOf("video.m4s", "audio.m4s") || media == setOf("media.mp4") || media == setOf("media.mkv"))
        var record = read(key)
        if (record != null) {
            require(record.getString("destination") == destination)
            if (record.getBoolean("ready")) {
                for (value in items(record).values) { val uri = Uri.parse(value); checkBoundary(record, uri); readable(uri).close() }
                return items(record)
            }
            deleteRecord(key, record)
        }
        if (destination.startsWith("file:")) externalDirectory(Uri.parse(destination).path!!)
        else if (destination == "downloads") require(Build.VERSION.SDK_INT >= 29) else root(destination, write = true)
        val id = call.argument<String>("id")!!
        val base = folderName(call)
        record = JSONObject().put("destination", destination).put("taskId", id)
            .put("ready", false).put("items", JSONObject())
        // Every branch keeps one part in one readable folder, so the folder can
        // be recognised again after the app - and with it the private staging
        // directory - is gone.
        when {
            destination.startsWith("file:") -> {
                val parent = externalDirectory(Uri.parse(destination).path!!)
                val name = unique(base) { File(parent, it).exists() }
                val folder = File(parent, name)
                if (!folder.mkdir() && !folder.isDirectory) throw IOException("无法创建下载文件夹")
                record.put("folderPath", folder.absolutePath)
            }
            destination == "downloads" -> {
                val prefix = "${Environment.DIRECTORY_DOWNLOADS}/BiliSail/"
                val name = unique(base) { hasMediaStoreRows("$prefix$it/") }
                record.put("relativePath", "$prefix$name/")
            }
            else -> {
                val tree = root(destination, write = true)
                val name = unique(base) { hasTreeChild(tree, it) }
                val mime = DocumentsContract.Document.MIME_TYPE_DIR
                val folder = DocumentsContract.createDocument(resolver, tree, mime, name)
                    ?: throw IOException("无法创建下载文件夹，请改用应用私有目录或重新选择位置")
                record.put("folderDocId", DocumentsContract.getDocumentId(folder))
            }
        }
        save(key, record)
        for ((name, path) in files) {
            if (cancelled.get()) throw IOException("保存已暂停，临时文件已保留")
            require(name in mediaNames || name in sidecarNames)
            val source = File(path)
            // Trust the exact platform-owned app directory, including its system
            // ancestor aliases. Inspect only user-controlled descendants, just
            // like the Dart file store; never canonicalize or walk above it.
            val boundary = activity.getDir("flutter", Activity.MODE_PRIVATE).absoluteFile
            require(source.name == name && source.parentFile?.name == id)
            require(source.absolutePath.startsWith(boundary.path + File.separator))
            require(source.path.split(File.separatorChar).none { it == ".." || it == "." })
            var component = source.absoluteFile
            while (component != boundary) {
                require(!OsConstants.S_ISLNK(Os.lstat(component.path).st_mode))
                component = component.parentFile ?: throw IllegalArgumentException()
            }
            val mime = mimeFor(name)
            val uri = if (destination.startsWith("file:")) {
                val target = File(externalDirectory(record.getString("folderPath")), name)
                if (!target.createNewFile()) throw IOException("目标文件已存在，请更换文件夹后重试")
                Uri.fromFile(target)
            } else if (destination == "downloads") {
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                    put(MediaStore.MediaColumns.MIME_TYPE, mime)
                    put(MediaStore.MediaColumns.RELATIVE_PATH, record.getString("relativePath"))
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: throw IOException("无法创建下载文件")
            } else {
                // One folder per part; the name is already unique per folder.
                val folder = DocumentsContract.buildDocumentUriUsingTree(
                    Uri.parse(destination), record.getString("folderDocId"))
                DocumentsContract.createDocument(resolver, folder, mime, name)
                    ?: throw IOException("无法创建下载文件")
            }
            record.getJSONObject("items").put(name, uri.toString())
            save(key, record)
            checkBoundary(record, uri)
            source.inputStream().use { input ->
                val outputStream = if (uri.scheme == "file") File(uri.path!!).outputStream()
                    else resolver.openOutputStream(uri, "w") ?: throw IOException("无法写入下载位置")
                outputStream.use { output ->
                    // MediaStore creates its backing file on the first write
                    // open. Check seekability after that open, before copying.
                    readable(uri).close()
                    val buffer = ByteArray(256 * 1024)
                    while (true) {
                        if (cancelled.get()) throw IOException("保存已暂停，临时文件已保留")
                        val count = input.read(buffer)
                        if (count < 0) break
                        output.write(buffer, 0, count)
                    }
                    output.flush()
                    if (output is java.io.FileOutputStream) output.fd.sync()
                }
            }
            readable(uri).close()
        }
        if (cancelled.get()) throw IOException("保存已暂停，临时文件已保留")
        if (destination == "downloads") {
            for (value in items(record).values) {
                val values = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
                if (resolver.update(Uri.parse(value), values, null, null) != 1) throw IOException("公开下载文件失败")
            }
        }
        save(key, record.put("ready", true))
        return items(record)
    }

    private fun deleteRecord(key: String, record: JSONObject) {
        for ((name, value) in items(record)) {
            val uri = Uri.parse(value)
            try {
                checkBoundary(record, uri)
                if (record.getString("destination").startsWith("file:")) {
                    if (!File(uri.path!!).delete()) throw IOException("删除下载文件失败")
                } else if (record.getString("destination") == "downloads") {
                    if (resolver.delete(uri, null, null) != 1) throw IOException("删除下载文件失败")
                }
                else if (!DocumentsContract.deleteDocument(resolver, uri)) throw IOException("删除下载文件失败")
            } catch (_: java.io.FileNotFoundException) {
                // An unavailable volume is not evidence that the user deleted a
                // child. Retain the journal and task until the tree is readable.
                if (record.getString("destination").startsWith("file:")) {
                    externalDirectory(Uri.parse(record.getString("destination")).path!!)
                } else if (record.getString("destination") != "downloads") {
                    root(record.getString("destination"))
                } else if (Environment.getExternalStorageState() != Environment.MEDIA_MOUNTED) {
                    throw IOException("下载存储设备不可用，请连接后重试")
                }
            }
            record.getJSONObject("items").remove(name)
            save(key, record)
        }
        removeEmptyFolder(record)
        if (!prefs.edit().remove(key).commit()) throw IOException("保存删除结果失败")
    }

    /**
     * Removes the per-part folder this journal created, but only once it is
     * empty - a user who dropped anything else into it keeps their files.
     * MediaStore folders cannot be deleted through the provider, so the empty
     * directory stays behind in that mode.
     */
    private fun removeEmptyFolder(record: JSONObject) {
        val destination = record.getString("destination")
        try {
            if (destination.startsWith("file:") && record.has("folderPath")) {
                val folder = externalDirectory(record.getString("folderPath"))
                if (folder.listFiles()?.isEmpty() == true && !folder.delete())
                    throw IOException("删除下载文件夹失败")
            } else if (!destination.startsWith("file:") && destination != "downloads" &&
                record.has("folderDocId")
            ) {
                val tree = Uri.parse(destination)
                val children = treeChildren(tree, record.getString("folderDocId"))
                if (children.isEmpty()) DocumentsContract.deleteDocument(
                    resolver, DocumentsContract.buildDocumentUriUsingTree(tree, record.getString("folderDocId")))
            }
        } catch (_: java.io.FileNotFoundException) {
            // Volume offline: the items are already gone from the journal.
        }
    }

    private fun delete(call: MethodCall) {
        val key = key(call)
        val record = read(key) ?: return
        require(record.getString("destination") == call.argument<String>("destination"))
        deleteRecord(key, record)
    }

    private fun openMedia(value: String): Map<String, Any> {
        val record = prefs.all.entries.asSequence().filter { it.key.startsWith("task_") }
            .map { JSONObject(it.value as String) }.firstOrNull { it.optBoolean("ready") && items(it).containsValue(value) }
            ?: throw SecurityException()
        val uri = Uri.parse(value)
        checkBoundary(record, uri)
        val fd = readable(uri)
        val lease = UUID.randomUUID().toString()
        synchronized(leases) {
            if (closed.get()) { fd.close(); throw IOException("存储服务已关闭") }
            leases[lease] = fd
        }
        return mapOf("lease" to lease, "fd" to fd.fd)
    }

    fun close() {
        if (!closed.compareAndSet(false, true)) return
        channel.setMethodCallHandler(null)
        cancellations.values.forEach { it.set(true) }
        finishPicker(false)
        worker.execute {
            synchronized(leases) { leases.values.forEach { it.close() }; leases.clear() }
        }
        worker.shutdown()
    }
}
