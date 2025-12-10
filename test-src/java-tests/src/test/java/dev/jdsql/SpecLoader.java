package dev.jdsql;

import com.fasterxml.jackson.core.JsonFactory;
import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.core.JsonToken;
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
        return loadCasesFromDir(casesDir);
    }

    public static List<SpecCase> loadProjectCases() throws IOException {
        // Canonical location for jd-sql project-specific cases
        Path casesDir = projectRoot().resolve("test-src/testdata/cases");
        if (!Files.isDirectory(casesDir)) return List.of();
        return loadCasesFromDir(casesDir);
    }

    private static List<SpecCase> loadCasesFromDir(Path dir) throws IOException {
        List<Path> files;
        try (Stream<Path> s = Files.list(dir)) {
            files = s.filter(p -> p.getFileName().toString().endsWith(".json"))
                    .sorted()
                    .toList();
        }
        List<SpecCase> out = new ArrayList<>();
        JsonFactory factory = new JsonFactory();
        for (Path f : files) {
            try (JsonParser parser = factory.createParser(f.toFile())) {
                if (parser.nextToken() != JsonToken.START_ARRAY) {
                    // Fallback: parse whole file if not an array
                    List<SpecCase> batch = MAPPER.readValue(f.toFile(), new TypeReference<>() {});
                    for (SpecCase sc : batch) {
                        sc._sourceFile = f;
                        sc._sourceLine = 1;
                        out.add(sc);
                    }
                    continue;
                }
                while (parser.nextToken() == JsonToken.START_OBJECT) {
                    int line = parser.getCurrentLocation().getLineNr();
                    SpecCase sc = MAPPER.readValue(parser, SpecCase.class);
                    sc._sourceFile = f;
                    sc._sourceLine = line;
                    out.add(sc);
                }
            }
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
