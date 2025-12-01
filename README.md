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
SELECT jd_diff('{"a":1}'::jsonb, '{"a":2,"b":3}'::jsonb);
-- => [{"op":"replace","path":["a"],"value":2},{"op":"add","path":["b"],"value":3}]

SELECT jd_patch('{"a":1}'::jsonb, '[{"op":"replace","path":["a"],"value":2},{"op":"add","path":["b"],"value":3}]');
-- => {"a":2,"b":3}
```

## Features

1. Human-friendly format, similar to Unified Diff.
2. Produces a minimal diff between array elements using LCS algorithm.
3. Adds context before and after when modifying an array to prevent bad patches.
4. Create and apply structural patches in jd, patch (RFC 6902) and merge (RFC 7386) patch formats.
5. Translates between patch formats.

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
- The tests use Testcontainers to start a disposable PostgreSQL and install the SQL from `sql/postgres/*.sql` before executing spec cases.
- The test harness also runs the upstream jd CORE cases; you can add project-specific cases under `test-src/java-tests/src/test/resources/jd-sql/cases`.

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
  SELECT jd_diff($1::jsonb, $2::jsonb)
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


## Testing with Equinox

- We include initial SQL tests in spec/test/sql for use with JerrySievert/equinox.
- These tests can also be run manually for quick verification.
- To run the tests, run `task test` in the root directory.

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

**Examples:**

Treat specific array as a set while others remain as lists:
```sql
select jd_diff(left, right, opts :='[{"@":["tags"],"^":["SET"]}]')
```

Apply precision to specific temperature field:
```sql
select jd_diff(left, right, opts :='[{"@":["sensor","temperature"],"^":[{"precision":0.1}]}]')
```

Multiple PathOptions - SET on one path, precision on another:
```sql
select jd_diff(left, right, opts :='[{"@":["items"],"^":["SET"]}, {"@":["price"],"^":[{"precision":0.01}]}]')
```

Target specific array index:
```sql
select jd_diff(left, right, opts :='[{"@":["measurements", 0],"^":[{"precision":0.05}]}]')
```

Apply to root level:
```sql
select jd_diff(left, right, opts :='[{"@":[],"^":["SET"]}]')
```

Ignore specific fields (deny-list approach):
```sql
select jd_diff(left, right, opts :='[{"@":["timestamp"],"^":["DIFF_OFF"]}, {"@":["metadata","generated"],"^":["DIFF_OFF"]}]')
```

Allow-list approach - ignore everything except specific fields:
```sql
select jd_diff(left, right, opts :='[{"@":[],"^":["DIFF_OFF"]}, {"@":["userdata"],"^":["DIFF_ON"]}]')
```

Nested override - ignore parent but include specific child:
```sql
select jd_diff(left, right, opts :='[{"@":["config"],"^":["DIFF_OFF"]}, {"@":["config","user_settings"],"^":["DIFF_ON"]}]')
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
