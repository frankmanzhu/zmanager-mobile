import org.gradle.api.tasks.Exec

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

val mobileRoot = rootProject.projectDir.parentFile
val zmanagerRoot = mobileRoot.resolve("../zmanager").canonicalFile
val generatedJniDir = project.file("src/main/jniLibs/arm64-v8a")

val buildZmanagerFfi by tasks.registering(Exec::class) {
    description = "Build the zmanager-ffi Android library from the sibling zmanager repository."
    group = "build"
    workingDir(mobileRoot)
    inputs.dir(zmanagerRoot.resolve("crates"))
    inputs.files(zmanagerRoot.resolve("Cargo.toml"), zmanagerRoot.resolve("Cargo.lock"))
    outputs.files(
        generatedJniDir.resolve("libzmanager_ffi.so"),
        generatedJniDir.resolve("libc++_shared.so")
    )
    commandLine("bash", mobileRoot.resolve("scripts/build-android-rust.sh").absolutePath)
}

tasks.named("preBuild").configure {
    dependsOn(buildZmanagerFfi)
}

android {
    namespace = "org.tzap.zmanager.mobile"
    compileSdk = 35

    defaultConfig {
        applicationId = "org.tzap.zmanager.mobile"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
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
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("net.java.dev.jna:jna:5.15.0@aar")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.14.1")

    debugImplementation("androidx.compose.ui:ui-tooling")
}
