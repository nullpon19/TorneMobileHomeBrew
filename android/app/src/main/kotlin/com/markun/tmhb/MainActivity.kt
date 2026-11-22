package com.markun.tmhb

import android.Manifest
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.system.StructPollfd
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileDescriptor
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.InetAddress
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null
    private var akeEventSink: EventChannel.EventSink? = null
    private val akeConnections = mutableMapOf<Int, AkeSocketConnection>()
    private val akeExecutor = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var pendingStoragePermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MULTICAST_LOCK_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquire" -> {
                        acquireMulticastLock()
                        result.success(null)
                    }
                    "release" -> {
                        releaseMulticastLock()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WAKELOCK_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setKeepAwake" -> {
                        val keepAwake = call.argument<Boolean>("keepAwake") ?: false
                        if (keepAwake) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(isKeepAwakeSet())
                    }
                    "getKeepAwake" -> result.success(isKeepAwakeSet())
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AKE_SOCKET_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "connect" -> {
                        val id = call.argument<Int>("id")!!
                        val host = call.argument<String>("host")!!
                        val port = call.argument<Int>("port")!!
                        val connection = AkeSocketConnection(id) { event -> emitAkeEvent(event) }
                        synchronized(akeConnections) { akeConnections[id] = connection }
                        akeExecutor.execute {
                            try {
                                connection.connect(host, port, 10_000)
                                mainHandler.post { result.success(null) }
                            } catch (e: Exception) {
                                synchronized(akeConnections) { akeConnections.remove(id) }
                                mainHandler.post {
                                    result.error("connect_failed", e.message, null)
                                }
                            }
                        }
                    }
                    "send" -> {
                        val id = call.argument<Int>("id")!!
                        val data = call.argument<ByteArray>("data")!!
                        val connection = synchronized(akeConnections) { akeConnections[id] }
                        if (connection != null) {
                            akeExecutor.execute { connection.send(data) }
                        }
                        result.success(null)
                    }
                    "close" -> {
                        val id = call.argument<Int>("id")!!
                        val connection = synchronized(akeConnections) { akeConnections.remove(id) }
                        connection?.close()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_FILES_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "shareFiles" -> {
                        val paths = call.argument<List<String>>("paths") ?: emptyList()
                        try {
                            shareLogFiles(paths)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("share_failed", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FIRETV_HELPER_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setMediaVolumeMax" -> result.success(setMediaVolumeMax())
                    "isVpnActive" -> result.success(isVpnActive())
                    "isTailscaleInstalled" -> result.success(isTailscaleInstalled())
                    "tryConnectTailscale" -> result.success(tryConnectTailscale())
                    "launchTailscale" -> result.success(launchTailscale())
                    "hasStoragePermission" -> result.success(hasStoragePermission())
                    "requestStoragePermission" -> requestStoragePermission(result)
                    "getAppFilesDirPath" -> result.success(getExternalFilesDir(null)?.absolutePath)
                    "listCredentialCandidateFiles" -> {
                        akeExecutor.execute {
                            val list = listCredentialCandidateFiles()
                            mainHandler.post { result.success(list) }
                        }
                    }
                    "readFileBytes" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.success(null)
                        } else {
                            akeExecutor.execute {
                                val bytes = readCandidateFileBytes(path)
                                mainHandler.post { result.success(bytes) }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, AKE_SOCKET_EVENTS_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    akeEventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    akeEventSink = null
                }
            })
    }

    private fun emitAkeEvent(event: Map<String, Any?>) {
        mainHandler.post { akeEventSink?.success(event) }
    }

    // SSDP M-SEARCH responses arrive as Wi-Fi multicast; without this
    // lock the driver may filter them out (plan 17).
    private fun acquireMulticastLock() {
        if (multicastLock == null) {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicastLock = wifi.createMulticastLock("torne-mobile-hb-ssdp").apply {
                setReferenceCounted(false)
            }
        }
        if (multicastLock?.isHeld != true) {
            multicastLock?.acquire()
        }
    }

    private fun releaseMulticastLock() {
        if (multicastLock?.isHeld == true) {
            multicastLock?.release()
        }
    }

    // Sleep suppression during playback (plan 35): the Dart side
    // gets the flag read back after every set, so the debug log
    // proves whether the setting actually stuck. Method channel
    // handlers run on the main thread, so touching the window
    // here is safe.
    private fun isKeepAwakeSet(): Boolean =
        window.attributes.flags and
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON != 0

    // Debug log sharing (plan 46): hands the staged log copies in
    // the cache dir to the system share sheet. Raw file:// URIs
    // are rejected since API 24, so the files go out as
    // FileProvider content URIs; the provider's paths file exposes
    // only the staging subdirectory of the cache dir. The ClipData
    // carries the read grants through the chooser to the target
    // app.
    private fun shareLogFiles(paths: List<String>) {
        require(paths.isNotEmpty()) { "no files to share" }
        val uris = ArrayList<Uri>()
        for (path in paths) {
            uris.add(FileProvider.getUriForFile(this, "$packageName.fileprovider", File(path)))
        }
        val intent = Intent(Intent.ACTION_SEND_MULTIPLE).apply {
            type = "text/plain"
            putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
            clipData = ClipData.newUri(contentResolver, "debug logs", uris[0]).apply {
                for (i in 1 until uris.size) {
                    addItem(ClipData.Item(uris[i]))
                }
            }
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(Intent.createChooser(intent, "デバッグログを共有"))
    }

    private fun setMediaVolumeMax(): Boolean =
        try {
            val audio = applicationContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
                ?: return false
            val maxVolume = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            audio.setStreamVolume(AudioManager.STREAM_MUSIC, maxVolume, 0)
            true
        } catch (_: Exception) {
            false
        }

    @Suppress("DEPRECATION")
    private fun isVpnActive(): Boolean =
        try {
            val cm = applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                ?: return false
            val activeCaps = cm.activeNetwork?.let { cm.getNetworkCapabilities(it) }
            if (activeCaps?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true) {
                return true
            }
            cm.allNetworks.any { network ->
                cm.getNetworkCapabilities(network)
                    ?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
            }
        } catch (_: Exception) {
            false
        }

    private fun tailscaleLaunchIntent(): Intent? =
        packageManager.getLeanbackLaunchIntentForPackage(TAILSCALE_PACKAGE)
            ?: packageManager.getLaunchIntentForPackage(TAILSCALE_PACKAGE)

    private fun isTailscaleInstalled(): Boolean =
        try {
            tailscaleLaunchIntent() != null
        } catch (_: Exception) {
            false
        }

    private fun tryConnectTailscale(): Boolean =
        try {
            val intent = Intent("com.tailscale.ipn.CONNECT_VPN").apply {
                setPackage(TAILSCALE_PACKAGE)
            }
            sendBroadcast(intent)
            true
        } catch (_: Exception) {
            false
        }

    private fun launchTailscale(): Boolean =
        try {
            val intent = tailscaleLaunchIntent() ?: return false
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }

    private fun hasStoragePermission(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            return true
        }
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.READ_EXTERNAL_STORAGE,
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestStoragePermission(result: MethodChannel.Result) {
        if (hasStoragePermission()) {
            result.success(true)
            return
        }
        pendingStoragePermissionResult?.success(false)
        pendingStoragePermissionResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE),
            STORAGE_PERMISSION_REQUEST_CODE,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == STORAGE_PERMISSION_REQUEST_CODE) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            val pending = pendingStoragePermissionResult
            pendingStoragePermissionResult = null
            pending?.success(granted)
        }
    }

    @Suppress("DEPRECATION")
    private fun listCredentialCandidateFiles(): List<Map<String, Any>> {
        val roots = listOf(
            Triple(getExternalFilesDir(null), "アプリ専用フォルダ", 2),
            Triple(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                "Download",
                2,
            ),
            Triple(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS),
                "Documents",
                2,
            ),
            Triple(Environment.getExternalStorageDirectory(), "内部ストレージ", 1),
        )
        val allowedExts = setOf("env", "txt", "cert", "key", "pem", "bin")
        val seenPaths = HashSet<String>()
        val results = ArrayList<Map<String, Any>>()

        fun scanDir(dir: File, folderLabel: String, depthRemaining: Int) {
            val children = try {
                dir.listFiles()
            } catch (_: Exception) {
                null
            } ?: return
            for (child in children) {
                if (results.size >= MAX_CREDENTIAL_CANDIDATES) return
                val name = child.name
                if (name.startsWith(".")) continue
                if (child.isDirectory) {
                    if (depthRemaining > 1) {
                        scanDir(child, "$folderLabel/$name", depthRemaining - 1)
                    }
                    continue
                }
                if (!child.isFile || !child.canRead()) continue
                val size = child.length()
                if (size !in 1L..MAX_CREDENTIAL_FILE_BYTES) continue
                val ext = child.extension.lowercase()
                val lowerName = name.lowercase()
                if (ext !in allowedExts && !lowerName.contains("credential")) continue
                val canonical = try {
                    child.canonicalPath
                } catch (_: Exception) {
                    child.absolutePath
                }
                if (!seenPaths.add(canonical)) continue
                results.add(
                    mapOf(
                        "path" to child.absolutePath,
                        "name" to name,
                        "folder" to folderLabel,
                        "size" to size,
                    ),
                )
            }
        }

        for ((root, label, depth) in roots) {
            if (root != null && root.exists() && root.isDirectory) {
                scanDir(root, label, depth)
            }
        }

        results.sortWith(
            compareByDescending<Map<String, Any>> {
                val name = (it["name"] as String).lowercase()
                name.endsWith(".env") || name.contains("credential")
            }.thenBy { it["folder"] as String }
                .thenBy { (it["name"] as String).lowercase() },
        )
        return results
    }

    private fun readCandidateFileBytes(path: String): ByteArray? =
        try {
            val file = File(path)
            if (!file.exists() || !file.isFile || !file.canRead()) {
                null
            } else {
                val size = file.length()
                if (size !in 1L..MAX_CREDENTIAL_FILE_BYTES) null else file.readBytes()
            }
        } catch (_: Exception) {
            null
        }

    companion object {
        private const val MULTICAST_LOCK_CHANNEL = "com.markun.tmhb/multicast_lock"
        private const val WAKELOCK_CHANNEL = "com.markun.tmhb/wakelock"
        private const val SHARE_FILES_CHANNEL = "com.markun.tmhb/share_files"
        private const val AKE_SOCKET_CHANNEL = "com.markun.tmhb/ake_socket"
        private const val AKE_SOCKET_EVENTS_CHANNEL = "com.markun.tmhb/ake_socket_events"
        private const val FIRETV_HELPER_CHANNEL = "com.markun.tmhb/firetv_helper"
        private const val TAILSCALE_PACKAGE = "com.tailscale.ipn"
        private const val STORAGE_PERMISSION_REQUEST_CODE = 1001
        private const val MAX_CREDENTIAL_FILE_BYTES = 1_048_576L
        private const val MAX_CREDENTIAL_CANDIDATES = 100
    }
}

