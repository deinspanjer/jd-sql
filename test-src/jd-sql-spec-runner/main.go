package main

import (
	"database/sql"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	_ "github.com/lib/pq"
	"gopkg.in/yaml.v3"
)

type Config struct {
	Engine string `yaml:"engine"`
	DSN    string `yaml:"dsn"`
	SQL    string `yaml:"sql"`
}

func main() {
	code, err := run()
	if err != nil {
		fmt.Fprintln(os.Stderr, err.Error())
		os.Exit(2)
	}
	os.Exit(code)
}

func run() (int, error) {
    cfgPath, fileA, fileB, err := parseArgs()
    if err != nil {
        return 2, err
    }

	cfg, err := loadConfig(cfgPath)
	if err != nil {
		return 2, err
	}

	switch strings.ToLower(cfg.Engine) {
	case "postgres", "pg":
		return runPostgres(cfg, fileA, fileB)
	default:
		return 2, fmt.Errorf("unsupported engine '%s' (supported: postgres)", cfg.Engine)
	}
}

func parseArgs() (cfgPath string, fileA string, fileB string, err error) {
    // Primary parser (compatible with -c/--config); ignore unknown flags by parsing manually.
    var configFlag string
    fs := flag.NewFlagSet("jd-sql-spec-runner", flag.ContinueOnError)
    fs.SetOutput(new(nopWriter)) // silence default usage output on error
    fs.StringVar(&configFlag, "c", "", "config file")
    fs.StringVar(&configFlag, "config", "", "config file")
    _ = fs.Parse(os.Args[1:])

    // Remaining args may include jd flags; the upstream runner may prepend flags and arbitrary args.
    raw := os.Args[1:]
    // Remove config flags from view
    raw = stripConfigArgs(raw)

    // Collect positional (non-flag) args only
    pos := make([]string, 0, len(raw))
    for _, s := range raw {
        if strings.HasPrefix(s, "-") {
            continue
        }
        pos = append(pos, s)
    }

    // Enforce exactly two positional inputs for diff mode
    if len(pos) < 2 {
        // Try permissive parse from environment
        configFlag2, a, b, perr := permissiveParseEnvArgs()
        if perr != nil {
            return "", "", "", errors.New("missing input files (expected two file paths)")
        }
        if configFlag == "" {
            configFlag = configFlag2
        }
        // Validate existence
        if err := ensureFilesExist(a, b); err != nil {
            return "", "", "", err
        }
        return resolveConfigPath(configFlag), a, b, nil
    }
    if len(pos) > 2 {
        return "", "", "", errors.New("too many input files (expected two)")
    }

    a := pos[len(pos)-2]
    b := pos[len(pos)-1]
    if err := ensureFilesExist(a, b); err != nil {
        return "", "", "", err
    }
    return resolveConfigPath(configFlag), a, b, nil
}

func ensureFilesExist(a, b string) error {
    if a != "" {
        if _, err := os.Stat(a); err != nil {
            return fmt.Errorf("input file does not exist: %s", a)
        }
    }
    if b != "" {
        if _, err := os.Stat(b); err != nil {
            return fmt.Errorf("input file does not exist: %s", b)
        }
    }
    return nil
}

func stripConfigArgs(args []string) []string {
	out := make([]string, 0, len(args))
	i := 0
	for i < len(args) {
		a := args[i]
		if a == "-c" || a == "--config" {
			if i+1 < len(args) {
				i += 2
				continue
			}
			i++
			continue
		}
		if strings.HasPrefix(a, "-c=") || strings.HasPrefix(a, "--config=") {
			i++
			continue
		}
		out = append(out, a)
		i++
	}
	return out
}

func permissiveParseEnvArgs() (cfg string, a string, b string, err error) {
	args := os.Args[1:]
	// Remove config flags
	i := 0
	for i < len(args) {
		s := args[i]
		if s == "-c" || s == "--config" {
			if i+1 < len(args) {
				cfg = args[i+1]
				args = append(args[:i], args[i+2:]...)
				continue
			}
			args = append(args[:i], args[i+1:]...)
			continue
		} else if strings.HasPrefix(s, "-c=") {
			cfg = strings.TrimPrefix(s, "-c=")
			args = append(args[:i], args[i+1:]...)
			continue
		} else if strings.HasPrefix(s, "--config=") {
			cfg = strings.TrimPrefix(s, "--config=")
			args = append(args[:i], args[i+1:]...)
			continue
		}
		i++
	}
	if len(args) < 2 {
		return "", "", "", errors.New("not enough args")
	}
	return cfg, args[len(args)-2], args[len(args)-1], nil
}

func loadConfig(path string) (Config, error) {
	var cfg Config
	b, err := os.ReadFile(path)
	if err != nil {
		return cfg, fmt.Errorf("failed to read config file: %s: %w", path, err)
	}
	if err := yaml.Unmarshal(b, &cfg); err != nil {
		return cfg, fmt.Errorf("failed to parse YAML config: %s: %w", path, err)
	}
	return cfg, nil
}

func resolveConfigPath(opt string) string {
	if opt != "" {
		return opt
	}
	// 1) cwd
	if existsFile("jd-sql-spec.yaml") {
		return "jd-sql-spec.yaml"
	}
	// 2) next to executable
	if exe, err := os.Executable(); err == nil {
		if dir := filepath.Dir(exe); dir != "" {
			p := filepath.Join(dir, "jd-sql-spec.yaml")
			if existsFile(p) {
				return p
			}
		}
	}
	return "jd-sql-spec.yaml" // will fail on read with clear message
}

