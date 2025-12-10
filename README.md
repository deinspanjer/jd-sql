# SQL JSON diff and patch

`jd-sql` is a set of SQL-centric implementations of the JSON diff and patch spec provided by [jd](https://github.com/josephburnett/jd)

It supports a native `jd` format (similar to unified format) as well as JSON Merge Patch ([RFC 7386](https://datatracker.ietf.org/doc/html/rfc7386)) and a subset of JSON Patch ([RFC 6902](https://datatracker.ietf.org/doc/html/rfc6902)).

The currently provided implementations are:
- postgres-vanilla: PostgreSQL-native functions implemented in `PL/pgSQL` supporting PostgreSQL v15 and above (possibly lower but not tested)
- postgres-plv8: PostgreSQL functions implemented in `plv8` version 3.2.4 (tested with PostgreSQL v15,16,17)

Planned implementations in preference order:
- DuckDB
- Databricks

Unplanned implementations that should be possible if there is demand or collaboration:
- SQLServer
- MySQL
- SQLite

Implementations for commercial databases will only be considered if assets can be safely contributed and maintained.

## Examples

See the README and examples in the [josephburnett/jd](https://github.com/josephburnett/jd) repo for general examples.
See the [examples/jsonb_diff_merge.sql](examples/postgres/jsonb_diff_merge.sql) file for examples of how to use the `jd-sql` functions.

Quick example:

```
-- Textual jd format (human-readable) as TEXT
SELECT jd_diff_text('{"a":1}'::jsonb, '{"a":2}'::jsonb, NULL);
-- => @ ["a"]
--    - 1
--    + 2

-- JSON-returning entrypoint
-- Note: In text mode, the JSONB result is a JSON string containing the jd text shown above.
SELECT jd_diff('{"a":1}'::jsonb, '{"a":2}'::jsonb, NULL);
-- => "@ [\"a\"]\n- 1\n+ 2\n"

-- Patching helpers (work in progress; examples subject to change as spec coverage expands)
SELECT jd_patch('{"a":1}'::jsonb, '[{"op":"replace","path":["a"],"value":2}]', NULL);
-- => {"a":2}
```

Notes on return types:
- jd_diff(a jsonb, b jsonb, options jsonb) now returns JSONB. When the selected output format is textual jd, the returned JSONB value is a JSON string containing the multi-line jd diff text. This allows callers that prefer JSON-only pipelines to treat the result uniformly as JSONB.
- jd_diff_text(a jsonb, b jsonb, options jsonb) is provided for convenience when a TEXT result is desired directly.

## Features

1. Human-friendly format, similar to Unified Diff.
2. Produces a minimal diff between array elements using LCS algorithm.
3. Adds context before and after when modifying an array to prevent bad patches.
4. Create and apply structural patches in jd, patch (RFC 6902) and merge (RFC 7386) patch formats.
5. Translates between patch formats.

### MERGE option vs JSON Merge Patch format (RFC 7386)

Upstream jd distinguishes between:

- MERGE (an option that changes diff/patch semantics):
  - Objects: merge recursively
  - Arrays: replace entirely (no element‑wise merge)
  - null means delete a property when applied
  - In jd’s structural text format, MERGE appears either as `^ "MERGE"` or legacy `^ {"Merge":true}`.

- JSON Merge Patch (RFC 7386) format: a serialization for merge‑style patches (a single JSON object where keys map to changes, `null` deletes, nested objects recurse, arrays replace).

In jd-sql, keep these separate but interoperable:

- Computing diffs:
  - `select jd_diff(a, b, options, 'jd')` → jd text as a JSON string
  - `select jd_diff(a, b, options, 'merge')` or `select jd_diff_merge(a, b, options)` → RFC 7386 object
  - `select jd_diff(a, b, options, 'patch')` or `select jd_diff_patch(a, b, options)` → RFC 6902 array

- Translating formats:
  - `select jd_translate_diff_format(diff_jsonb, 'merge', 'jd')` will include the MERGE header in the jd text output (as upstream specifies).
  - `select jd_translate_diff_format(diff_jsonb, 'jd', 'merge')` produces RFC 7386 when the jd text contains the MERGE header.

Notes:

- Asking for merge output (format `'merge'`) implies merge semantics for the diff result. This mirrors the upstream CLI’s `-f merge` behavior.
- jd-sql renders RFC 7386 only when the diff elements are merge‑compatible; translation from non‑merge diffs to RFC 7386 is constrained to leaf property updates/deletes.

## Installation

TODO: add installation instructions for each implementation

## Development and testing

We provide a Docker-based development environment for each supported implementation.
Check the doc folder for your implementation for details.

### Project layout and IntelliJ/Gradle mapping

Key parts of this repository and how IntelliJ (via Gradle import) categorizes them:

- sql/* — installable SQL scripts that are the primary outputs of this project.
- README.md, doc/*, examples/* — documentation and examples.
- external/jd — upstream jd project used as a reference and for spec tests.
- external/jd/spec/test — upstream spec runner “black box” tests; imported into the IDE as Test Resources for the Java tests via Gradle sourceSets.
- test-src/jd-sql-spec-runner and test-src/testdata/jd-sql-spec-runner — Go wrapper and config so the upstream spec runner can exercise jd-sql.
- test-src/java-tests — JUnit-based integration tests for jd-sql; Gradle subproject.

IntelliJ notes:

- IntelliJ derives source/resource roots from Gradle. Do not mark folders manually in Project Structure — Gradle refresh will overwrite.
- The Gradle subproject under test-src/java-tests declares extra Test Resources so the IDE shows them correctly:
  - external/jd/spec/test (upstream spec cases)
  - test-src/testdata (local test data and configs)

### Java integration tests (JUnit + Testcontainers)

Java-based integration tests for jd-sql now live under `test-src/java-tests` as a Gradle subproject.

- Location: `test-src/java-tests`
- Test sources: `test-src/java-tests/src/test/java`
- Test resources (project-specific): `test-src/java-tests/src/test/resources`
- Additional Test Resources (configured via Gradle):
  - `external/jd/spec/test`
  - `test-src/testdata`
- Run tests: `task test` (or `./gradlew :test-src:java-tests:test`)
- Watch SQL and re-run tests on change: `task --watch dev:watch-sql` (includes Java tests via `java:watch-sql`)

Notes:
- The tests use Testcontainers to start a disposable database engine per install script and then execute the spec cases against the installed functions. Today the runner starts PostgreSQL for scripts under `sql/postgres/**`. The structure is intentionally engine‑agnostic to support additional engines in the future (duckdb, sqlite, databricks, etc.).
- The test harness runs upstream jd spec cases and any project-specific cases. You can add project-specific cases under either `test-src/java-tests/src/test/resources/jd-sql/cases` or the shared `test-src/testdata/cases`.

YAML-mode handling:
- Upstream extended specs include a case named `yaml_mode` which uses the `-yaml` CLI flag and supplies YAML inputs. The jd-sql SQL runner accepts only JSON/JSONB, and we do not plan to support YAML input/output at this time. As a result, the Java test harness will skip any spec case that includes the `-yaml` flag by default.
- You can opt-in to attempt running YAML cases by setting one of these switches (skipping will be disabled):
  - JVM system property: `-Djdsql.enable.yaml=true`
  - Environment variable: `JDSQL_ENABLE_YAML=1` (or `true` / `yes`)
  Note: enabling this will likely cause failures until YAML-to-JSON preprocessing or native YAML support is introduced.

Important: The Go-based jd spec runner wrapper in `test-src/jd-sql-spec-runner` that integrates with the upstream blackbox tests does not implement this skip. It will still report a failure for the YAML case at present. TODO has been added in that code to track this.

Filtering by categories:
- You can run only specific categories of spec cases by setting a comma-separated list with either:
  - JVM system property: `-Djdsql.spec.categories=jd-core,jd-format`
  - Environment variable: `JDSQL_SPEC_CATEGORIES=jd-core,jd-format`
- If no categories are provided, all cases are executed by default.
- Available categories mapped for upstream specs:
  - `jd-core` (upstream `core`)
  - `jd-options` (upstream `options`)
  - `jd-path_options` (upstream `path_options`)
  - `jd-format` (upstream `format`, `translation`, and `patching`)
  - `jd-errors` (upstream `errors`)
  - `jd-edge_cases` (upstream `edge_cases`)
- Project-specific categories (jd-sql):
  - `jd-sql-custom`

Examples:
```
./gradlew :test-src:java-tests:test -Djdsql.spec.categories=jd-core
JDSQL_SPEC_CATEGORIES=jd-core,jd-format ./gradlew :test-src:java-tests:test
```

Test tree grouping:
- Tests are organized into a nested container hierarchy to make browsing easier in the IDE and reports:
  - Engine (e.g., `PostgreSQL`)
    - Version (only shown when a version segment exists in the path; otherwise elided using `default`)
      - Variant (e.g., `plpgsql`, `plv8` as inferred from SQL filename)
        - `bootstrap` (file existence + container start + SQL install)
        - `cases:<category>` (e.g., `cases:jd-core`, `cases:jd-format`), containing the individual spec cases
        - `teardown` (container stop)

Runner class:
- The engine‑agnostic test runner class is `dev.jdsql.EngineSpecIT` (previously `PgSpecIT`). It discovers install scripts under `sql/**` and currently executes those under `sql/postgres/**` using a PostgreSQL Testcontainer. As additional engines are implemented, corresponding scripts (e.g., `sql/duckdb/**`) will appear as separate top-level engine groups in the test tree.

### Upstream jd submodule and spec tests

This repository includes the upstream josephburnett/jd project as a Git submodule under external/jd. We use it primarily to view upstream code and run/port spec tests.

- Location: external/jd (spec cases in external/jd/spec/test). IntelliJ imports `external/jd/spec/test` as Test Resources for the Java tests.
- First-time setup: task jd-submodule-init
- Update to latest upstream on the current submodule branch: task jd-submodule-update
- Checkout a specific tag/branch/commit: task jd-spec-pull -- REF=v2.2.0
- Run upstream jd spec tests against jd-sql: task jd-spec-test

#### jd-sql Go test harness

We provide a small Go wrapper that lets the upstream spec runner call into a configured jd-sql SQL implementation.
The build task automatically fetches its Go modules (runs `go mod tidy` and `go mod download`) so you don't need to manage dependencies manually.

- Source: test-src/jd-sql-spec-runner
- Config file: test-src/testdata/jd-sql-spec-runner/jd-sql-spec.yaml (create by copying the provided example)

Config example (YAML):

```
engine: postgres
dsn: postgres://postgres:postgres@localhost:5432/postgres
sql: |
  SELECT jd_diff($1::jsonb, $2::jsonb, NULL::jsonb)
```

How it works:
- The upstream Go test harness creates two temporary files containing the A and B JSON documents.
- It invokes the Go wrapper (the "binary under test"), passing through arguments and the two file paths.
- The wrapper reads the YAML config, connects to the configured database, executes the configured SQL with the two JSON inputs bound as parameters, and prints the result to stdout.
- The Go harness compares stdout with the expected diff for each case.

To run the test suite against jd-sql (PostgreSQL):

1) Build and run a dev Postgres with jd-sql installed

```
task docker-pg-build
task docker-pg-run
# Once running, in another terminal install the SQL functions:
psql -h localhost -U postgres -f sql/postgres/jd_pg_plpgsql.sql
```

2) Create the runner config

```
cp test-src/testdata/jd-sql-spec-runner/jd-sql-spec.example.yaml test-src/testdata/jd-sql-spec-runner/jd-sql-spec.yaml
# Adjust DSN if needed
```

3) Execute the upstream spec tests via the wrapper

```
task jd-spec-test
```

Notes:
- The wrapper currently supports Postgres only.

### Task-based workflow

- Install Task: https://taskfile.dev/installation/
- List tasks: `task -l`
- Common tasks:
  - Build vanilla Postgres image: `task docker-pg-build`
  - Run Postgres dev container: `task docker-pg-run`
  - Install SQL functions: `task pg-install`
  - Smoke tests: `task pg-smoke`
  - Build spec runner: `task jd-spec-build-runner`
  - Run jd spec tests: `task jd-spec-test`

File watcher for SQL (Postgres):

- Start the watcher: `task --watch dev:watch-sql`
- It will:
  - Detect which engine the changed file targets (plpgsql vs plv8 by filename)
  - Ensure the appropriate Postgres container is running
  - Apply the changed SQL file via psql
  - Build the Go jd-sql-spec-runner and the upstream Go test-runner for your host
  - Run the jd spec test suite with the correct config
- The provided SQL example returns JSONB (from jd_diff); the wrapper will print compact JSON if the first column is JSON/JSONB, or print text verbatim if it’s TEXT. Mapping to the exact jd structural diff text format will come as jd-sql evolves.
 - Config discovery: You can omit -c/--config. The runner will look for jd-sql-spec.yaml in (1) the current working directory, then (2) the same directory as the runner executable. Use -c to override explicitly.
 - Exit codes: The spec runner expects exit code 1 when a diff is produced and 0 when no diff is produced. The jd-sql runner follows this: it exits 1 if the SQL result indicates a non-empty diff (non-empty TEXT or non-empty JSON/JSONB), exits 0 if the result is empty (empty string, null, [] or {}). Any runner error (invalid inputs, DB/connect/SQL failures, unsupported result type) exits with code 2.


## Testing

- We include a JUnit test suite that exercises the SQL functions using the data from the upstream jd spec test suite.
- To run the tests, run `task test` in the root directory.
- The upstream jd spec test can also be used to drive the SQL functions via a Go test harness. See the section above for details.

# Usage documentation copied from `jd` project
The following documentation is almost identical to the original jd project.
Only examples and references to the library or CLI have been changed to reflect the SQL implementation.

## Option Details

These options are identical to the options provided by the main `jd` project.
They are copied here for convenience.

`setkeys` This option determines what keys are used to decide if two
objects 'match'. Then the matched objects are compared, which will
return a diff if there are differences in the objects themselves,
their keys and/or values. You shouldn't expect this option to mask or
ignore non-specified keys, it is not intended as a way to 'ignore'
some differences between objects.

### PathOptions: Targeted Comparison Options

PathOptions allow you to apply different comparison semantics to specific paths in your JSON/YAML data. This enables precise control over how different parts of your data are compared.

**PathOption Syntax:**
```jsonc
{"@": ["path", "to", "target"], "^": [options]}
```

- `@` (At): JSON path array specifying where to apply the option
- `^` (Then): Array of options to apply at that path

**Supported Options:**
- `"SET"`: Treat array as a set (ignore order and duplicates)
- `"MULTISET"`: Treat array as a multiset (ignore order, count duplicates)  
- `{"precision": N}`: Numbers within N are considered equal
- `{"setkeys": ["key1", "key2"]}`: Match objects by specified keys
- `"DIFF_ON"`: Enable diffing at this path (default behavior)
- `"DIFF_OFF"`: Disable diffing at this path, ignore all changes

Note on options parameter:
- All jd-sql functions accept an `options JSONB` parameter to control comparison behavior using jd V2-style options. Pass `NULL` for default behavior when you do not need options.

**Examples:**

Treat specific array as a set while others remain as lists:
```sql
select jd_diff(left, right, '[{"@":["tags"],"^":["SET"]}]'::jsonb)
```

Apply precision to specific temperature field:
```sql
select jd_diff(left, right, '[{"@":["sensor","temperature"],"^":[{"precision":0.1}]}]'::jsonb)
```

Multiple PathOptions - SET on one path, precision on another:
```sql
select jd_diff(left, right, '[{"@":["items"],"^":["SET"]}, {"@":["price"],"^":[{"precision":0.01}]}]'::jsonb)
```

Target specific array index:
```sql
select jd_diff(left, right, '[{"@":["measurements", 0],"^":[{"precision":0.05}]}]'::jsonb)
```

Apply to root level:
```sql
select jd_diff(left, right, '[{"@":[],"^":["SET"]}]'::jsonb)
```

Ignore specific fields (deny-list approach):
```sql
select jd_diff(left, right, '[{"@":["timestamp"],"^":["DIFF_OFF"]}, {"@":["metadata","generated"],"^":["DIFF_OFF"]}]'::jsonb)
```

Allow-list approach - ignore everything except specific fields:
```sql
select jd_diff(left, right, '[{"@":[],"^":["DIFF_OFF"]}, {"@":["userdata"],"^":["DIFF_ON"]}]'::jsonb)
```

Nested override - ignore parent but include specific child:
```sql
select jd_diff(left, right, '[{"@":["config"],"^":["DIFF_OFF"]}, {"@":["config","user_settings"],"^":["DIFF_ON"]}]'::jsonb)
```


## Diff Language (v2)

The jd v2 diff format is a human-readable structural diff format with context and metadata support.

### Format Overview

A diff consists of:
- **Options header** (optional): Shows the options used to create the diff
- **Metadata lines** (optional): Start with `^` and specify hunk-level metadata  
- **Diff hunks**: Start with `@` and specify the path, followed by changes and context

### Options Header

When options are provided to `jd`, they are displayed at the beginning of the diff to show how it was produced. Each option appears on its own line starting with `^ `:

```diff
^ "SET"
^ {"precision":0.001}
@ ["items",{}]
- "old-item"
+ "new-item"
```

This feature helps understand:
- Whether arrays were treated as sets (`"SET"`) or multisets (`"MULTISET"`) 
- What precision was used for number comparisons (`{"precision":N}`)
- Which keys identify set objects (`{"setkeys":["key1","key2"]}`)
- Path-specific options (`{"@":["path"],"^":["OPTION"]}`)
- Whether merge semantics were applied (`"MERGE"`)
- If color output was requested (`"COLOR"`)

The options header is informational and helps with debugging diff behavior. Note that diffs with options headers can still be parsed and applied as patches.

### EBNF Grammar

```EBNF
Diff ::= OptionsHeader* (MetadataLine | DiffHunk)*

OptionsHeader ::= '^' SP JsonValue NEWLINE

MetadataLine ::= '^' SP JsonObject NEWLINE

DiffHunk ::= '@' SP JsonArray NEWLINE
             ContextLine*
             (RemoveLine | AddLine)*
             ContextLine*

ContextLine ::= SP SP JsonValue NEWLINE

RemoveLine ::= '-' SP JsonValue NEWLINE

AddLine ::= '+' SP JsonValue NEWLINE

JsonArray ::= '[' (PathElement (',' PathElement)*)? ']'

PathElement ::= JsonString        // Object key: "foo"
              | JsonNumber        // Array index: 0 
              | EmptyObject       // Set marker: {}
              | EmptyArray        // List marker: [] 
              | ObjectWithKeys    // Set keys: {"id":"value"}
              | ArrayWithObject   // Multiset: [{}] or [{"id":"value"}]
```

### Path Elements Reference

| Element | Description | Example Path |
|---------|-------------|--------------|
| `"key"` | Object field access | `["user","name"]` |
| `0`, `1`, etc. | Array index access | `["items",0]` |
| `{}` | Treat array as set (ignore order/duplicates) | `["tags",{}]` |
| `[]` | Explicit list marker | `["values",[]]` |
| `{"id":"val"}` | Match objects by specific key | `["users",{"id":"123"}]` |
| `[{}]` | Treat as multiset (ignore order, count duplicates) | `["counts",[{}]]` |
| `[{"key":"val"}]` | Match multiset objects by key | `["items",[{"id":"456"}]]` |

### Line Types

- **`@ [path]`**: Diff hunk header specifying the location
- **`^ {metadata}`**: Metadata for the following hunks (inherits downward)  
- **`  value`**: Context lines (spaces) - elements that provide context
- **`- value`**: Remove lines - values being removed
- **`+ value`**: Add lines - values being added

### Core Examples

#### Simple Object Change
```diff
@ ["name"]
- "Alice"
+ "Bob"
```

#### Array Element with Context
```diff
@ ["items",1]
  "apple"
+ "banana" 
  "cherry"
```

#### Set Operations (Ignore Order)
```diff
@ ["tags",{}]
- "urgent"
+ "completed"
+ "reviewed"
```

#### Object Identification by Key
```diff
@ ["users",{"id":"123"},"status"]
- "pending"
+ "active"
```

#### Multiset Operations
```diff
@ ["scores",[{}]]
- 85
- 92
+ 88
+ 95
+ 95
```

### Advanced Examples

#### Merge Patch Metadata
```diff
^ {"Merge":true}
@ ["config"]
- {"timeout":30,"retries":3}
+ {"timeout":60,"retries":5,"debug":true}
```

#### Complex List Context
```diff
@ ["matrix",1,2]
  [[1,2,3],[4,5,6]]
- 6
+ 9
  [7,8,9]
]
```

#### Nested Set with PathOptions
```diff
@ ["department","employees",{"employeeId":"E123"},"projects",{}]
- "ProjectA"
+ "ProjectB" 
+ "ProjectC"
```

#### Multiple Hunks with Inheritance
```diff
^ {"Merge":true}
@ ["user","preferences"] 
+ {"theme":"dark","notifications":true}
@ ["user","lastLogin"]
+ "2023-12-01T10:30:00Z"
```

### Integration with PathOptions

The path syntax directly corresponds to PathOption targeting:
- Diff path `["users",{}]` ↔ PathOption `{"@":["users"],"^":["SET"]}`
- Diff path `["items",{"id":"123"}]` ↔ PathOption with SetKeys targeting
- Diff path `["scores",[{}]]` ↔ PathOption `{"@":["scores"],"^":["MULTISET"]}`

This allows fine-grained control over how different parts of your data structures are compared and diffed.

## Attribution

This project ports the ideas and specification from the upstream jd project but is an original implementation in SQL.

- Upstream project: josephburnett/jd — https://github.com/josephburnett/jd
- License: MIT — see external/jd/LICENSE in this repository or the upstream link above.
- Portions of documentation in this repository (including some content in `doc/` and excerpts near the end of this README) are adapted from the upstream jd project and remain © Joseph Burnett under the MIT License.
