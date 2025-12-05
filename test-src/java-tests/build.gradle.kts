plugins {
    java
    idea
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
    @Suppress("unused") val test by getting {
        resources {
            // Only include necessary upstream spec resources, not the entire test tree
            // to avoid bringing in binaries like the upstream test-runner or last test results.
            // Keep just the JSON spec cases needed by our Java tests.
            srcDir(rootProject.file("external/jd/spec/test/cases"))

            // Project-provided resources (trimmed to what Java tests actually need)
            // - Custom/spec-extension cases used by java-tests
            srcDir(rootProject.file("test-src/testdata/cases"))
            // - Configs for jd-sql-spec-runner (if referenced by tests)
            srcDir(rootProject.file("test-src/testdata/jd-sql-spec-runner/configs"))
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
    addTestListener(object : TestListener {
        override fun beforeSuite(suite: TestDescriptor) {}
        override fun beforeTest(testDescriptor: TestDescriptor) {}
        override fun afterTest(testDescriptor: TestDescriptor, result: TestResult) {}
        override fun afterSuite(suite: TestDescriptor, result: TestResult) {
            if (suite.parent == null) {
                println("\n==== Test Summary ====")
                println("Result: ${result.resultType}")
                println("Tests: ${result.testCount}, Passed: ${result.successfulTestCount}, Failed: ${result.failedTestCount}, Skipped: ${result.skippedTestCount}")
                println("======================\n")
            }
        }
    })
}

// Ensure IntelliJ uses the same output directories as Gradle so that
// running tests from the IDE doesn't create a separate test-src/java-tests/out tree.
idea {
    module {
        inheritOutputDirs = false
        // Match Gradle's build/classes layout under the unified root out/ directory
        outputDir = layout.buildDirectory.dir("classes/java/main").get().asFile
        testOutputDir = layout.buildDirectory.dir("classes/java/test").get().asFile
    }
}
