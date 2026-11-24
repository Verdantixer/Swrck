package com.swock.vpn.swock

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.widget.TextView
import com.google.android.gms.ads.AdError
import com.google.android.gms.ads.AdRequest
import com.google.android.gms.ads.FullScreenContentCallback
import com.google.android.gms.ads.LoadAdError
import com.google.android.gms.ads.MobileAds
import com.google.android.gms.ads.interstitial.InterstitialAd
import com.google.android.gms.ads.interstitial.InterstitialAdLoadCallback
import com.google.android.gms.ads.rewarded.RewardedAd
import com.google.android.gms.ads.rewarded.RewardedAdLoadCallback
import com.google.android.ump.ConsentInformation
import com.google.android.ump.ConsentRequestParameters
import com.google.android.ump.UserMessagingPlatform
import com.swock.vpn.swock.hotspot.HotspotService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.swock.vpn/channel"
    private val rewardedAdsChannelName = "com.swock/rewarded_ads"
    private val hotspotPermissionRequest = 7
    private val vpnNotificationPermissionRequest = 8
    private val dvsImportRequest = 41
    private val dvsExportRequest = 42
    private var pendingProfileJson: String? = null
    private var pendingImportUri: String? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingNotificationPermissionResult: MethodChannel.Result? = null
    private var pendingDvsImportResult: MethodChannel.Result? = null
    private var pendingDvsExportResult: MethodChannel.Result? = null
    private var pendingDvsExportContents: String? = null
    private var integrityVerified = false
    private var adsInitialized = false
    private var consentInformation: ConsentInformation? = null
    private var pendingRewardedAdResult: MethodChannel.Result? = null
    private var pendingConnectionInterstitialResult: MethodChannel.Result? = null
    private var preloadedRewardedAd: RewardedAd? = null
    private var rewardedAdLoading = false

    private val hotspotWifiPermission: String
        get() = if (Build.VERSION.SDK_INT >= 33) android.Manifest.permission.NEARBY_WIFI_DEVICES
        else android.Manifest.permission.ACCESS_FINE_LOCATION

    override fun onCreate(savedInstanceState: Bundle?) {
        integrityVerified = AppIntegrity.isTrusted(this)
        super.onCreate(savedInstanceState)
        if (!integrityVerified) {
            setContentView(TextView(this).apply {
                text = "This is not an official Swock release. Install the signed release build."
                textSize = 16f
                setPadding(48, 96, 48, 48)
            })
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (!integrityVerified) return
        pendingImportUri = intent?.dataString

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, rewardedAdsChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialize" -> initializeRewardAds(result)
                    "showRewardedTimeAd" -> showRewardedTimeAd(result)
                    "showConnectionInterstitial" -> showConnectionInterstitial(result)
                    "privacyOptionsRequired" -> result.success(
                        consentInformation?.privacyOptionsRequirementStatus ==
                            ConsentInformation.PrivacyOptionsRequirementStatus.REQUIRED,
                    )
                    "showPrivacyOptions" -> showAdsPrivacyOptions(result)
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "listLaunchableApps" -> listLaunchableApps(result)
                "launchGame" -> launchGame(call.argument<String>("packageName"), result)
                "connect" -> {
                    val profileJson = call.argument<String>("profile")
                    if (profileJson.isNullOrBlank()) {
                        result.error("INVALID_PROFILE", "A profile is required", null)
                        return@setMethodCallHandler
                    }
                    if (Build.VERSION.SDK_INT >= 33 &&
                        checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                        if (pendingNotificationPermissionResult != null) {
                            result.error("BUSY", "A permission request is already open", null)
                        } else {
                            pendingProfileJson = profileJson
                            pendingNotificationPermissionResult = result
                            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), vpnNotificationPermissionRequest)
                        }
                    } else {
                        beginVpnPermissionFlow(profileJson, result)
                    }
                }

                "disconnect" -> {
                    pendingProfileJson = null
                    val stopIntent = Intent(this, MyVpnService::class.java)
                        .putExtra(MyVpnService.EXTRA_STOP, true)
                    startService(stopIntent)
                    result.success(true)
                }
                "openExternalUrl" -> {
                    val url = call.argument<String>("url")
                    if (url.isNullOrBlank()) {
                        result.error("INVALID_URL", "A URL is required", null)
                    } else {
                        try {
                            startActivity(
                                Intent(Intent.ACTION_VIEW, Uri.parse(url))
                                    .addCategory(Intent.CATEGORY_BROWSABLE),
                            )
                            result.success(true)
                        } catch (error: Exception) {
                            result.error("OPEN_FAILED", error.message, null)
                        }
                    }
                }
                "getStatus" -> result.success(MyVpnService.status())
                "getStatistics" -> result.success(MyVpnService.statistics())
                "drainVpnLogs" -> result.success(MyVpnService.drainVpnEvents())
                "clearVpnLogs" -> {
                    MyVpnService.clearVpnEvents()
                    result.success(true)
                }
                "testConnection" -> result.success(call.argument<String>("profile")?.let(MyVpnService::testConnection) == true)
                "getNetworkInfo" -> result.success(mapOf("connected" to true))
                "hotspotRequestPermissions" -> {
                    val needed = buildList {
                        if (checkSelfPermission(hotspotWifiPermission) != PackageManager.PERMISSION_GRANTED) add(hotspotWifiPermission)
                        if (Build.VERSION.SDK_INT >= 33 &&
                            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                            add(android.Manifest.permission.POST_NOTIFICATIONS)
                        }
                    }
                    if (needed.isEmpty()) {
                        result.success(true)
                    } else if (pendingPermissionResult != null) {
                        result.error("BUSY", "A permission request is already open", null)
                    } else {
                        pendingPermissionResult = result
                        requestPermissions(needed.toTypedArray(), hotspotPermissionRequest)
                    }
                }
                "hotspotStart" -> {
                    val intent = Intent(this, HotspotService::class.java)
                        .setAction(HotspotService.ACTION_START)
                        .putExtra(HotspotService.EXTRA_NAME, call.argument<String>("name"))
                        .putExtra(HotspotService.EXTRA_PASSWORD, call.argument<String>("password"))
                        .putExtra(HotspotService.EXTRA_PORT, call.argument<Int>("port") ?: HotspotService.AUTO_PORT)
                        .putExtra(HotspotService.EXTRA_DIRECT, call.argument<String>("mode") == "direct")
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
                    result.success(true)
                }
                "hotspotStop" -> {
                    startService(Intent(this, HotspotService::class.java).setAction(HotspotService.ACTION_STOP))
                    result.success(true)
                }
                "hotspotStatus" -> result.success(HotspotService.status())
                "getImportUri" -> {
                    result.success(pendingImportUri)
                    pendingImportUri = null
                }
                "importProfileFile" -> {
                    if (pendingDvsImportResult != null || pendingDvsExportResult != null) {
                        result.error("BUSY", "A file picker is already open", null)
                    } else {
                        pendingDvsImportResult = result
                        startActivityForResult(
                            Intent(Intent.ACTION_OPEN_DOCUMENT)
                                .addCategory(Intent.CATEGORY_OPENABLE)
                                .setType("*/*"),
                            dvsImportRequest,
                        )
                    }
                }
                "exportDvsFile" -> {
                    val contents = call.argument<String>("contents")
                    val fileName = call.argument<String>("fileName")
                    if (contents.isNullOrBlank() || fileName.isNullOrBlank()) {
                        result.error("INVALID_FILE", "Profile file contents and name are required", null)
                    } else if (pendingDvsImportResult != null || pendingDvsExportResult != null) {
                        result.error("BUSY", "A file picker is already open", null)
                    } else {
                        pendingDvsExportResult = result
                        pendingDvsExportContents = contents
                        startActivityForResult(
                            Intent(Intent.ACTION_CREATE_DOCUMENT)
                                .addCategory(Intent.CATEGORY_OPENABLE)
                                .setType("application/octet-stream")
                                .putExtra(Intent.EXTRA_TITLE, if (fileName.endsWith(".dvs", true)) fileName else "$fileName.dvs"),
                            dvsExportRequest,
                        )
                    }
                }
                else -> result.notImplemented()
            }
        }

    }

    private fun initializeRewardAds(result: MethodChannel.Result) {
        if (adsInitialized) {
            result.success(true)
            return
        }
        val consent = UserMessagingPlatform.getConsentInformation(this)
        consentInformation = consent
        consent.requestConsentInfoUpdate(
            this,
            ConsentRequestParameters.Builder().build(),
            {
                UserMessagingPlatform.loadAndShowConsentFormIfRequired(this) {
                    initializeMobileAdsIfAllowed(consent, result)
                }
            },
            {
                initializeMobileAdsIfAllowed(consent, result)
            },
        )
    }

    private fun initializeMobileAdsIfAllowed(
        consent: ConsentInformation,
        result: MethodChannel.Result,
    ) {
        if (!consent.canRequestAds()) {
            result.success(false)
            return
        }
        MobileAds.initialize(this) {
            runOnUiThread {
                adsInitialized = true
                result.success(true)
            }
        }
    }

    private fun showAdsPrivacyOptions(result: MethodChannel.Result) {
        val consent = consentInformation
        if (consent == null ||
            consent.privacyOptionsRequirementStatus !=
            ConsentInformation.PrivacyOptionsRequirementStatus.REQUIRED
        ) {
            result.success(false)
            return
        }
        UserMessagingPlatform.showPrivacyOptionsForm(this) { formError ->
            result.success(formError == null && consent.canRequestAds())
        }
    }

    private fun showRewardedTimeAd(result: MethodChannel.Result) {
        if (!adsInitialized || consentInformation?.canRequestAds() != true) {
            result.success(false)
            return
        }
        if (pendingRewardedAdResult != null ||
            pendingConnectionInterstitialResult != null
        ) {
            result.error("AD_BUSY", "Another ad is already in progress", null)
            return
        }
        pendingRewardedAdResult = result
        RewardedAd.load(
            this,
            getString(R.string.admob_rewarded_id),
            AdRequest.Builder().build(),
            object : RewardedAdLoadCallback() {
                override fun onAdLoaded(ad: RewardedAd) {
                    var earned = false
                    ad.fullScreenContentCallback = object : FullScreenContentCallback() {
                        override fun onAdDismissedFullScreenContent() {
                            finishRewardedTimeAd(earned)
                        }

                        override fun onAdFailedToShowFullScreenContent(error: AdError) {
                            finishRewardedTimeAd(false)
                        }
                    }
                    try {
                        ad.show(this@MainActivity) { earned = true }
                    } catch (_: Exception) {
                        finishRewardedTimeAd(false)
                    }
                }

                override fun onAdFailedToLoad(error: LoadAdError) {
                    finishRewardedTimeAd(false)
                }
            },
        )
    }

    private fun finishRewardedTimeAd(earned: Boolean) {
        val result = pendingRewardedAdResult ?: return
        pendingRewardedAdResult = null
        result.success(earned)
    }

    private fun showConnectionInterstitial(result: MethodChannel.Result) {
        if (!adsInitialized || consentInformation?.canRequestAds() != true) {
            result.success(false)
            return
        }
        if (pendingRewardedAdResult != null ||
            pendingConnectionInterstitialResult != null
        ) {
            result.success(false)
            return
        }
        pendingConnectionInterstitialResult = result
        InterstitialAd.load(
            this,
            getString(R.string.admob_interstitial_id),
            AdRequest.Builder().build(),
            object : InterstitialAdLoadCallback() {
                override fun onAdLoaded(ad: InterstitialAd) {
                    if (pendingConnectionInterstitialResult == null) return
                    if (MyVpnService.status()["connected"] != true) {
                        finishConnectionInterstitial(false)
                        return
                    }
                    ad.fullScreenContentCallback = object : FullScreenContentCallback() {
                        override fun onAdDismissedFullScreenContent() {
                            finishConnectionInterstitial(true)
                        }

                        override fun onAdFailedToShowFullScreenContent(error: AdError) {
                            finishConnectionInterstitial(false)
                        }
                    }
                    try {
                        ad.show(this@MainActivity)
                    } catch (_: Exception) {
                        finishConnectionInterstitial(false)
                    }
                }

                override fun onAdFailedToLoad(error: LoadAdError) {
                    finishConnectionInterstitial(false)
                }
            },
        )
    }

    private fun finishConnectionInterstitial(shown: Boolean) {
        val result = pendingConnectionInterstitialResult ?: return
        pendingConnectionInterstitialResult = null
        result.success(shown)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        pendingImportUri = intent.dataString
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == hotspotPermissionRequest) {
            val index = permissions.indexOf(hotspotWifiPermission)
            val granted = index >= 0 && grantResults.getOrNull(index) == PackageManager.PERMISSION_GRANTED
            pendingPermissionResult?.success(granted)
            pendingPermissionResult = null
        } else if (requestCode == vpnNotificationPermissionRequest) {
            val profile = pendingProfileJson
            val result = pendingNotificationPermissionResult
            pendingProfileJson = null
            pendingNotificationPermissionResult = null
            if (profile != null && result != null) {
                // Notification permission is optional for the tunnel itself. Continue
                // connection even if the user declines, then let Android suppress alerts.
                beginVpnPermissionFlow(profile, result)
            }
        }
    }

    private fun listLaunchableApps(result: MethodChannel.Result) {
        try {
            val launcherIntent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            val apps = packageManager.queryIntentActivities(launcherIntent, 0)
                .asSequence()
                .map { it.activityInfo.packageName to it.loadLabel(packageManager).toString() }
                .filter { it.first != packageName && it.second.isNotBlank() }
                .distinctBy { it.first }
                .map { mapOf("packageName" to it.first, "label" to it.second) }
                .sortedBy { it["label"]?.lowercase() }
                .toList()
            result.success(apps)
        } catch (error: Exception) {
            result.error("GAME_LIST_FAILED", error.message ?: "Could not list installed games.", null)
        }
    }

    private fun launchGame(packageName: String?, result: MethodChannel.Result) {
        if (packageName.isNullOrBlank() || packageName == this.packageName) {
            result.error("INVALID_GAME", "Select an installed game.", null)
            return
        }
        if (MyVpnService.status()["connected"] != true) {
            result.error("VPN_REQUIRED", "Connect Swock VPN before launching a game.", null)
            return
        }
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        if (intent == null) {
            result.error("GAME_NOT_FOUND", "This game is no longer installed.", null)
            return
        }
        try {
            startActivity(intent)
            result.success(true)
        } catch (error: Exception) {
            result.error("GAME_LAUNCH_FAILED", error.message ?: "Could not launch this game.", null)
        }
    }

    private fun beginVpnPermissionFlow(profileJson: String, result: MethodChannel.Result) {
        val intent = VpnService.prepare(this)
        if (intent != null) {
            pendingProfileJson = profileJson
            startActivityForResult(intent, 0)
            result.success(true)
        } else {
            startVpnService(profileJson)
            result.success(true)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == dvsImportRequest) {
            val result = pendingDvsImportResult
            pendingDvsImportResult = null
            if (resultCode != RESULT_OK || data?.data == null) {
                result?.success(null)
            } else {
                try {
                    val contents = contentResolver.openInputStream(data.data!!)?.bufferedReader()?.use { it.readText() }
                    result?.success(contents)
                } catch (error: Exception) {
                    result?.error("FILE_READ_FAILED", error.message ?: "Could not read the selected profile file", null)
                }
            }
            return
        }
        if (requestCode == dvsExportRequest) {
            val result = pendingDvsExportResult
            val contents = pendingDvsExportContents
            pendingDvsExportResult = null
            pendingDvsExportContents = null
            if (resultCode != RESULT_OK || data?.data == null || contents == null) {
                result?.success(false)
            } else {
                try {
                    contentResolver.openOutputStream(data.data!!, "wt")?.bufferedWriter()?.use { it.write(contents) }
                        ?: throw IllegalStateException("Could not open the selected file for writing")
                    result?.success(true)
                } catch (error: Exception) {
                    result?.error("FILE_WRITE_FAILED", error.message ?: "Could not save the profile file", null)
                }
            }
            return
        }
        if (requestCode == 0) {
            val profile = pendingProfileJson
            pendingProfileJson = null
            if (resultCode == RESULT_OK && profile != null) {
                startVpnService(profile)
            } else if (resultCode != RESULT_OK) {
                MyVpnService.updateStatus("disconnected", "VPN permission was not granted")
            }
        }
    }

    private fun startVpnService(profileJson: String) {
        val intent = Intent(this, MyVpnService::class.java)
            .putExtra(MyVpnService.EXTRA_PROFILE, profileJson)
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }
}
