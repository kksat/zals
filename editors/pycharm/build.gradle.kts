plugins {
    id("java")
    id("org.jetbrains.kotlin.jvm") version "1.9.24"
    id("org.jetbrains.intellij.platform") version "2.0.1"
}

group = "com.kksat"
version = "0.1.0"

repositories {
    mavenCentral()
    intellijPlatform {
        defaultRepositories()
    }
}

dependencies {
    intellijPlatform {
        pycharmProfessional("2024.1")
        bundledPlugin("com.intellij.modules.json")
    }
    implementation("org.jetbrains.kotlin:kotlin-stdlib")
}

intellijPlatform {
    pluginConfiguration {
        id = "com.kksat.zals"
        name = "Ansible Language Server (zals)"
        version = project.version.toString()
        vendor {
            name = "kksat"
            url = "https://github.com/kksat/zals"
        }
        description = """
            Provides language intelligence for Ansible playbooks, roles, tasks, and variables
            using zals (Zig Ansible Language Server).
        """.trimIndent()
    }
}

tasks {
    withType<JavaCompile> {
        sourceCompatibility = "17"
        targetCompatibility = "17"
    }
    withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile> {
        kotlinOptions.jvmTarget = "17"
    }
}
