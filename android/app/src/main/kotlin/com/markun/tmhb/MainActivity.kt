package com.markun.tmhb

import android.Manifest
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.Settings
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
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.PI
import kotlin.math.exp
import kotlin.math.sin

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null
    private var akeEventSink: EventChannel.EventSink? = null
    private val akeConnections = mutableMapOf<Int, AkeSocketConnection>()
    private val akeExecutor = Executors.newCachedThreadPool()
    private val soundExecutor = Executors.newSingleThreadExecutor()
    private val soundGeneration = AtomicInteger(0)
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
                        val connection = AkeSocketConnection(
                            id = id,
                            emit = { event -> emitAkeEvent(event) },
                            onClosed = { connId ->
                                synchronized(akeConnections) { akeConnections.remove(connId) }
                            },
                        )
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
                    "getAndroidSdkInt" -> result.success(Build.VERSION.SDK_INT)
                    "getCacheAvailableBytes" -> {
                        val avail = try {
                            StatFs(cacheDir.absolutePath).availableBytes
                        } catch (_: Exception) {
                            null
                        }
                        result.success(avail)
                    }
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
                    "playAribBuiltinSound" -> {
                        val soundId = call.argument<Int>("soundId") ?: 0
                        val urgent = call.argument<Boolean>("urgent") ?: false
                        val gen = soundGeneration.incrementAndGet()
                        soundExecutor.execute { playAribBuiltinSound(soundId, urgent, gen) }
                        result.success(true)
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

    override fun onDestroy() {
        val snapshot = synchronized(akeConnections) {
            val copy = akeConnections.values.toList()
            akeConnections.clear()
            copy
        }
        for (connection in snapshot) {
            connection.close()
        }
        akeExecutor.shutdownNow()
        soundGeneration.incrementAndGet()
        soundExecutor.shutdownNow()
        super.onDestroy()
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
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            return Environment.isExternalStorageManager()
        }
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.READ_EXTERNAL_STORAGE,
        ) == PackageManager.PERMISSION_GRANTED
    }

    @Suppress("DEPRECATION")
    private fun requestStoragePermission(result: MethodChannel.Result) {
        if (hasStoragePermission()) {
            result.success(true)
            return
        }
        pendingStoragePermissionResult?.success(false)
        pendingStoragePermissionResult = result
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                val intent = Intent(
                    Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                    Uri.parse("package:$packageName"),
                )
                startActivityForResult(intent, MANAGE_STORAGE_REQUEST_CODE)
            } catch (_: Exception) {
                try {
                    val fallback = Intent(
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.parse("package:$packageName"),
                    )
                    startActivityForResult(fallback, MANAGE_STORAGE_REQUEST_CODE)
                } catch (_: Exception) {
                    val pending = pendingStoragePermissionResult
                    pendingStoragePermissionResult = null
                    pending?.success(false)
                }
            }
            return
        }
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE),
            STORAGE_PERMISSION_REQUEST_CODE,
        )
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == MANAGE_STORAGE_REQUEST_CODE) {
            val pending = pendingStoragePermissionResult
            pendingStoragePermissionResult = null
            pending?.success(hasStoragePermission())
        }
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
                File(Environment.getExternalStorageDirectory(), "Downloads"),
                "Downloads",
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

    private fun playAribBuiltinSound(soundId: Int, urgent: Boolean, gen: Int) {
        if (gen != soundGeneration.get()) return
        val sampleRate = 44100
        val pcm: ShortArray
        val totalMs: Long

        if (urgent) {
            totalMs = 4600L
            val totalSamples = ((sampleRate * totalMs) / 1000L).toInt()
            val mix = DoubleArray(totalSamples)
            val strikeTimesMs = intArrayOf(0, 980, 1960, 2940)
            val tailSamples = (sampleRate * 1660) / 1000
            val attackSamples = 350
            for (strikeMs in strikeTimesMs) {
                val startSample = (sampleRate * strikeMs) / 1000
                for (i in 0 until tailSamples) {
                    val idx = startSample + i
                    if (idx >= totalSamples) break
                    val t = i.toDouble() / sampleRate
                    val envAttack = if (i < attackSamples) i.toDouble() / attackSamples else 1.0
                    val s = envAttack * (
                        sin(2.0 * PI * 523.25 * t) * exp(-2.35 * t) * 1.00 +
                            sin(2.0 * PI * 1046.50 * t) * exp(-4.2 * t) * 0.14 +
                            sin(2.0 * PI * 2616.25 * t) * exp(-5.0 * t) * 0.22 +
                            sin(2.0 * PI * 3662.75 * t) * exp(-5.5 * t) * 0.28 +
                            sin(2.0 * PI * 5232.50 * t) * exp(-6.2 * t) * 0.32 +
                            sin(2.0 * PI * 5755.75 * t) * exp(-6.5 * t) * 0.30 +
                            sin(2.0 * PI * 6279.00 * t) * exp(-6.8 * t) * 0.26
                        )
                    mix[idx] += s
                }
            }
            pcm = ShortArray(totalSamples)
            val gain = 0.48
            for (i in 0 until totalSamples) {
                val scaled = (mix[i] * gain * Short.MAX_VALUE)
                    .toInt()
                    .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                pcm[i] = scaled.toShort()
            }
        } else {
            data class ToneSeg(val freqs: DoubleArray, val durationMs: Int, val gain: Double)

            val segments: List<ToneSeg> = when {
                soundId == 13 -> listOf(
                    ToneSeg(doubleArrayOf(880.0), 180, 0.40),
                    ToneSeg(doubleArrayOf(659.25), 220, 0.40),
                    ToneSeg(doubleArrayOf(880.0), 180, 0.40),
                    ToneSeg(doubleArrayOf(659.25), 240, 0.40),
                )
                soundId in 0..4 -> listOf(
                    ToneSeg(doubleArrayOf(659.25, 987.77), 240, 0.34),
                    ToneSeg(doubleArrayOf(523.25, 783.99), 420, 0.34),
                )
                else -> listOf(
                    ToneSeg(doubleArrayOf(880.0), 180, 0.24),
                )
            }

            val totalSamples = segments.sumOf { (sampleRate * it.durationMs) / 1000 }
            if (totalSamples <= 0) return
            pcm = ShortArray(totalSamples)
            var offset = 0
            for (seg in segments) {
                val count = (sampleRate * seg.durationMs) / 1000
                val attackSamples = (sampleRate * 8) / 1000
                for (i in 0 until count) {
                    val t = i.toDouble() / sampleRate
                    var sum = 0.0
                    for (f in seg.freqs) {
                        sum += sin(2.0 * PI * f * t)
                    }
                    val avg = sum / seg.freqs.size
                    val envAttack = if (i < attackSamples) i.toDouble() / attackSamples else 1.0
                    val envDecay = exp(-3.5 * i.toDouble() / count)
                    val sample = (avg * envAttack * envDecay * seg.gain * Short.MAX_VALUE)
                        .toInt()
                        .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                    pcm[offset + i] = sample.toShort()
                }
                offset += count
            }
            totalMs = segments.sumOf { it.durationMs }.toLong()
        }

        if (gen != soundGeneration.get()) return
        var track: AudioTrack? = null
        try {
            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            val format = AudioFormat.Builder()
                .setSampleRate(sampleRate)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .build()
            track = AudioTrack.Builder()
                .setAudioAttributes(attrs)
                .setAudioFormat(format)
                .setBufferSizeInBytes(pcm.size * 2)
                .setTransferMode(AudioTrack.MODE_STATIC)
                .build()
            track.write(pcm, 0, pcm.size)
            track.play()
            val deadline = System.currentTimeMillis() + totalMs + 60L
            while (gen == soundGeneration.get() && System.currentTimeMillis() < deadline) {
                Thread.sleep(50L)
            }
        } catch (_: Exception) {
        } finally {
            try {
                track?.stop()
            } catch (_: Exception) {
            }
            try {
                track?.release()
            } catch (_: Exception) {
            }
        }
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
        private const val MANAGE_STORAGE_REQUEST_CODE = 1002
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
    private external fun nativeSetsockoptInt(
        fd: FileDescriptor,
        level: Int,
        option: Int,
        value: Int,
    ): Int

    fun fcntlInt(fd: FileDescriptor, cmd: Int, arg: Int): Int {
        val result = nativeFcntlInt(fd, cmd, arg)
        if (result < 0) throw ErrnoException("fcntl", -result)
        return result
    }

    fun setsockoptInt(fd: FileDescriptor, level: Int, option: Int, value: Int) {
        val result = nativeSetsockoptInt(fd, level, option, value)
        if (result < 0) throw ErrnoException("setsockopt", -result)
    }
}

