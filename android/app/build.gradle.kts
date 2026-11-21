plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseKeystorePath = System.getenv("ANDROID_KEYSTORE_PATH")?.takeIf { it.isNotEmpty() }
val releaseKeystorePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")?.takeIf { it.isNotEmpty() }
val releaseKeyAlias = System.getenv("ANDROID_KEY_ALIAS")?.takeIf { it.isNotEmpty() }
val releaseKeyPassword = System.getenv("ANDROID_KEY_PASSWORD")?.takeIf { it.isNotEmpty() }
val releaseSigningValues = listOf(
    releaseKeystorePath, releaseKeystorePassword, releaseKeyAlias, releaseKeyPassword,
)
val useReleaseKeystore = releaseSigningValues.any { it != null }
require(!useReleaseKeystore || releaseSigningValues.all { it != null }) {
    "Android release signing requires ANDROID_KEYSTORE_PATH, ANDROID_KEYSTORE_PASSWORD, " +
        "ANDROID_KEY_ALIAS, and ANDROID_KEY_PASSWORD together."
}

android {
    namespace = "com.nekotribe.nekotribe"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.nekotribe.nekotribe"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (useReleaseKeystore) {
            create("release") {
                val keystore = file(requireNotNull(releaseKeystorePath))
                require(keystore.isFile) { "The Android release keystore file does not exist." }
                storeFile = keystore
                storePassword = releaseKeystorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            val signing = if (useReleaseKeystore) "release" else "debug"
            signingConfig = signingConfigs.getByName(signing)
        }
    }
}

flutter {
    source = "../.."
}
