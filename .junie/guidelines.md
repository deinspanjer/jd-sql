# Project Overview

This project is a port of the Golang project josephburnett-jd into functions that can be used within PostgreSQL.
provides both a commandline, library and website for diffing and patching JSON and YAML values.
It is focused on a human-readable diff format but has the ability to read and produce other diff formats.
Features of the source project that are not included in this port:
- Support for YAML
- CLI
- Web UI

## Key Commands

- Test: `make test`
- Fuzz: `make fuzz`

## Code Standards

- When adding new functionality, new tests SHOULD be added and documentation MUST be updated
- Until this instruction is removed, backwards compatibility to previous versions of jd-pg features is not required.
- This project is specific to PostgreSQL with a tested minimum version of PostgreSQL 15. Ensure syntax is PostgreSQL compatible.
- MUST pass unit and fuzz tests (implemented using JerrySievert/equinox)
- Add tests to existing table tests when possible
- Main function MUST remain backward compatible with previous jd-pg releases (maintain API backward compatability) *
- jd-pg SHOULD maintain compatibility with the original jd project (maintain API backward compatability)
- Helper functions that are not intended to be used outside of jd-pg SHOULD be prefixed with `_jd_`

  * Unless otherwise instructed

## File Structure

- `README.md` - Information about installation, usage and diff format
- `Makefile` - Project commands
- `/doc` - Plans and documents
- `/docker` - Dockerfiles for testing
- `/examples` - Various examples of usage
- `/sql` - SQL files for installing the function to a PostgreSQL database

### Reference code for porting
- `/v2` - V2 library
- `/v2/jd/main.go` - V2 commandline
- `/doc` - Plans and documents
- `/lib` - Deprecated v1 library (read-only)
- `main.go` - Deprecated v1 commandline (read-only)

## Advice

- Try and avoid creating temporary files and instead rely on modifying existing unit tests for debugging.
  This will prevent you from getting stuck on asking for my approval. Try and use tools you don't need
  to ask approval for so you can unblock yourself.
- Don't use words like "comprehensive" or "robust" because they don't add anything to the specificity of
  a sentence. Each layer of testing adds a layer of probability to catch a bug, but few things are truely
  comprehensive. And robustness again is very relative and requires context, such as SLAs.
- Documentation is in `README.md` and `v2/jd/main.go` (see usage).
