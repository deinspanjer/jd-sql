# Project Overview

`jd` is a tool for comparing and diffing JSON documents.
This project is a port of the Golang project josephburnett-jd spec into SQL functionality for various database engines.
It is focused on a human-readable diff format but has the ability to read and produce other diff formats.

## Junie permissions

You are allowed to:
- make changes to any file in the project
- run any `task` target
- run commands such as `go mod download` that retrieve files from the internet
- run commands that interact with the locally running Docker containers related to the project


## Code Standards

- When adding new functionality, new tests SHOULD be added and documentation MUST be updated
- Until this instruction is removed, backwards compatibility to previous versions of jd-sql features is not required.
- When possible, use a test driven approach to development.
  - Capture the requirements in a test case
  - Write the code to satisfy the requirements
  - Run the test case to ensure the code works as expected
- MUST pass java-tests (Gradle subproject) before submitting a PR
- Add tests to existing test categories when appropriate
- jd-sql SHOULD maintain compatibility with the original jd project (maintain API backward compatability)
- Helper functions that are not intended to be used outside of jd-pg SHOULD be prefixed with `_jd_`
- SQL scripts (files under `sql/**`) MUST be formatted using the pattern defined in `.editorconfig`
  - lower case keywords
  - 4 spaces indentation
  - significant clauses of a statement on a new line
  - indented subqueries and compound clauses
  - one-liner statements MUST NOT exceed 80 characters and should only be used when the statement is short and simple

- Installable SQL scripts (files under `sql/**`) must declare the project license in a leading SQL comment header. Use MIT and reference the root `LICENSE` file, for example:

  ```sql
  -- License: MIT
  -- This file is licensed under the MIT License. See the LICENSE file at
  -- github.com/deinspanjer/jd-sql/LICENSE for full license text.
  --
  -- Copyright (c) 2025 Daniel Einspanjer
  ```

## File Structure

- `README.md` - Information about installation, usage and diff format
- `Taskfile.yml` - Project tasks using Task (primary build/automation)
- `/taskfiles` - Modular sub-taskfiles (Postgres images/containers, jd subproject, spec runner, engine stubs)
- `/doc` - Plans and documents
- `/docker` - Dockerfiles for testing
- `/examples` - Various examples of usage
- `/sql` - Installable SQL script sources that are the primary outputs of this project (e.g., sql/postgres/*)
- `/external/jd` - Upstream jd project (reference code and spec)
- `/external/jd/spec/test` - Upstream spec runner tests (treated as Test Resources in the IDE via Gradle)
- `/test-src/jd-sql-spec-runner` - Go wrapper used by upstream spec runner to call jd-sql
- `/test-src/testdata/jd-sql-spec-runner` - Configs and test data for the Go wrapper
- `/test-src/java-tests` - JUnit integration tests (Gradle subproject)
  - `src/test/java` - Java test sources
  - `src/test/resources` - Project-specific test resources
  - Additional Test Resources (declared via Gradle `sourceSets`):
    - `external/jd/spec/test`
    - `test-src/testdata`
- `/out` - Build outputs (Gradle is configured to place outputs under out/gradle/**)

### Reference code for porting
- `/external/jd/CLAUDE.md` - Guidelines provided by the original jd project for LLM assistance
- `/external/jd/v2` - V2 library
- `/external/jd/v2/jd/main.go` - V2 commandline
- `/external/jd/doc` - Plans and documents
- `/external/jd/lib` - Deprecated v1 library (read-only)
- `external/jd/main.go` - Deprecated v1 commandline (read-only)

## Advice

- Try and avoid creating temporary files and instead rely on modifying existing unit tests for debugging.
  This will prevent you from getting stuck on asking for my approval. Try and use tools you don't need
  to ask approval for so you can unblock yourself.
- Don't use words like "comprehensive" or "robust" because they don't add anything to the specificity of
  a sentence. Each layer of testing adds a layer of probability to catch a bug, but few things are truly
  comprehensive. And robustness again is very relative and requires context, such as SLAs.

## IntelliJ and Gradle

- IntelliJ derives source and resource roots from Gradle. Avoid manually marking directories in Project Structure; Gradle refresh will overwrite.
- The `test-src/java-tests` subproject configures extra Test Resources via `sourceSets` so that:
  - `external/jd/spec/test` and `test-src/testdata` appear as Test Resources in the IDE and are on the test runtime classpath.

## Running selected test categories

The java-test suite can filter tests by category using the environment variable `JDSQL_SPEC_CATEGORIES` (comma-separated). The available category names are:
- jd-sql-unit: simple unit tests for fast verification of correctness
- jd-core: upstream jd spec core test cases
- jd-edge_cases: upstream jd spec edge cases
- jd-errors: upstream jd spec error cases
- jd-options: upstream jd spec options test cases
- jd-path_options: upstream jd spec path options test cases
- jd-format: upstream jd spec format test cases
- jd-sql-custom: custom tests to be run for any jd-sql engine implementation

### Running a test case using IntelliJ IDEA JUnitRunner
- class `dev.jdsql.EngineSpecIT`
- classpath: `jd-sql.test-src.java-tests.test`
- ENV `JDSQL_SPEC_CATEGORIES=<categories as csv list>`

The run configuration `.idea/runConfigurations/IntelliJ_java_test__core_.xml` is an example of running a single category.
Tests can be run via gradle task, but the IDE is more convenient for developer review.

Notes
- If `JDSQL_SPEC_CATEGORIES` is unset or empty, all categories will run.
- Category normalization is handled by the runner (e.g., upstream names like `core` become `jd-core`).
- Use this to iterate quickly: start with `jd-sql-unit`, then `jd-core`, then move through the remaining categories.