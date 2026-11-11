import java.util.Properties
import java.util.Base64

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseSigningFile = rootProject.file("../keystore/release-signing.properties")
val releaseSigning = Properties().apply {
    if (releaseSigningFile.isFile) {
        releaseSigningFile.inputStream().use { load(it) }
    }
}
val releaseRequested = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true) || it.substringAfterLast(':') in listOf("assemble", "build", "bundle")
}
if (releaseRequested) {
    require(releaseSigningFile.isFile) {
        "Missing keystore/release-signing.properties. Restore the release signing files before building."
    }
    for (key in listOf("storeFile", "storeType", "keyAlias", "storePassword", "keyPassword")) {
        require(!releaseSigning.getProperty(key).isNullOrBlank()) { "Missing release signing property: $key" }
    }
    require(releaseSigningFile.parentFile.resolve(releaseSigning.getProperty("storeFile")).isFile) {
        "Release keystore not found. Restore the original keystore; do not replace an existing app's key."
    }
}

// Same dart-define feeds native startup before the Dart VM is running.
val shellDefines = (project.findProperty("dart-defines") as? String).orEmpty().split(',')
    .mapNotNull { encoded -> runCatching { String(Base64.getDecoder().decode(encoded), Charsets.UTF_8) }.getOrNull() }
    .mapNotNull { raw -> raw.indexOf('=').takeIf { it > 0 }?.let { raw.substring(0, it) to raw.substring(it + 1) } }.toMap()
val shellConfigUrl = shellDefines["SSG_CONFIG_URL"] ?: "https://u4k2.top/api/config"

android {
    buildFeatures { buildConfig = true }
    testBuildType = if (providers.gradleProperty("shellReview").orNull == "true") "release" else "debug"
    namespace = "com.aaazero.yueh"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.aaazero.yueh"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        buildConfigField("String", "SHELL_CONFIG_URL", "\"" + shellConfigUrl.replace("\\", "\\\\").replace("\"", "\\\"") + "\"")
        testInstrumentationRunner = "com.aaazero.yueh.StartupContractTest"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (releaseSigningFile.isFile) {
                storeFile = releaseSigningFile.parentFile.resolve(releaseSigning.getProperty("storeFile"))
                storeType = releaseSigning.getProperty("storeType")
                storePassword = releaseSigning.getProperty("storePassword")
                keyAlias = releaseSigning.getProperty("keyAlias")
                keyPassword = releaseSigning.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        debug {
            if (providers.gradleProperty("shellReview").orNull == "true") {
                applicationIdSuffix = ".review"
            }
        }
        release {
            // Isolated native acceptance target; never changes an installed user app.
            if (providers.gradleProperty("shellReview").orNull == "true") applicationIdSuffix = ".startupcheck"
            signingConfig = signingConfigs.getByName("release")
            proguardFiles("shell-rules.pro")
            if (providers.gradleProperty("shellReview").orNull == "true") proguardFiles("shell-acceptance-rules.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}


android { packaging { jniLibs { excludes += setOf("lib/armeabi-v7a/**", "lib/armeabi/**", "lib/x86/**", "lib/x86_64/**") } } }
dependencies {
 implementation("com.onesignal:OneSignal:5.11.0")
 implementation("com.onesignal:notifications:5.11.0")
 implementation("androidx.webkit:webkit:1.18.0")
 implementation("androidx.activity:activity:1.13.0")
 implementation("androidx.core:core-splashscreen:1.0.1")
}
