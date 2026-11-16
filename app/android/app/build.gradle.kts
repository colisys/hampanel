import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasKeystoreFile = keystorePropertiesFile.exists()
if (hasKeystoreFile) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

// CI provides the keystore through environment variables so that the secret
// never has to be written into the checked-out tree.
val envStorePath = System.getenv("HAMPANEL_ANDROID_KEYSTORE")
val envStorePassword = System.getenv("HAMPANEL_ANDROID_KEYSTORE_PASSWORD")
val envKeyAlias = System.getenv("HAMPANEL_ANDROID_KEY_ALIAS")
val envKeyPassword = System.getenv("HAMPANEL_ANDROID_KEY_PASSWORD")
val hasEnvKeystore = envStorePath != null && envStorePassword != null &&
    envKeyAlias != null && envKeyPassword != null && File(envStorePath).exists()
val hasFileKeystore = hasKeystoreFile &&
    keystoreProperties["storeFile"] != null &&
    keystoreProperties["storePassword"] != null &&
    keystoreProperties["keyAlias"] != null &&
    keystoreProperties["keyPassword"] != null
val hasReleaseKeystore = hasFileKeystore || hasEnvKeystore

val releaseStoreFile: File? = if (hasEnvKeystore) {
    File(envStorePath!!)
} else {
    (keystoreProperties["storeFile"] as String?)?.let { file(it) }
}
val releaseStorePassword: String? =
    if (hasEnvKeystore) envStorePassword else keystoreProperties["storePassword"] as String?
val releaseKeyAlias: String? =
    if (hasEnvKeystore) envKeyAlias else keystoreProperties["keyAlias"] as String?
val releaseKeyPassword: String? =
    if (hasEnvKeystore) envKeyPassword else keystoreProperties["keyPassword"] as String?

android {
    namespace = "work.dawncall.hampanel"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "work.dawncall.hampanel"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
                storeFile = releaseStoreFile
                storePassword = releaseStorePassword
                enableV1Signing = true
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }

    buildTypes {
        release {
            // Signed when a keystore is supplied (android/key.properties locally or
            // HAMPANEL_ANDROID_KEYSTORE* in CI); otherwise the APK stays unsigned.
            signingConfig = if (hasReleaseKeystore) signingConfigs.getByName("release") else null
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
