import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

fun androidVersionCode(version: String): Int {
    val match = Regex("""^(\d+)\.(\d+)\.(\d+)$""").matchEntire(version)
        ?: error("Android releases require X.Y.Z, got $version")
    val (majorText, minorText, patchText) = match.destructured
    val major = majorText.toLong()
    val minor = minorText.toLong()
    val patch = patchText.toLong()
    require(minor < 1_000 && patch < 1_000)
    val code = major * 1_000_000 + minor * 1_000 + patch
    require(code in 1..2_100_000_000)
    return code.toInt()
}

val cargoVersion = providers.exec {
    commandLine("sh", rootProject.file("../scripts/version.sh").absolutePath)
}.standardOutput.asText.map { it.trim() }
val resolvedVersionName = providers.environmentVariable("ZUKO_VERSION").orElse(cargoVersion).get()
val resolvedVersionCode = providers.environmentVariable("ZUKO_VERSION_CODE")
    .map(String::toInt)
    .getOrElse(androidVersionCode(resolvedVersionName))

val signingEnvironment = listOf(
    "ANDROID_KEYSTORE_PATH",
    "ANDROID_KEYSTORE_PASSWORD",
    "ANDROID_KEY_ALIAS",
    "ANDROID_KEY_PASSWORD",
).associateWith { providers.environmentVariable(it).orNull.orEmpty() }
val signingCount = signingEnvironment.values.count(String::isNotBlank)
require(signingCount == 0 || signingCount == signingEnvironment.size) {
    "Set all Android signing environment variables or none"
}
val signingReady = signingCount == signingEnvironment.size

android {
    namespace = "dev.adonm.zuko"
    compileSdk = 36
    ndkVersion = "29.0.14206865"

    defaultConfig {
        applicationId = "dev.adonm.zuko"
        minSdk = 29
        targetSdk = 36
        versionCode = resolvedVersionCode
        versionName = resolvedVersionName

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        vectorDrawables.useSupportLibrary = true

        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
        externalNativeBuild {
            cmake {
                arguments += "-DANDROID_STL=none"
            }
        }
    }

    signingConfigs {
        if (signingReady) {
            create("release") {
                storeFile = file(signingEnvironment.getValue("ANDROID_KEYSTORE_PATH"))
                storePassword = signingEnvironment.getValue("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = signingEnvironment.getValue("ANDROID_KEY_ALIAS")
                keyPassword = signingEnvironment.getValue("ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
        release {
            isMinifyEnabled = false
            if (signingReady) signingConfig = signingConfigs.getByName("release")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }
    packaging {
        jniLibs.useLegacyPackaging = false
        resources.excludes += setOf(
            "/META-INF/{AL2.0,LGPL2.1}",
            // The cross-platform iroh JAR embeds desktop binaries as ordinary
            // resources. Android uses the pinned ABI libraries built above.
            "/darwin-aarch64/**",
            "/linux-aarch64/**",
            "/linux-x86-64/**",
            "/win32-x86-64/**",
        )
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }
    kotlinOptions {
        jvmTarget = "21"
        freeCompilerArgs += "-opt-in=kotlin.ExperimentalUnsignedTypes"
    }
    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

dependencies {
    implementation(project(":core"))

    val composeBom = platform("androidx.compose:compose-bom:2025.08.00")
    implementation(composeBom)
    androidTestImplementation(composeBom)

    implementation("androidx.core:core-ktx:1.17.0")
    implementation("androidx.activity:activity-compose:1.11.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.9.3")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.3")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    debugImplementation("androidx.compose.ui:ui-tooling")

    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("computer.iroh:iroh:1.0.0") {
        exclude(group = "net.java.dev.jna", module = "jna")
    }
    // 5.19.1's Android binaries are 16 KiB-page compatible. Older 5.15.0
    // works functionally but fails Android's current native alignment check.
    implementation("net.java.dev.jna:jna:5.19.1@aar")

    testImplementation(kotlin("test"))
    testImplementation("org.junit.jupiter:junit-jupiter:5.13.4")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.7.0")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}

tasks.withType<Test>().configureEach {
    useJUnitPlatform()
}
