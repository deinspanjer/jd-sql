plugins {
    // Enable automatic provisioning of Java toolchains via Foojay
    id("org.gradle.toolchains.foojay-resolver-convention") version "0.8.0"
}

rootProject.name = "jd-sql"

// Java integration tests live under test-src/java-tests
include("test-src:java-tests")
