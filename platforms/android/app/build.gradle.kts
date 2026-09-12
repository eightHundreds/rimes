import java.security.MessageDigest

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val repoRoot: File = rootProject.projectDir.parentFile.parentFile
val thirdPartyDir: File = rootProject.projectDir.resolve("third_party")
val prebuiltDir: File = thirdPartyDir.resolve("prebuilt")
val openccDataDir: File = thirdPartyDir.resolve("opencc-data")
val rimeAssetsDir: File = layout.buildDirectory.dir("generated/rimeAssets").get().asFile
val requestedAbis: List<String> = (project.findProperty("rimesAbis") as String? ?: "arm64-v8a,x86_64")
    .split(',')
    .map { it.trim() }
    .filter { it.isNotEmpty() }

// ---------------------------------------------------------------------------
// Release signing
//
// A formal release keystore is optional. When the four
// RIMES_ANDROID_RELEASE_* environment variables are all present (wired from
// GitHub secrets by .github/workflows/android-release.yml — see
// platforms/android/README.md for the exact secret names and how to rotate
// them), the release build type is signed with that keystore. Otherwise it
// falls back to the stock Gradle debug keystore, so `assembleRelease` always
// produces an installable, signed APK even before a real keystore exists.
// ---------------------------------------------------------------------------
val releaseKeystorePath: String? = System.getenv("RIMES_ANDROID_RELEASE_KEYSTORE_PATH")
val releaseKeystorePassword: String? = System.getenv("RIMES_ANDROID_RELEASE_KEYSTORE_PASSWORD")
val releaseKeyAlias: String? = System.getenv("RIMES_ANDROID_RELEASE_KEY_ALIAS")
val releaseKeyPassword: String? = System.getenv("RIMES_ANDROID_RELEASE_KEY_PASSWORD")
val hasFormalReleaseSigning: Boolean =
    !releaseKeystorePath.isNullOrBlank() &&
        !releaseKeystorePassword.isNullOrBlank() &&
        !releaseKeyAlias.isNullOrBlank() &&
        !releaseKeyPassword.isNullOrBlank()

android {
    namespace = "com.isaac.inputmethod.rimes"
    compileSdk = 35
    ndkVersion = "27.2.12479018"

    defaultConfig {
        applicationId = "com.isaac.inputmethod.rimes"
        minSdk = 24
        targetSdk = 35
        versionCode = 1
        versionName = "0.5.0-android.1"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        ndk {
            abiFilters += requestedAbis
        }
        externalNativeBuild {
            cmake {
                arguments += listOf(
                    "-DANDROID_STL=c++_static",
                    "-DRIMES_REPO_ROOT=${repoRoot.absolutePath}",
                    "-DRIMES_PREBUILT_DIR=${prebuiltDir.absolutePath}",
                )
                cppFlags += listOf("-std=c++17", "-fexceptions", "-frtti")
            }
        }
    }

    signingConfigs {
        if (hasFormalReleaseSigning) {
            create("release") {
                storeFile = file(releaseKeystorePath!!)
                storePassword = releaseKeystorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = if (hasFormalReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
        debug {
            isMinifyEnabled = false
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    sourceSets {
        getByName("main") {
            assets.srcDir(rimeAssetsDir)
        }
    }

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }

    packaging {
        jniLibs.useLegacyPackaging = false
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.preference:preference-ktx:1.2.1")
    implementation("androidx.recyclerview:recyclerview:1.3.2")
    implementation("com.google.android.material:material:1.12.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlin:kotlin-test-junit:2.0.21")

    androidTestImplementation("androidx.test:core-ktx:1.6.1")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:rules:1.6.1")
    androidTestImplementation("androidx.test.uiautomator:uiautomator:2.3.0")
}

// ---------------------------------------------------------------------------
// Rime data assets
//
// The APK ships exactly the reviewed cross-platform dependency closure that
// scripts/platform-preview/preview.py validates for Windows and Linux, plus the
// stock OpenCC configuration/dictionaries that the closure declares as an
// external runtime dependency. Nothing is copied from rime-data by hand.
// ---------------------------------------------------------------------------
val stageRimeData by tasks.registering(Exec::class) {
    group = "rimes"
    description = "Stage the reviewed rime-data dependency closure into the generated assets directory."
    val stageDir = rimeAssetsDir.resolve("rime")
    inputs.dir(repoRoot.resolve("rime-data"))
    inputs.file(repoRoot.resolve("scripts/platform-preview/policy.json"))
    inputs.file(repoRoot.resolve("scripts/platform-preview/preview.py"))
    outputs.dir(stageDir)
    doFirst {
        stageDir.deleteRecursively()
        stageDir.parentFile.mkdirs()
    }
    commandLine(
        "python3",
        repoRoot.resolve("scripts/platform-preview/preview.py").absolutePath,
        "stage",
        "--repo-root", repoRoot.absolutePath,
        "--output-dir", stageDir.absolutePath,
    )
}

val copyOpenCCData by tasks.registering(Copy::class) {
    group = "rimes"
    description = "Overlay stock OpenCC configuration and dictionaries produced by scripts/build-opencc-data.sh."
    dependsOn(stageRimeData)
    doFirst {
        check(openccDataDir.isDirectory && openccDataDir.resolve("s2t.json").isFile) {
            "Missing stock OpenCC data at $openccDataDir. Run platforms/android/scripts/build-opencc-data.sh first."
        }
    }
    from(openccDataDir) {
        include("*.json", "*.ocd2")
    }
    into(rimeAssetsDir.resolve("rime/opencc"))
}

val writeRimeAssetsVersion by tasks.registering {
    group = "rimes"
    description = "Write a content fingerprint so the app redeploys shared data only when the bundled files change."
    dependsOn(copyOpenCCData)
    val versionFile = rimeAssetsDir.resolve("rime-assets.version")
    outputs.file(versionFile)
    doLast {
        val digest = MessageDigest.getInstance("SHA-256")
        val root = rimeAssetsDir.resolve("rime")
        root.walkTopDown()
            .filter { it.isFile }
            .sortedBy { it.relativeTo(root).invariantSeparatorsPath }
            .forEach { file ->
                digest.update(file.relativeTo(root).invariantSeparatorsPath.toByteArray())
                digest.update(0)
                digest.update(file.readBytes())
                digest.update(0)
            }
        versionFile.writeText(digest.digest().joinToString("") { "%02x".format(it) })
    }
}

val checkPrebuilt by tasks.registering {
    group = "rimes"
    description = "Fail early with a clear message when the pinned prebuilt librime dependencies are absent."
    doLast {
        requestedAbis.forEach { abi ->
            check(prebuiltDir.resolve("librime/$abi/lib/librime.a").isFile) {
                "Missing prebuilt librime for $abi under $prebuiltDir. Run platforms/android/scripts/fetch-prebuilt.sh first."
            }
        }
    }
}

tasks.named("preBuild") {
    dependsOn(writeRimeAssetsVersion, checkPrebuilt)
}
