package dev.jdsql;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;
import java.util.stream.Stream;

public class SpecLoader {
    private static final ObjectMapper MAPPER = new ObjectMapper();

    public static Path projectRoot() {
        // Try to find the repository root by searching upwards for Taskfile.yml
        Path dir = Paths.get("").toAbsolutePath();
        for (int i = 0; i < 5 && dir != null; i++) {
            if (Files.exists(dir.resolve("Taskfile.yml"))) return dir;
            dir = dir.getParent();
        }
        return Paths.get("").toAbsolutePath();
    }

    public static List<SpecCase> loadUpstreamCases() throws IOException {
        Path casesDir = projectRoot().resolve("external/jd/spec/test/cases");
        if (!Files.isDirectory(casesDir)) {
            throw new IOException("Cases directory not found: " + casesDir);
        }
        List<Path> files;
        try (Stream<Path> s = Files.list(casesDir)) {
            files = s.filter(p -> p.getFileName().toString().endsWith(".json"))
                    .sorted()
                    .toList();
        }
        List<SpecCase> out = new ArrayList<>();
        for (Path f : files) {
            List<SpecCase> batch = MAPPER.readValue(f.toFile(), new TypeReference<>() {
            });
            out.addAll(batch);
        }
        return out;
    }

    public static List<SpecCase> loadProjectCases() throws IOException {
        // Allow project-specific cases under test-src/java-tests resources folder (optional)
        Path customDir = projectRoot().resolve("test-src/java-tests/src/test/resources/jd-sql/cases");
        if (!Files.exists(customDir)) return List.of();
        List<Path> files;
        try (Stream<Path> s = Files.list(customDir)) {
            files = s.filter(p -> p.getFileName().toString().endsWith(".json"))
                    .sorted()
                    .toList();
        }
        List<SpecCase> out = new ArrayList<>();
        for (Path f : files) {
            List<SpecCase> batch = MAPPER.readValue(f.toFile(), new TypeReference<>() {
            });
            out.addAll(batch);
        }
        return out;
    }

    public static List<Path> findSqlInstallScripts() throws IOException {
        Path sqlDir = projectRoot().resolve("sql");
        if (!Files.isDirectory(sqlDir)) return List.of();
        List<Path> out = new ArrayList<>();
        try (Stream<Path> s = Files.walk(sqlDir)) {
            s.filter(p -> p.getFileName().toString().endsWith(".sql"))
             .forEach(out::add);
        }
        return out;
    }

    public static String normalizeContentForJsonb(String content) {
        // Upstream uses empty string as void; represent as SQL NULL (Java null) so jd_diff sees 'void'
        if (content == null || content.isEmpty()) return null;
        return content;
    }
}
