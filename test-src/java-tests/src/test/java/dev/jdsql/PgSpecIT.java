package dev.jdsql;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.parallel.Execution;
import org.junit.jupiter.api.parallel.ExecutionMode;
import org.junit.jupiter.api.DynamicTest;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.utility.DockerImageName;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.*;
import java.util.ArrayList;
import java.util.Collection;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.*;

@TestMethodOrder(MethodOrderer.OrderAnnotation.class)
@Execution(ExecutionMode.SAME_THREAD)
public class PgSpecIT {

    private static List<Path> pgSqlFiles;
    private static List<SpecCase> allCases;
    private static String level;
    private static final ObjectMapper JSON = new ObjectMapper();
    // We manage one container per SQL install file to balance isolation and performance
    private static final java.util.Map<Path, PostgreSQLContainer<?>> containers = new java.util.concurrent.ConcurrentHashMap<>();
    private static final java.util.Map<Path, String> jdbcUrls = new java.util.concurrent.ConcurrentHashMap<>();

    @BeforeAll
    static void discover() throws IOException {
        pgSqlFiles = SpecLoader.findSqlInstallScripts().stream()
                .filter(p -> p.toString().contains("/postgres/"))
                .sorted()
                .collect(Collectors.toList());
        level = System.getProperty("jdsql.spec.level", System.getenv().getOrDefault("JDSQL_SPEC_LEVEL", "core"));
        List<SpecCase> upstream = SpecLoader.loadUpstreamCases();
        List<SpecCase> project = SpecLoader.loadProjectCases();
        allCases = new ArrayList<>();
        allCases.addAll(filterByLevel(upstream));
        allCases.addAll(filterByLevel(project));
    }

    private static List<SpecCase> filterByLevel(List<SpecCase> in) {
        if (level.equalsIgnoreCase("all")) return in;
        // default: only core cases
        return in.stream()
                .filter(c -> c.compliance_level == null || c.compliance_level.equalsIgnoreCase("core"))
                .collect(Collectors.toList());
    }

    @TestFactory
    @Order(1)
    Collection<DynamicTest> runPgSqlFilesAgainstCases() {
        List<DynamicTest> tests = new ArrayList<>();
        for (Path sqlFile : pgSqlFiles) {
            tests.add(DynamicTest.dynamicTest("install:" + sqlFile.getFileName(), () -> {
                // Just a marker test name placeholder; actual tests per case below
                assertTrue(Files.exists(sqlFile));
            }));

            // Use a single container; switch installed SQL per file on-demand
            tests.addAll(createContainerBackedTests(sqlFile, allCases));
        }
        return tests;
    }