func existsFile(p string) bool {
	st, err := os.Stat(p)
	if err != nil {
		return false
	}
	return !st.IsDir()
}

func runPostgres(cfg Config, fileA, fileB string) (int, error) {
    // TODO(jd-sql): Upstream extended spec includes a `yaml_mode` case using the `-yaml` flag
    // and YAML inputs. This runner intentionally passes inputs directly to the SQL implementation
    // without YAML->JSON preprocessing. As a result, `yaml_mode` will currently fail here.
    // The Java JUnit harness skips YAML-mode cases by default; this Go runner does NOT.
    // If/when YAML support is added (or a preprocessing mode is introduced), consider adding
    // a configurable skip or conversion similar to the Java tests.
    // Read inputs as raw JSON text. We intentionally pass raw JSON strings to Postgres
    // and let the database perform JSONB parsing/validation via ::jsonb casts.
	// This mirrors the behavior of the previous Rust runner and ensures that invalid
	// JSON surfaces as a SQL error (exit 2) instead of being pre-validated here.
	aText, err := os.ReadFile(fileA)
	if err != nil {
		return 2, fmt.Errorf("failed to read input file A: %s: %w", fileA, err)
	}
	bText, err := os.ReadFile(fileB)
	if err != nil {
		return 2, fmt.Errorf("failed to read input file B: %s: %w", fileB, err)
	}

	var aIsNull, bIsNull bool
	if strings.TrimSpace(string(aText)) == "" {
		aIsNull = true
	}
	if strings.TrimSpace(string(bText)) == "" {
		bIsNull = true
	}

	dsn := cfg.DSN
	// Default to disabling SSL unless explicitly configured. This matches local dev
	// expectations and the prior Rust runner, and avoids lib/pq errors when the server
	// does not have SSL enabled.
	if !strings.Contains(strings.ToLower(dsn), "sslmode=") {
		if strings.Contains(dsn, "?") {
			dsn = dsn + "&sslmode=disable"
		} else {
			dsn = dsn + "?sslmode=disable"
		}
	}

	db, err := sql.Open("postgres", dsn)
	if err != nil {
		return 2, fmt.Errorf("failed to connect to postgres: %s: %w", dsn, err)
	}
	defer db.Close()

	// Prepare statement
	stmt, err := db.Prepare(cfg.SQL)
	if err != nil {
		return 2, fmt.Errorf("prepare SQL failed: %w", err)
	}
	defer stmt.Close()

	// Bind parameters: use nil to represent SQL NULL (void), otherwise pass raw JSON text.
	var arg1 any
	if aIsNull {
		arg1 = nil
	} else {
		arg1 = string(aText)
	}
	var arg2 any
	if bIsNull {
		arg2 = nil
	} else {
		arg2 = string(bText)
	}

	row := stmt.QueryRow(arg1, arg2)

 // Try text first
 var textOut sql.NullString
 if err := row.Scan(&textOut); err == nil {
     if textOut.Valid {
         out := textOut.String
         // If the text looks like JSON, attempt to decode.
         var decoded any
         if json.Unmarshal([]byte(out), &decoded) == nil {
             switch v := decoded.(type) {
             case string:
                 // JSON string -> emit unquoted payload
                 fmt.Fprint(os.Stdout, v)
                 if strings.TrimSpace(v) == "" {
                     return 0, nil
                 }
                 return 1, nil
             default:
                 // Valid JSON (object/array/number/bool/null): emit compact JSON
                 enc, _ := json.Marshal(v)
                 fmt.Fprint(os.Stdout, string(enc))
                 if jsonDiffPresent(v) {
                     return 1, nil
                 }
                 return 0, nil
             }
         }
         // Not JSON: treat as plain text jd output
         fmt.Fprint(os.Stdout, out)
         if strings.TrimSpace(out) == "" {
             return 0, nil
         }
         return 1, nil
     }
     return 0, nil
 } else {
     // Re-query to get raw JSON bytes by executing again (since Scan consumed row)
     row2 := db.QueryRow(cfg.SQL, arg1, arg2)
     var jsonBytes []byte
     if err2 := row2.Scan(&jsonBytes); err2 == nil {
         // print compact JSON
			// Ensure bytes are valid JSON
			var v any
			if err := json.Unmarshal(jsonBytes, &v); err != nil {
				// Treat as text
				s := string(jsonBytes)
				fmt.Fprint(os.Stdout, s)
				if strings.TrimSpace(s) == "" {
					return 0, nil
				}
				return 1, nil
			}
			enc, _ := json.Marshal(v)
			fmt.Fprint(os.Stdout, string(enc))
			if jsonDiffPresent(v) {
				return 1, nil
			}
			return 0, nil
		}
		// If both scans fail, return error
		return 2, fmt.Errorf("unsupported result type in first column; expected text or json")
	}
}

func toJSONB(v any) any { return v }

func jsonDiffPresent(v any) bool {
	switch t := v.(type) {
	case nil:
		return false
	case bool:
		return t
	case float64:
		return t != 0
	case string:
		return t != ""
	case []any:
		return len(t) > 0
	case map[string]any:
		return len(t) > 0
	default:
		return true
	}
}

type nopWriter struct{}

func (n *nopWriter) Write(p []byte) (int, error) { return len(p), nil }
