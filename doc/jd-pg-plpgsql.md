jd-pg PL/pgSQL implementation (initial)

Overview

This document describes the initial PL/pgSQL-only implementation of jd-pg functions. The goal is to provide a PostgreSQL-native way to generate and apply diffs between JSONB values without requiring plv8.

Scope for this initial version
- Top-level object diffs: add, remove, replace operations for keys at the document root.
- Whole-value replace for arrays and scalars when values differ.
- Patch application for the operation set produced by jd_diff.
- No array index paths or deep/nested paths yet. These will be added iteratively.

Installation
- Ensure you are connected to your PostgreSQL 15+ database.
- Load the SQL script:
  \i sql/jd_pg_plpgsql.sql

Functions
- jd_diff(a jsonb, b jsonb) → jsonb
  - Returns a JSONB array of operations using a simplified jd-like format:
    - {"op":"add"|"remove"|"replace", "path":[<keys...>], "value":<jsonb?>}
  - path is a JSON array of object keys. Only [] (root) and single-key ["k"] are supported currently.
  - value is required for add/replace and omitted for remove.

- jd_patch(a jsonb, diff jsonb) → jsonb
  - Applies the operations to produce a new JSONB value.
  - Errors if nested paths are used or types are incompatible for the operation.

Examples
- Top-level changes:
  SELECT jd_diff('{"a":1}'::jsonb, '{"a":2,"b":3}'::jsonb);
  → [{"op":"replace","path":["a"],"value":2},{"op":"add","path":["b"],"value":3}]

- Apply patch:
  SELECT jd_patch('{"a":1}'::jsonb, '[{"op":"replace","path":["a"],"value":2},{"op":"add","path":["b"],"value":3}]');
  → {"a":2,"b":3}

Notes on compatibility with jd
- The canonical jd format is text-based and supports deep paths, array contexts, and options. This initial version focuses on a pragmatic subset suited for early jd-pg usage in SQL. The intention is to expand functionality towards jd feature parity over time.

Testing with Equinox
- We plan to validate jd-pg SQL functions using JerrySievert/equinox. The repository will contain SQL-based tests demonstrating expected behavior for jd_diff and jd_patch.
- Until the full test harness is wired into the Makefile flow, you can run the SQL tests manually in a PostgreSQL container/session with psql.

Roadmap
- Deep path support (nested objects, array indices)
- Array LCS-based diffs
- Options (SET, MULTISET, precision, setkeys) with PathOptions
- Translations to/from JSON Patch and JSON Merge Patch
- DIFF_ON/DIFF_OFF support
