group = "dev.fluttercommunity.plus.share"
version = "1.0-SNAPSHOT"

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}


plugins {
    id("com.android.library")
}

android {
    namespace = "dev.fluttercommunity.plus.share"
    compileSdk = flutter.compileSdkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        minSdk = 21
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    lint {
        disable.add("InvalidPackage")
    }

    dependencies {
        implementation("androidx.core:core-ktx:1.16.0")
        implementation("androidx.annotation:annotation:1.9.1")
        implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    }
}
