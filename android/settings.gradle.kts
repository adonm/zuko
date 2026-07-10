pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "ZukoAndroid"
include(":core")

if (gradle.startParameter.projectProperties["zuko.skipAndroidApp"] != "true") {
    include(":app")
}
