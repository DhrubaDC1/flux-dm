plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "io.github.dhrubadc1.flux_dm"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = providers.gradleProperty("fluxNdkVersion")
        .orElse(flutter.ndkVersion).get()

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "io.github.dhrubadc1.flux_dm"
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
        // A stable key lets updates install in place; uninstalling deletes
        // downloads kept in app-private storage.
        if (providers.gradleProperty("fluxKeystore").isPresent) {
            create("release") {
                storeFile = file(providers.gradleProperty("fluxKeystore").get())
                storePassword = providers.gradleProperty("fluxKeystorePassword").get()
                keyAlias = providers.gradleProperty("fluxKeyAlias").get()
                keyPassword = providers.gradleProperty("fluxKeyPassword").get()
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
                ?: signingConfigs.getByName("debug")
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