    private List<DynamicTest> createContainerBackedTests(Path sqlFile, List<SpecCase> cases) {
        List<DynamicTest> tests = new ArrayList<>();
        tests.add(DynamicTest.dynamicTest("pg-container:start:" + sqlFile.getFileName(), () -> {
            DockerImageName image = DockerImageName.parse("postgres:17");
            PostgreSQLContainer<?> pg = new PostgreSQLContainer<>(image)
                    .withDatabaseName("postgres")
                    .withUsername("postgres")
                    .withPassword("postgres")
                    .withReuse(true);
            pg.start();
            // Install SQL once into the default database for this container
            installSql(pg, sqlFile, pg.getDatabaseName());
            containers.put(sqlFile, pg);
            jdbcUrls.put(sqlFile, pg.getJdbcUrl());
        }));

        for (SpecCase c : cases) {
            String displayName = sqlFile.getFileName() + " :: " + c.category + "/" + c.name;
            tests.add(DynamicTest.dynamicTest(displayName, () -> {
                PostgreSQLContainer<?> pg = containers.get(sqlFile);
                assertNotNull(pg, "Container not started for " + sqlFile);
                String url = jdbcUrls.get(sqlFile);
                try (Connection conn = DriverManager.getConnection(url, pg.getUsername(), pg.getPassword())) {
                    conn.setAutoCommit(true);

                    // sanity: jd_diff exists
                    assertTrue(functionExists(conn, "jd_diff", 2), "jd_diff(a jsonb, b jsonb) must exist");

                    String a = SpecLoader.normalizeContentForJsonb(c.content_a);
                    String b = SpecLoader.normalizeContentForJsonb(c.content_b);
                    if (Boolean.TRUE.equals(c.should_error)) {
                        boolean aInvalid = isInvalidJson(a);
                        boolean bInvalid = isInvalidJson(b);
                        if (aInvalid || bInvalid) {
                            assertThrows(SQLException.class, () -> callJdDiff(conn, a, b),
                                    () -> "Expected SQL error for case " + c.name);
                            return;
                        }
                        // CLI-only error case (e.g., too many args, nonexistent file). For SQL, just ensure call succeeds.
                        assertDoesNotThrow(() -> callJdDiff(conn, a, b), () -> "SQL should not error for CLI-only case " + c.name);
                    } else {
                        String diff = callJdDiff(conn, a, b);
                        if (c.expected_exit == 0) {
                            assertEquals("", diff, "Expected no differences");
                        } else {
                            String expected = c.expected_diff == null ? null : c.expected_diff;
                            assertNotNull(expected, "expected_diff must be provided when expected_exit != 0");
                            assertEquals(expected.trim(), diff.trim(), () -> "Diff mismatch for case " + c.name);
                        }
                    }
                }
            }));
        }
        // add teardown to stop container after all cases for this sql file
        tests.add(DynamicTest.dynamicTest("pg-container:stop:" + sqlFile.getFileName(), () -> {
            PostgreSQLContainer<?> pg = containers.remove(sqlFile);
            if (pg != null) {
                try {
                    pg.stop();
                } finally {
                    jdbcUrls.remove(sqlFile);
                }
            }
        }));
        return tests;
    }

    private static String jdbcUrlForDb(PostgreSQLContainer<?> pg, String dbName) {
        String host = pg.getHost();
        Integer port = pg.getMappedPort(5432);
        return "jdbc:postgresql://" + host + ":" + port + "/" + dbName;
    }

    private static void installSql(PostgreSQLContainer<?> pg, Path sqlFile, String dbName) {
        // Copy SQL file into the container and execute with psql to properly handle dollar-quoting and multiple statements
        String containerPath = "/tmp/jd_install.sql";
        pg.copyFileToContainer(org.testcontainers.utility.MountableFile.forHostPath(sqlFile), containerPath);
        try {
            org.testcontainers.containers.Container.ExecResult res = pg.execInContainer(
                "bash", "-lc",
                "psql -v ON_ERROR_STOP=1 -U " + pg.getUsername() + " -d " + dbName + " -f " + containerPath
            );
            if (res.getExitCode() != 0) {
                throw new RuntimeException("Failed to install SQL: exit=" + res.getExitCode() + "\nstdout=" + res.getStdout() + "\nstderr=" + res.getStderr());
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new RuntimeException(e);
        } catch (IOException e) {
            throw new RuntimeException(e);
        }
    }

    // No database recreation needed when using one container per SQL file.

    private static boolean functionExists(Connection conn, String name, int argCount) throws SQLException {
        String q = "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace " +
                "where n.nspname='public' and p.proname=? and p.pronargs=?";
        try (PreparedStatement ps = conn.prepareStatement(q)) {
            ps.setString(1, name);
            ps.setInt(2, argCount);
            try (ResultSet rs = ps.executeQuery()) {
                rs.next();
                return rs.getInt(1) > 0;
            }
        }
    }

    private static String callJdDiff(Connection conn, String a, String b) throws SQLException {
        String sql = "select jd_diff(?::jsonb, ?::jsonb)";
        try (PreparedStatement ps = conn.prepareStatement(sql)) {
            if (a == null) ps.setNull(1, java.sql.Types.VARCHAR); else ps.setString(1, a);
            if (b == null) ps.setNull(2, java.sql.Types.VARCHAR); else ps.setString(2, b);
            try (ResultSet rs = ps.executeQuery()) {
                rs.next();
                String res = rs.getString(1);
                return res == null ? "" : res;
            }
        }
    }

    private static boolean isInvalidJson(String s) {
        if (s == null) return false; // SQL NULL represents void; not invalid JSON
        try {
            JSON.readTree(s);
            return false;
        } catch (JsonProcessingException e) {
            return true;
        }
    }
}
