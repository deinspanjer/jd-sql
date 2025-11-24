plugins {
    // empty root; subprojects define their own plugins
}

allprojects {
    repositories {
        mavenCentral()
    }

    // Direct all Gradle build outputs into the project-level out/ directory
    // This keeps the working tree clean and avoids unversioned files outside of out/
    // Example structure: out/gradle/test-src/java-tests/...
    layout.buildDirectory.set(file("${rootDir}/out/gradle/${project.path.replace(":", "/").trimStart('/')}"))
}