/// fcntl(2) via JNI (libtmhb_fcntl). android.system.Os.fcntlInt only
/// exists on API 30+, and calling it on an older device kills the
/// calling thread with NoSuchMethodError — the AKE socket connects on
/// a worker thread at the start of playback, so playback crashed on
/// API 29 (and on every API below 30) devices. The native call has
/// the exact semantics of Os.fcntlInt on every API level, so there is
/// a single code path: it returns the fcntl(2) result, or -errno on
/// failure, which is converted to ErrnoException here just like Os.
private object FcntlCompat {
    init {
        System.loadLibrary("tmhb_fcntl")
    }

    private external fun nativeFcntlInt(fd: FileDescriptor, cmd: Int, arg: Int): Int

    fun fcntlInt(fd: FileDescriptor, cmd: Int, arg: Int): Int {
        val result = nativeFcntlInt(fd, cmd, arg)
        if (result < 0) throw ErrnoException("fcntl", -result)
        return result
    }
}

/// One native AKE socket (plan 28): a BSD socket with IP TTL 3 and
/// TCP_NODELAY set via setsockopt before connect (the DTCP-IP
/// proximity requirement the reference client implements), with
/// blocking I/O on worker threads afterwards.
private class AkeSocketConnection(
    private val id: Int,
    private val emit: (Map<String, Any?>) -> Unit,
) {
    private var fd: FileDescriptor? = null
    private var input: FileInputStream? = null
    private var output: FileOutputStream? = null

    @Volatile
    private var closed = false

    fun connect(host: String, port: Int, timeoutMs: Int) {
        val descriptor = Os.socket(OsConstants.AF_INET, OsConstants.SOCK_STREAM, 0)
        try {
            Os.setsockoptInt(descriptor, OsConstants.IPPROTO_IP, OsConstants.IP_TTL, 3)
            Os.setsockoptInt(descriptor, OsConstants.IPPROTO_TCP, OsConstants.TCP_NODELAY, 1)
            val address = InetAddress.getByName(host)
            val flags = FcntlCompat.fcntlInt(descriptor, OsConstants.F_GETFL, 0)
            FcntlCompat.fcntlInt(descriptor, OsConstants.F_SETFL, flags or OsConstants.O_NONBLOCK)
            var inProgress = false
            try {
                Os.connect(descriptor, address, port)
            } catch (e: ErrnoException) {
                if (e.errno != OsConstants.EINPROGRESS) throw e
                inProgress = true
            }
            if (inProgress) {
                val pollFd = StructPollfd().apply {
                    fd = descriptor
                    events = OsConstants.POLLOUT.toShort()
                }
                val ready = Os.poll(arrayOf(pollFd), timeoutMs)
                if (ready <= 0) {
                    throw ErrnoException("connect", OsConstants.ETIMEDOUT)
                }
                // A failed connect also reports writable; confirm
                // the peer exists (throws ENOTCONN otherwise).
                // (android.system.Os has no public getsockoptInt in
                // the SDK stubs, hence getpeername.)
                Os.getpeername(descriptor)
            }
            FcntlCompat.fcntlInt(descriptor, OsConstants.F_SETFL, flags)
        } catch (e: Exception) {
            try {
                Os.close(descriptor)
            } catch (_: Exception) {
            }
            throw e
        }
        fd = descriptor
        input = FileInputStream(descriptor)
        output = FileOutputStream(descriptor)
        Thread { readLoop() }.apply { isDaemon = true }.start()
    }

    private fun readLoop() {
        val buffer = ByteArray(16384)
        try {
            while (!closed) {
                val count = input!!.read(buffer)
                if (count > 0) {
                    emit(
                        mapOf(
                            "id" to id,
                            "kind" to "data",
                            "data" to buffer.copyOf(count),
                        ),
                    )
                } else if (count < 0) {
                    if (!closed) emit(mapOf("id" to id, "kind" to "done"))
                    return
                }
            }
        } catch (e: Exception) {
            if (!closed) {
                emit(
                    mapOf(
                        "id" to id,
                        "kind" to "error",
                        "message" to (e.message ?: "socket error"),
                    ),
                )
            }
        }
    }

    fun send(data: ByteArray) {
        val out = output ?: return
        synchronized(out) {
            try {
                out.write(data)
                out.flush()
            } catch (e: Exception) {
                if (!closed) {
                    emit(
                        mapOf(
                            "id" to id,
                            "kind" to "error",
                            "message" to (e.message ?: "send failed"),
                        ),
                    )
                }
            }
        }
    }

    fun close() {
        closed = true
        // Best effort: closing the descriptor and the streams wakes
        // the read loop in practice; a lingering reader exits when
        // the peer closes and its events are dropped by the Dart
        // side, which has already forgotten this connection.
        try {
            input?.close()
        } catch (_: Exception) {
        }
        try {
            output?.close()
        } catch (_: Exception) {
        }
        val descriptor = fd
        fd = null
        if (descriptor != null) {
            try {
                Os.close(descriptor)
            } catch (_: Exception) {
            }
        }
    }
}
