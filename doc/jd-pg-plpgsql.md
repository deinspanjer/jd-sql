jd-sql PL/pgSQL implementation (initial)

Overview

This document describes the initial PL/pgSQL-only implementation of jd-sql functions within PostgreSQL. While jd-sql targets SQL implementations beyond just PostgreSQL, this document focuses on the PostgreSQL-native approach to generate and apply diffs between JSONB values without requiring plv8.

Scope for this initial version
- Top-level object diffs: add, remove, replace operations for keys at the document root.
- Whole-value replace for arrays and scalars when values differ.
- Patch application for the operation set produced by jd_diff.
- No array index paths or deep/nested paths yet. These will be added iteratively.

Installation (PostgreSQL)
- Ensure you are connected to your PostgreSQL 15+ database.
- Load the SQL script:
  \i sql/jd_pg_plpgsql.sql

Functions
- jd_diff(a jsonb, b jsonb, options jsonb DEFAULT NULL) → text
  - Produces a jd v2-style textual structural diff for core cases.
  - Honors a JSONB `options` array using jd PathOptions syntax (subset):
    - Global options like `"DIFF_ON"`, `"DIFF_OFF"`, `"SET"`, and `{ "precision": N }`.
    - PathOptions objects: `{ "@": [path...], "^": [ directives... ] }`.

  Supported directives (subset):
  - `"SET"`: Compare arrays as mathematical sets at the targeted path(s) — ignore order; the diff shows header `^ "SET"` and changes using `@ [path,{}]` with `-`/`+` elements.
  - `{ "precision": N }`: Treat two numbers within `N` as equal for diffing.
  - `"DIFF_ON"` / `"DIFF_OFF"`: Enable/disable diffing for targeted paths.

- jd_patch(a jsonb, diff jsonb, options jsonb DEFAULT NULL) → jsonb
  - Applies the simplified jd-like operation array to produce a new JSONB value.
  - The `options` parameter is accepted for signature consistency; it is not used by this simplified patcher.

Examples
- Top-level changes:
  SELECT jd_diff('{"a":1}'::jsonb, '{"a":2,"b":3}'::jsonb, NULL);
  → [{"op":"replace","path":["a"],"value":2},{"op":"add","path":["b"],"value":3}]

- Array as set (ignore order):
  SELECT jd_diff('{"tags":[1,2,3]}'::jsonb, '{"tags":[3,1,2]}'::jsonb, '["SET"]');
  → ''

  SELECT jd_diff('{"tags":["red","blue","green"]}'::jsonb, '{"tags":["red","blue","yellow"]}'::jsonb, '["SET"]');
  → ^ "SET"\n@ ["tags",{}]\n- "green"\n+ "yellow"\n

- Apply patch:
  SELECT jd_patch('{"a":1}'::jsonb, '[{"op":"replace","path":["a"],"value":2},{"op":"add","path":["b"],"value":3}]', NULL);
  → {"a":2,"b":3}

Notes on compatibility with jd
- The canonical jd format is text-based and supports deep paths, array contexts, and options. This initial version focuses on a pragmatic subset suited for early jd-sql usage in SQL. The intention is to expand functionality towards jd feature parity over time. The `options` parameter currently supports a subset: global/PathOptions for `DIFF_ON`/`DIFF_OFF`, `SET` for set-like array comparison, and numeric `precision`.

Testing with Equinox
- We plan to validate jd-sql SQL functions using JerrySievert/equinox. The repository will contain SQL-based tests demonstrating expected behavior for jd_diff and jd_patch.
- Until the full test harness is wired into the Makefile flow, you can run the SQL tests manually in a PostgreSQL container/session with psql.

Roadmap
- Deep path support (nested objects, array indices)
- Array LCS-based diffs
- Options (SET, MULTISET, precision, setkeys) with PathOptions
- Translations to/from JSON Patch and JSON Merge Patch
- DIFF_ON/DIFF_OFF support
