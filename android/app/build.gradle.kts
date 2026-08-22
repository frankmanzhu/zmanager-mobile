import org.gradle.api.tasks.Exec
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

val mobileRoot = rootProject.projectDir.parentFile
val zmanagerRelativeDir = providers.environmentVariable("ZMANAGER_RELATIVE_DIR")
    .orElse("../zmanager")
val zmanagerRoot = providers.environmentVariable("ZMANAGER_DIR")
    .orElse(mobileRoot.resolve(zmanagerRelativeDir.get()).path)
    .map(mobileRoot::resolve)
    .map { it.canonicalFile }
    .get()
// Keep in sync with the default ABI set in scripts/build-android-rust.sh.
// x86_64 is deliberately not a default: see that script for why it currently
// fails to link.
val androidAbis = (System.getenv("ZMANAGER_ANDROID_ABIS") ?: "arm64-v8a").split(" ")
val jniLibsDir = project.file("src/main/jniLibs")

val buildZmanagerFfi by tasks.registering(Exec::class) {
    description = "Build the pinned zmanager-ffi Android library for every configured ABI."
    group = "build"
    workingDir(mobileRoot)
    inputs.dir(zmanagerRoot.resolve("crates"))
    inputs.files(zmanagerRoot.resolve("Cargo.toml"), zmanagerRoot.resolve("Cargo.lock"))
    outputs.files(
        androidAbis.flatMap { abi ->
            listOf(
                jniLibsDir.resolve("$abi/libzmanager_ffi.so"),
                jniLibsDir.resolve("$abi/libc++_shared.so")
            )
        }
    )
    commandLine("bash", mobileRoot.resolve("scripts/build-android-rust.sh").absolutePath)
}

tasks.named("preBuild").configure {
    dependsOn(buildZmanagerFfi)
}

// Release signing is never checked in. Populate android/local.properties
// (already gitignored, already the standard per-machine Android config file)
// with RELEASE_STORE_FILE / RELEASE_STORE_PASSWORD / RELEASE_KEY_ALIAS /
// RELEASE_KEY_PASSWORD, or set the ZMANAGER_RELEASE_* environment variables
// for CI. Neither present means the release build type is left unsigned
// rather than failing Gradle configuration.
val localProperties = Properties().apply {
    val localPropertiesFile = rootProject.file("local.properties")
    if (localPropertiesFile.exists()) {
        localPropertiesFile.inputStream().use(::load)
    }
}

fun signingProperty(key: String): String? =
    localProperties.getProperty("RELEASE_$key") ?: System.getenv("ZMANAGER_RELEASE_$key")

android {
    namespace = "org.tzap.zmanager.mobile"
    compileSdk = 35

    defaultConfig {
        applicationId = "org.tzap.zmanager.mobile"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk {
            abiFilters += androidAbis
        }
    }

    signingConfigs {
        create("release") {
            val storeFilePath = signingProperty("STORE_FILE")
            if (storeFilePath != null) {
                storeFile = rootProject.file(storeFilePath)
                storePassword = signingProperty("STORE_PASSWORD")
                keyAlias = signingProperty("KEY_ALIAS")
                keyPassword = signingProperty("KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            if (signingConfigs.getByName("release").storeFile != null) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        buildConfig = true
        compose = true
    }

}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2025.01.00")
    implementation(composeBom)
    androidTestImplementation(composeBom)

    implementation("androidx.activity:activity-compose:1.10.0")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.documentfile:documentfile:1.0.1")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("net.java.dev.jna:jna:5.15.0@aar")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.14.1")

    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:rules:1.6.1")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    androidTestImplementation("androidx.test.uiautomator:uiautomator:2.3.0")

    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