/// One native AKE socket (plan 28): a BSD socket with IP TTL 3 and
/// TCP_NODELAY set via setsockopt before connect (the DTCP-IP
/// proximity requirement the reference client implements), with
/// blocking I/O on worker threads afterwards.
private class AkeSocketConnection(
    private val id: Int,
    private val emit: (Map<String, Any?>) -> Unit,
    private val onClosed: (Int) -> Unit,
) {
    private val closeLock = Any()
    private var fd: FileDescriptor? = null
    private var input: FileInputStream? = null
    private var output: FileOutputStream? = null

    @Volatile
    private var closed = false

    fun connect(host: String, port: Int, timeoutMs: Int) {
        val descriptor = Os.socket(OsConstants.AF_INET, OsConstants.SOCK_STREAM, 0)
        try {
            FcntlCompat.setsockoptInt(descriptor, OsConstants.IPPROTO_IP, OsConstants.IP_TTL, 3)
            FcntlCompat.setsockoptInt(descriptor, OsConstants.IPPROTO_TCP, OsConstants.TCP_NODELAY, 1)
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
                val count = input?.read(buffer) ?: -1
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
        } finally {
            onClosed(id)
            close()
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
        val inStream: FileInputStream?
        val outStream: FileOutputStream?
        val descriptor: FileDescriptor?
        synchronized(closeLock) {
            closed = true
            inStream = input
            outStream = output
            descriptor = fd
            input = null
            output = null
            fd = null
        }
        // Close streams & OS fd idempotently so peer FIN never leaves
        // the DTCP-IP AKE socket sitting in CLOSE-WAIT.
        try {
            inStream?.close()
        } catch (_: Exception) {
        }
        try {
            outStream?.close()
        } catch (_: Exception) {
        }
        if (descriptor != null) {
            try {
                Os.close(descriptor)
            } catch (_: Exception) {
            }
        }
    }
}
