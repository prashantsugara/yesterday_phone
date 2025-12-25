allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

subprojects {
    project.afterEvaluate {
        if ((project.plugins.hasPlugin("com.android.application") || project.plugins.hasPlugin("com.android.library"))) {
            val android = project.extensions.getByName("android") as com.android.build.gradle.BaseExtension
            android.compileSdkVersion(36)
            
            // Fix "Namespace not specified" error for legacy plugins (e.g. device_apps)
            // Fix "Namespace not specified" error for legacy plugins (e.g. device_apps)
            if (android.namespace == null) {
                val newNamespace = "com.example.${project.name.replace("-", "_")}"
                println("Setting missing namespace for ${project.name}: $newNamespace")
                android.namespace = newNamespace
            }
            
            // Fix JVM Target compatibility
            android.compileOptions {
                sourceCompatibility = JavaVersion.VERSION_17
                targetCompatibility = JavaVersion.VERSION_17
            }
            // Use withGroovyBuilder to safely access dynamic properties if needed, or just try-catch or checks
            // But usually this works:
            if (project.plugins.hasPlugin("kotlin-android")) {
               // Fix for KTS: Configure task directly
               tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
                   kotlinOptions {
                       jvmTarget = "17"
                   }
               }
            }
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}



tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
