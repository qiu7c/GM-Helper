plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "cn.gdgm.nativeapp"
    compileSdk = 35
    defaultConfig {
        applicationId = "cn.gdgm.schedule.gdgm_schedule"
        minSdk = 26
        targetSdk = 35
        versionCode = 20
        versionName = "3.0.0"
    }
    buildTypes {
        debug {
            applicationIdSuffix = ".nativepreview"
            versionNameSuffix = "-preview"
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    sourceSets["test"].resources.srcDir("../../fixtures")
    testOptions { unitTests.isReturnDefaultValues = true }
}

dependencies {
    implementation("org.jsoup:jsoup:1.18.3")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
