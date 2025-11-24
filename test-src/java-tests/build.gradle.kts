plugins {
    java
}

java {
    toolchain {
        languageVersion.set(JavaLanguageVersion.of(21))
    }
}

repositories {
    mavenCentral()
}

dependencies {
    testImplementation("org.junit.jupiter:junit-jupiter:5.11.0")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher:1.11.0")

    // Testcontainers + Postgres
    testImplementation("org.testcontainers:junit-jupiter:1.20.3")
    testImplementation("org.testcontainers:postgresql:1.20.3")
    testImplementation("org.postgresql:postgresql:42.7.4")

    // JSON parsing
    testImplementation("com.fasterxml.jackson.core:jackson-databind:2.18.0")

    // Silence SLF4J "no provider" warnings in tests and provide simple logging.
    // Use testImplementation (not only testRuntimeOnly) so IntelliJ's JUnit runner,
    // when using the IDE classpath instead of Gradle, still includes the binding.
    testImplementation("org.slf4j:slf4j-simple:2.0.16")
}

// Ensure IntelliJ (via Gradle import) marks upstream spec data and local testdata
// as Test Resources for this module. This way they appear under the module as
// "Test Resources" and are on the test runtime classpath in both Gradle and IDE runs.
sourceSets {
    val test by getting {
        resources {
            // Upstream jd spec runner resources (JSON cases, YAML, etc.)
            srcDir(rootProject.file("external/jd/spec/test"))

            // Project-provided spec runner configs and testdata
            srcDir(rootProject.file("test-src/testdata"))
        }
        // Note: If additional non-standard Java/Kotlin test sources are added in the
        // repository outside of this subproject, declare them here with:
        // java.srcDir(rootProject.file("path/to/extra/test/src"))
    }
}

tasks.test {
    useJUnitPlatform()
    // Show standard out/err for easier debugging
    testLogging {
        events("passed", "skipped", "failed", "standardOut", "standardError")
        showExceptions = true
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
        showCauses = true
        showStackTraces = true
    }

    // Always run tests when invoked from the command line so results are visible
    // (avoid Gradle marking the task up-to-date and skipping execution)
    outputs.upToDateWhen { false }

    // Print a concise summary at the end of the test run
    addTestListener(object : org.gradle.api.tasks.testing.TestListener {
        override fun beforeSuite(suite: org.gradle.api.tasks.testing.TestDescriptor) {}
        override fun beforeTest(testDescriptor: org.gradle.api.tasks.testing.TestDescriptor) {}
        override fun afterTest(testDescriptor: org.gradle.api.tasks.testing.TestDescriptor, result: org.gradle.api.tasks.testing.TestResult) {}
        override fun afterSuite(suite: org.gradle.api.tasks.testing.TestDescriptor, result: org.gradle.api.tasks.testing.TestResult) {
            if (suite.parent == null) {
                println("\n==== Test Summary ====")
                println("Result: ${result.resultType}")
                println("Tests: ${result.testCount}, Passed: ${result.successfulTestCount}, Failed: ${result.failedTestCount}, Skipped: ${result.skippedTestCount}")
                println("======================\n")
            }
        }
    })
}
