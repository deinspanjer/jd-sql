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
- MUST pass unit and fuzz tests (implemented using JerrySievert/equinox)
- Add tests to existing table tests when possible
- jd-sql SHOULD maintain compatibility with the original jd project (maintain API backward compatability)
- Helper functions that are not intended to be used outside of jd-pg SHOULD be prefixed with `_jd_`

  * Unless otherwise instructed

## File Structure

- `README.md` - Information about installation, usage and diff format
- `Taskfile.yml` - Project tasks using Task (primary build/automation)
- `/taskfiles` - Modular sub-taskfiles (Postgres images/containers, jd subproject, spec runner, engine stubs)
- `/doc` - Plans and documents
- `/docker` - Dockerfiles for testing
- `/examples` - Various examples of usage
- `/sql` - SQL files for installing the function to a PostgreSQL database
- `/test-src` - Go-based jd-sql-spec-runner sources (test harness)
- `/test-src/testdata/jd-sql-spec-runner` - Test resources for the spec runner (configs, example YAML)
- `/out/test/bin` - Built binaries for test runners (output of build tasks)

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
