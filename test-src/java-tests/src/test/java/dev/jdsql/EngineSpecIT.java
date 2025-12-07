package dev.jdsql;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.parallel.Execution;
import org.junit.jupiter.api.parallel.ExecutionMode;
import org.junit.jupiter.api.DynamicTest;
import org.junit.jupiter.api.DynamicNode;
import org.junit.jupiter.api.DynamicContainer;
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
public class EngineSpecIT {

    private static List<Path> engineSqlFiles;
    private static List<SpecCase> allCases;
    private static java.util.Set<String> categories;
    private static final ObjectMapper JSON = new ObjectMapper();
    // We manage one container per SQL install file to balance isolation and performance
    private static final java.util.Map<Path, PostgreSQLContainer<?>> containers = new java.util.concurrent.ConcurrentHashMap<>();
    private static final java.util.Map<Path, String> jdbcUrls = new java.util.concurrent.ConcurrentHashMap<>();

    @BeforeAll
    static void discover() throws IOException {
        // For now, only Postgres is supported by the containerized runner.
        // We still prepare the list generically as "engineSqlFiles" to pave the way for other engines.
        engineSqlFiles = SpecLoader.findSqlInstallScripts().stream()
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
    Collection<DynamicNode> runEngineScriptsAgainstCases() {
        // Build hierarchy: Engine -> Version -> Variant -> (bootstrap, cases, teardown)
        java.util.Map<String, java.util.Map<String, java.util.Map<String, List<Path>>>> tree = new java.util.LinkedHashMap<>();
        for (Path sqlFile : engineSqlFiles) {
            EngineScript meta = EngineScript.from(sqlFile);
            tree
                .computeIfAbsent(meta.engineDisplayName, k -> new java.util.LinkedHashMap<>())
                .computeIfAbsent(meta.versionDisplay(), k -> new java.util.LinkedHashMap<>())
                .computeIfAbsent(meta.variantDisplay(), k -> new ArrayList<>())
                .add(sqlFile);
        }

        List<DynamicNode> engines = new ArrayList<>();
        for (var engineEntry : tree.entrySet()) {
            String engineName = engineEntry.getKey();
            var versionsMap = engineEntry.getValue();
            // If only a single implicit version ("default"), elide the version level
            if (versionsMap.size() == 1 && versionsMap.containsKey("default")) {
                List<DynamicNode> variants = new ArrayList<>();
                for (var varEntry : versionsMap.get("default").entrySet()) {
                    String variantName = varEntry.getKey();
                    List<Path> scripts = varEntry.getValue();
                    List<DynamicNode> variantChildren = new ArrayList<>();
                    for (Path script : scripts) {
                        variantChildren.add(createContainerBackedNodes(script, allCases, engineName, "default", variantName));
                    }
                    DynamicNode variantContainer = scripts.size() == 1
                            ? unwrapSingleTopLevel((DynamicContainer) createContainerBackedNodes(scripts.get(0), allCases, engineName, "default", variantName), variantName)
                            : DynamicContainer.dynamicContainer(variantName, variantChildren);
                    variants.add(variantContainer);
                }
                engines.add(DynamicContainer.dynamicContainer(engineName, variants));
            } else {
                List<DynamicNode> versions = new ArrayList<>();
                for (var verEntry : versionsMap.entrySet()) {
                    String versionName = verEntry.getKey();
                    List<DynamicNode> variants = new ArrayList<>();
                    for (var varEntry : verEntry.getValue().entrySet()) {
                        String variantName = varEntry.getKey();
                        List<Path> scripts = varEntry.getValue();

                        List<DynamicNode> variantChildren = new ArrayList<>();
                        // If multiple scripts target the same variant, create one sub-container per script
                        for (Path script : scripts) {
                            variantChildren.add(createContainerBackedNodes(script, allCases, engineName, versionName, variantName));
                        }
                        // If only one script under this variant, expose bootstrap/cases/teardown directly as children
                        DynamicNode variantContainer = scripts.size() == 1
                                ? unwrapSingleTopLevel((DynamicContainer) createContainerBackedNodes(scripts.get(0), allCases, engineName, versionName, variantName), variantName)
                                : DynamicContainer.dynamicContainer(variantName, variantChildren);
                        variants.add(variantContainer);
                    }
                    versions.add(DynamicContainer.dynamicContainer(versionName, variants));
                }
                engines.add(DynamicContainer.dynamicContainer(engineName, versions));
            }
        }
        return engines;
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
                // Skip YAML-mode cases by default: SQL runner does not support YAML I/O
                if (containsYamlArg(c) && !yamlEnabled()) {
                    org.junit.jupiter.api.Assumptions.assumeTrue(false,
                            "Skipping yaml_mode: YAML input/output not supported by SQL runner (enable with -Djdsql.enable.yaml=true or JDSQL_ENABLE_YAML=1)");
                }
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
                        DiffResult diffRes = callDiff(conn, a, b, options, c);
                        if (c.expected_exit == 0) {
                            if (diffRes.isJson) {
                                // For structured JSON results, consider an empty/falsey structure as no diff.
                                // Current implementation returns text (JSON string), but be future-proof.
                                assertEquals("", diffRes.asComparableString().trim(), "Expected no differences");
                            } else {
                                assertEquals("", diffRes.asComparableString(), "Expected no differences");
                            }
                        } else {
                            String expected = c.expected_diff == null ? null : c.expected_diff;
                            assertNotNull(expected, "expected_diff must be provided when expected_exit != 0");
                            assertEquals(expected.trim(), diffRes.asComparableString().trim(), () -> "Diff mismatch for case " + c.name);
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

    // New grouped representation using DynamicContainer for clearer test tree
    @SuppressWarnings("resource")
    private DynamicContainer createContainerBackedNodes(Path sqlFile, List<SpecCase> cases, String engineName, String versionName, String variantName) {
        List<DynamicNode> children = new ArrayList<>();

        // Preliminary install/check container
        children.add(DynamicContainer.dynamicContainer("bootstrap", java.util.List.of(
                DynamicTest.dynamicTest("install:" + sqlFile.getFileName(), () -> assertTrue(Files.exists(sqlFile))),
                DynamicTest.dynamicTest(engineLabel("container:start", engineName, variantName) + ":" + sqlFile.getFileName(), () -> {
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
                })
        )));

        // Group cases by normalized category
        java.util.Map<String, List<SpecCase>> byCat = new java.util.LinkedHashMap<>();
        for (SpecCase c : cases) {
            String cat = normalizeCategory(c);
            byCat.computeIfAbsent(cat == null || cat.isEmpty() ? "uncategorized" : cat, k -> new ArrayList<>()).add(c);
        }

        for (java.util.Map.Entry<String, List<SpecCase>> e : byCat.entrySet()) {
            String cat = e.getKey();
            List<SpecCase> inCat = e.getValue();
            // Stable order by case name for readability
            inCat.sort(java.util.Comparator.comparing(sc -> sc.name == null ? "" : sc.name));

            List<DynamicNode> caseTests = new ArrayList<>();
            for (SpecCase c : inCat) {
                String displayName = normalizeCategory(c) + "/" + c.name;
                caseTests.add(DynamicTest.dynamicTest(displayName, () -> {
                    // Skip YAML-mode cases by default
                    if (containsYamlArg(c) && !yamlEnabled()) {
                        org.junit.jupiter.api.Assumptions.assumeTrue(false,
                                "Skipping yaml_mode: YAML input/output not supported by SQL runner (enable with -Djdsql.enable.yaml=true or JDSQL_ENABLE_YAML=1)");
                    }
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
                            // CLI-only error case: ensure call succeeds.
                            assertDoesNotThrow(() -> callJdDiff(conn, a, b, options), () -> "SQL should not error for CLI-only case " + c.name);
                        } else {
                            DiffResult diffRes = callDiff(conn, a, b, options, c);
                            if (c.expected_exit == 0) {
                                if (diffRes.isJson) {
                                    assertEquals("", diffRes.asComparableString().trim(), "Expected no differences");
                                } else {
                                    assertEquals("", diffRes.asComparableString(), "Expected no differences");
                                }
                            } else {
                                String expected = c.expected_diff == null ? null : c.expected_diff;
                                assertNotNull(expected, "expected_diff must be provided when expected_exit != 0");
                                assertEquals(expected.trim(), diffRes.asComparableString().trim(), () -> "Diff mismatch for case " + c.name);
                            }
                        }
                    }
                }));
            }
            children.add(DynamicContainer.dynamicContainer("cases:" + cat, caseTests));
        }

        // Teardown group
        children.add(DynamicContainer.dynamicContainer("teardown", java.util.List.of(
                DynamicTest.dynamicTest(engineLabel("container:stop", engineName, variantName) + ":" + sqlFile.getFileName(), () -> {
                    PostgreSQLContainer<?> pg = containers.remove(sqlFile);
                    if (pg != null) {
                        try {
                            pg.stop();
                        } finally {
                            jdbcUrls.remove(sqlFile);
                        }
                    }
                })
        )));

        return DynamicContainer.dynamicContainer(sqlFile.getFileName().toString(), children);
    }

    // Helper: if a top-level container only wraps one script under a variant, present its children directly
    private DynamicContainer unwrapSingleTopLevel(DynamicContainer container, String variantName) {
        return DynamicContainer.dynamicContainer(variantName, container.getChildren());
    }

    private static String engineLabel(String prefix, String engineName, String variantName) {
        // e.g., "PostgreSQL/plpgsql: container:start" -> "postgresql-plpgsql-container:start"; but keep readable
        return (engineName + "/" + variantName + " " + prefix).toLowerCase().replace(' ', ':');
    }

    // Representation of metadata for an install script path
    private static class EngineScript {
        final String engineKey;           // e.g., "postgres"
        final String engineDisplayName;   // e.g., "PostgreSQL"
        final String version;             // raw version token or "default"
        final String variant;             // implementation variant
        final Path path;

        private EngineScript(String engineKey, String engineDisplayName, String version, String variant, Path path) {
            this.engineKey = engineKey;
            this.engineDisplayName = engineDisplayName;
            this.version = version;
            this.variant = variant;
            this.path = path;
        }

        static EngineScript from(Path p) {
            // expect: .../sql/<engine>/(<version>/)?<file>.sql
            List<String> parts = new ArrayList<>();
            for (Path part : p) parts.add(part.toString());
            int sqlIdx = -1;
            for (int i = 0; i < parts.size(); i++) {
                if (parts.get(i).equals("sql")) { sqlIdx = i; break; }
            }
            String engine = (sqlIdx >= 0 && sqlIdx + 1 < parts.size()) ? parts.get(sqlIdx + 1) : "unknown";
            String version = "default";
            int fileIdx = parts.size() - 1;
            if (sqlIdx + 2 < fileIdx) {
                String maybeVersion = parts.get(sqlIdx + 2);
                if (maybeVersion.matches("(?i)^(v?\\d+([_.]\\d+)*)$")) {
                    version = maybeVersion.replace('_', '.');
                }
            }
            String file = parts.get(fileIdx);
            String base = file.endsWith(".sql") ? file.substring(0, file.length() - 4) : file;
            String variant = extractVariant(engine, base);
            return new EngineScript(engine, displayEngine(engine), version, variant, p);
        }

        String versionDisplay() { return version; }
        String variantDisplay() { return variant; }
    }

    private static String displayEngine(String engine) {
        switch (engine.toLowerCase()) {
            case "postgres":
            case "postgresql":
                return "PostgreSQL";
            case "duckdb":
                return "duckdb";
            case "sqlite":
                return "sqlite";
            case "databricks":
                return "databricks";
            default:
                return engine;
        }
    }

    private static String extractVariant(String engine, String baseName) {
        // Heuristics: prefer known tokens at the end of the filename (e.g., *_plpgsql, *_plv8)
        String lower = baseName.toLowerCase();
        String[] known = {"plpgsql", "plv8"};
        for (String k : known) {
            if (lower.endsWith("_" + k) || lower.endsWith("-" + k) || lower.equals(k)) return k;
        }
        // fallback to base name
        return baseName;
    }

    private static boolean containsYamlArg(SpecCase c) {
        if (c == null || c.args == null) return false;
        for (String a : c.args) {
            if ("-yaml".equals(a)) return true;
            // Also treat translation flags that involve YAML as YAML mode for skipping
            if ("-t=json2yaml".equalsIgnoreCase(a)) return true;
            if ("-t=yaml2json".equalsIgnoreCase(a)) return true;
        }
        return false;
    }

    private static boolean yamlEnabled() {
        // Enable via JVM property or environment variable
        // -Djdsql.enable.yaml=true OR JDSQL_ENABLE_YAML=1/true/yes
        if (Boolean.getBoolean("jdsql.enable.yaml")) return true;
        String env = System.getenv("JDSQL_ENABLE_YAML");
        if (env == null) return false;
        String v = env.trim().toLowerCase();
        return v.equals("1") || v.equals("true") || v.equals("yes");
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
        // Retained helper for specific error-path checks; uses jd_diff_text
        String sql = "select jd_diff_text(?::jsonb, ?::jsonb, ?::jsonb)";
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

    // Result wrapper for diff outputs
    private static class DiffResult {
        final boolean isJson; // true when underlying result is a structured JSON value (object/array/number/bool/null) or JSON string
        final String text;    // jd text when applicable (already unquoted if JSON string)
        final String jsonCompact; // compact JSON when applicable

        DiffResult(boolean isJson, String text, String jsonCompact) {
            this.isJson = isJson;
            this.text = text == null ? "" : text;
            this.jsonCompact = jsonCompact == null ? "" : jsonCompact;
        }

        String asComparableString() {
            if (isJson) {
                // Prefer text if present (JSON string case), else compact JSON
                if (text != null && !text.isEmpty()) return text;
                return jsonCompact;
            }
            return text;
        }
    }

    private static DiffResult callDiff(Connection conn, String a, String b, String optionsJson, SpecCase c) throws SQLException {
        boolean useText = false;
        if (c != null && c.category != null && c.category.equalsIgnoreCase("jd-sql-custom")) {
            if (c.sql_function != null && c.sql_function.equalsIgnoreCase("jd_diff_text")) {
                useText = true;
            }
        }

        String func = useText ? "jd_diff_text" : "jd_diff";
        // Ensure function exists
        if (useText) {
            assertTrue(functionExists(conn, "jd_diff_text", 3), "jd_diff_text must exist when requested by jd-sql-custom case");
        }

        String sql = "select " + func + "(?::jsonb, ?::jsonb, ?::jsonb)";
        try (PreparedStatement ps = conn.prepareStatement(sql)) {
            if (a == null) ps.setNull(1, java.sql.Types.VARCHAR); else ps.setString(1, a);
            if (b == null) ps.setNull(2, java.sql.Types.VARCHAR); else ps.setString(2, b);
            if (optionsJson == null) ps.setNull(3, java.sql.Types.VARCHAR); else ps.setString(3, optionsJson);
            try (ResultSet rs = ps.executeQuery()) {
                rs.next();
                String col = rs.getString(1);
                if (col == null) {
                    return new DiffResult(false, "", null);
                }
                // Try to parse as JSON first
                try {
                    com.fasterxml.jackson.databind.JsonNode n = JSON.readTree(col);
                    if (n == null || n.isNull()) {
                        return new DiffResult(true, "", "null");
                    }
                    if (n.isTextual()) {
                        // JSON string → jd text
                        return new DiffResult(true, n.asText(), null);
                    }
                    // structured JSON → compact
                    String compact = JSON.writeValueAsString(n);
                    return new DiffResult(true, "", compact);
                } catch (IOException ignore) {
                    // Not JSON → treat as plain text
                    return new DiffResult(false, col, null);
                }
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
        // Map CLI-style flags to an options array understood by SQL implementation
        java.util.List<String> opts = new java.util.ArrayList<>();
        java.util.List<String> dirElems = new java.util.ArrayList<>();
        for (String arg : c.args) {
            if (arg == null) continue;
            if ("-set".equals(arg)) {
                dirElems.add("\"SET\"");
            } else if ("-mset".equals(arg)) {
                dirElems.add("\"MULTISET\"");
            } else if (arg.startsWith("-precision=")) {
                String v = arg.substring("-precision=".length()).trim();
                if (!v.isEmpty()) {
                    // store object {"precision":<num>}
                    dirElems.add("{\"precision\":" + v + "}");
                }
            } else if (arg.startsWith("-setkeys=")) {
                String v = arg.substring("-setkeys=".length()).trim();
                if (!v.isEmpty()) {
                    String[] keys = v.split(",");
                    String arr = java.util.Arrays.stream(keys)
                            .map(String::trim)
                            .filter(s -> !s.isEmpty())
                            .map(s -> "\"" + s.replace("\"", "\\\"") + "\"")
                            .collect(java.util.stream.Collectors.joining(","));
                    dirElems.add("{\"setkeys\":[" + arr + "]}");
                }
            } else if ("-color".equals(arg)) {
                dirElems.add("\"COLOR\"");
            } else if ("-yaml".equals(arg)) {
                // YAML mode unsupported in SQL runner; no-op mapping
            }
        }
        if (!dirElems.isEmpty()) {
            return "[" + String.join(",", dirElems) + "]";
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
