package dev.jdsql;

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
import java.util.List;
import java.util.stream.Collectors;

import static org.junit.jupiter.api.Assertions.*;

@TestMethodOrder(MethodOrderer.OrderAnnotation.class)
@Execution(ExecutionMode.SAME_THREAD)
public class PgSpecIT {

    private static List<Path> pgSqlFiles;
    private static List<SpecCase> allCases;
    private static java.util.Set<String> categories;
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
        String catStr = System.getProperty("jdsql.spec.categories",
                System.getenv().getOrDefault("JDSQL_SPEC_CATEGORIES", "")).trim();
        categories = java.util.Arrays.stream(catStr.isEmpty() ? new String[]{} : catStr.split(","))
                .map(String::trim)
                .filter(s -> !s.isEmpty())
                .map(String::toLowerCase)
                .collect(java.util.stream.Collectors.toCollection(java.util.LinkedHashSet::new));
        List<SpecCase> upstream = SpecLoader.loadUpstreamCases();
        List<SpecCase> project = SpecLoader.loadProjectCases();
        allCases = new ArrayList<>();
        allCases.addAll(filterByCategories(upstream));
        allCases.addAll(filterByCategories(project));
    }

    private static List<SpecCase> filterByCategories(List<SpecCase> in) {
        if (categories.isEmpty()) return in; // default: run all categories when not specified
        return in.stream()
                .filter(c -> categories.contains(normalizeCategory(c)))
                .collect(Collectors.toList());
    }

    private static String normalizeCategory(SpecCase c) {
        String cat = c.category == null ? "" : c.category.toLowerCase();
        switch (cat) {
            case "core":
                return "jd-core";
            case "options":
                return "jd-options";
            case "path_options":
                return "jd-path_options";
            case "format":
            case "translation":
            case "patching":
                return "jd-format";
            case "errors":
                return "jd-errors";
            case "edge_cases":
                return "jd-edge_cases";
            default:
                // Pass-through for already prefixed categories like jd-sql-custom, etc.
                return cat;
        }
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

    @SuppressWarnings("resource")
    private List<DynamicTest> createContainerBackedTests(Path sqlFile, List<SpecCase> cases) {
        List<DynamicTest> tests = new ArrayList<>();
        tests.add(DynamicTest.dynamicTest("pg-container:start:" + sqlFile.getFileName(), () -> {
            DockerImageName image = DockerImageName.parse("postgres:17");
            @SuppressWarnings("resource")
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
            String displayName = sqlFile.getFileName() + " :: " + normalizeCategory(c) + "/" + c.name;
            tests.add(DynamicTest.dynamicTest(displayName, () -> {
                PostgreSQLContainer<?> pg = containers.get(sqlFile);
                assertNotNull(pg, "Container not started for " + sqlFile);
                String url = jdbcUrls.get(sqlFile);
                try (Connection conn = DriverManager.getConnection(url, pg.getUsername(), pg.getPassword())) {
                    conn.setAutoCommit(true);

                    // sanity: jd_diff exists with options parameter
                    assertTrue(functionExists(conn, "jd_diff", 3), "jd_diff(a jsonb, b jsonb, options jsonb) must exist");

                    String a = SpecLoader.normalizeContentForJsonb(c.content_a);
                    String b = SpecLoader.normalizeContentForJsonb(c.content_b);
                    String options = buildOptionsJson(c);
                    if (Boolean.TRUE.equals(c.should_error)) {
                        boolean aInvalid = isInvalidJson(a);
                        boolean bInvalid = isInvalidJson(b);
                        if (aInvalid || bInvalid) {
                            assertThrows(SQLException.class, () -> callJdDiff(conn, a, b, options),
                                    () -> "Expected SQL error for case " + c.name);
                            return;
                        }
                        // CLI-only error case (e.g., too many args, nonexistent file). For SQL, just ensure call succeeds.
                        assertDoesNotThrow(() -> callJdDiff(conn, a, b, options), () -> "SQL should not error for CLI-only case " + c.name);
                    } else {
                        String diff = callJdDiff(conn, a, b, options);
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

    @SuppressWarnings("SameParameterValue")
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

    private static String callJdDiff(Connection conn, String a, String b, String optionsJson) throws SQLException {
        String sql = "select jd_diff(?::jsonb, ?::jsonb, ?::jsonb)";
        try (PreparedStatement ps = conn.prepareStatement(sql)) {
            if (a == null) ps.setNull(1, java.sql.Types.VARCHAR); else ps.setString(1, a);
            if (b == null) ps.setNull(2, java.sql.Types.VARCHAR); else ps.setString(2, b);
            if (optionsJson == null) ps.setNull(3, java.sql.Types.VARCHAR); else ps.setString(3, optionsJson);
            try (ResultSet rs = ps.executeQuery()) {
                rs.next();
                String res = rs.getString(1);
                return res == null ? "" : res;
            }
        }
    }

    private static String buildOptionsJson(SpecCase c) {
        if (c.args == null || c.args.isEmpty()) return null;
        // If -opts=JSON is present, pass it through as-is
        for (String arg : c.args) {
            if (arg != null && arg.startsWith("-opts=")) {
                String json = arg.substring("-opts=".length());
                // Validate JSON is an array; if invalid, ignore for SQL runner
                try {
                    com.fasterxml.jackson.databind.JsonNode n = JSON.readTree(json);
                    if (n != null && n.isArray()) return json;
                } catch (IOException ignored) {
                    // ignore invalid opts for SQL tests (CLI-only error)
                }
                return null;
            }
        }
        // Map simple flags to options array (minimal: support -set for now)
        boolean set = false;
        for (String arg : c.args) {
            if ("-set".equals(arg)) set = true;
        }
        if (set) {
            return "[\"SET\"]";
        }
        return null;
    }

    private static boolean isInvalidJson(String s) {
        if (s == null) return false; // SQL NULL represents void; not invalid JSON
        try {
            JSON.readTree(s);
            return false;
        } catch (IOException e) {
            return true;
        }
    }
}
