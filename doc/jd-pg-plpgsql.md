jd-sql PL/pgSQL: Upstream jd v2 API and PostgreSQL Type/Function Mapping

Overview

This document defines the PostgreSQL PL/pgSQL surface that mirrors the upstream jd v2 API for JSON diffing and patching. It introduces SQL domains and composite types to express jd concepts (paths, options, diffs) and specifies the public `jd_` functions (JSONB-only) together with private `_jd_` helpers. YAML input/output is not supported for the PL/pgSQL variant.

Upstream jd v2, summarized

- Values: `JsonNode` with methods: `Json(opts...)`, `Yaml(opts...)`, `Equals(n, opts...)`, `Diff(n, opts...)`, `Patch(d)`. Constructor: `NewJsonNode(any)`.
- Diffs: `DiffElement{Metadata, Options, Path, Before, Remove, Add, After}` and `Diff` (slice of elements). Renderers: `Render`, `RenderPatch` (RFC 6902), `RenderMerge` (RFC 7386). Readers: `ReadDiff*`, `ReadPatch*`, `ReadMerge*`.
- Options: constants `MERGE`, `SET`, `MULTISET`, `COLOR`, `DIFF_ON`, `DIFF_OFF`; builders `Precision(x)`, `SetKeys(...)`, `PathOption(@, ^...)`; parser `ReadOptionsString`.
- Paths: `Path` of elements: key (string), index (number), set (`{}`), multiset (`[]`), setkeys (`{...}`), multisetkeys (`[{...}]`).
- Metadata: `Merge` flag per hunk influences patch strategy.

Design goals for PostgreSQL

- Keep user-facing API JSONB-native: accept upstream-style JSON shapes where possible.
- Use SQL domains on `jsonb` for JSON-shaped concepts (options, path, RFC patches) and composite types for rowset-friendly structures (diff elements).
- Public functions are prefixed `jd_`; internal helpers use `_jd_` and are not meant to be called directly.

Domains (preferred for JSON-shaped concepts)

Use CHECK constraints that call private, immutable validators (`_jd_...`) to ensure shape correctness.

1) Options domain: `jd_option`
- Definition: `CREATE DOMAIN jd_option AS jsonb CHECK (_jd_validate_options(VALUE));`
- Semantics: a JSON array of jd options using upstream encoding.
  - Allowed entries:
    - Strings: `"MERGE"`, `"SET"`, `"MULTISET"`, `"COLOR"`, `"DIFF_ON"`, `"DIFF_OFF"`
    - Objects: `{"precision": number}`, `{"setkeys": [text,...]}`, `{"@": [path...], "^": [options...]}`, `{"Merge": true}`
- Validator: `_jd_validate_options(options jsonb) RETURNS boolean` (IMMUTABLE)

2) Path domain: `jd_path`
- Definition: `CREATE DOMAIN jd_path AS jsonb CHECK (_jd_validate_path(VALUE));`
- Semantics: a JSON array with elements representing jd path elements:
  - string (object key), number (array index), empty object `{}` (set), empty array `[]` (multiset), object `{...}` (setkeys), array with one object `[{...}]` (multisetkeys)
- Validator: `_jd_validate_path(path jsonb) RETURNS boolean` (IMMUTABLE)

3) RFC 6902 patch domain: `jd_patch`
- Definition: `CREATE DOMAIN jd_patch AS jsonb CHECK (_jd_validate_rfc6902(VALUE));`
- Semantics: a JSON array of operation objects per RFC 6902.
- Validator: `_jd_validate_rfc6902(patch jsonb) RETURNS boolean` (IMMUTABLE)

4) RFC 7386 merge patch domain: `jd_merge`
- Definition: `CREATE DOMAIN jd_merge AS jsonb CHECK (jsonb_typeof(VALUE) = 'object');`
- Optional stricter validator: `_jd_validate_rfc7386(merge jsonb) RETURNS boolean`

Composites (rowset-friendly structures)

1) `jd_metadata`
- `create type jd_metadata as ( merge boolean );`

2) `jd_diff_element`
- `create type jd_diff_element as (
    metadata jd_metadata,
    options  jd_option,
    path     jd_path,
    before   jsonb[],
    remove   jsonb[],
    add      jsonb[],
    after    jsonb[]
  );`

Rationale: Returning diffs as `SETOF jd_diff_element` makes it easy to consume in SQL, JOIN by path, and aggregate when needed. Domains keep arguments/returns simple where natural JSON shapes exist.

Public functions (JSONB-only)

Comparison and diff creation

- `jd_equal(a jsonb, b jsonb, options jd_option DEFAULT '[]'::jsonb) RETURNS boolean`
  - Equivalent to `JsonNode.Equals` with jd options (global or path-scoped).

- `jd_diff_text(a jsonb, b jsonb, options jd_option DEFAULT '[]'::jsonb) RETURNS text`
  - Equivalent to `Diff.Render()` in jd native text format. Rendering-only options like `COLOR` may be honored.

- `jd_diff(a jsonb, b jsonb, options jd_option, format jd_diff_format DEFAULT 'jd') RETURNS jsonb`
  - Format-aware wrapper that returns the diff in one of the supported formats:
    - `format = 'jd'` → returns a JSON string value containing the jd native structured diff text.
    - `format = 'patch'` → returns an RFC 6902 JSON Patch (JSON array of operations).
    - `format = 'merge'` → returns an RFC 7386 Merge Patch (JSON object with fields to set/remove via null).

- `jd_diff_struct(a jsonb, b jsonb, options jd_option DEFAULT '[]'::jsonb) RETURNS SETOF jd_diff_element`
  - Structural diff suitable for programmatic inspection.

- `jd_diff_patch(a jsonb, b jsonb, options jd_option DEFAULT '[]'::jsonb) RETURNS jd_patch`
  - Equivalent to `Diff.RenderPatch()` — RFC 6902 patch as JSONB.

 - `jd_diff_merge(a jsonb, b jsonb, options jd_option DEFAULT '[]'::jsonb) RETURNS jd_merge`
  - Equivalent to `Diff.RenderMerge()` — RFC 7386 patch as JSONB.

Patch application

- `jd_patch_text(value jsonb, diff_text text) RETURNS jsonb`
  - Apply jd native diff text to a JSONB value.

- `jd_patch_struct(value jsonb, diff_elements jd_diff_element[]) RETURNS jsonb`
  - Apply a structured diff (array form). Users can `array_agg` from a rowset.

 - `jd_apply_patch(value jsonb, patch jd_patch) RETURNS jsonb`
  - Apply an RFC 6902 JSON Patch to a JSONB value.
 - `jd_apply_merge(value jsonb, patch jd_merge) RETURNS jsonb`
  - Apply an RFC 7386 JSON Merge Patch to a JSONB value (objects are merged recursively, arrays and scalars replace; `null` removes a key).

Diff parsing and rendering

- `jd_read_diff_text(diff_text text) RETURNS SETOF jd_diff_element`
  - Parse jd native diff text into structured elements.

- `jd_render_diff_text(diff_elements jd_diff_element[], options jd_option DEFAULT '[]'::jsonb) RETURNS text`
  - Render structured diff elements into jd native text.

- `jd_render_diff_patch(diff_elements jd_diff_element[]) RETURNS jd_patch`
  - Convert structured diff elements to RFC 6902 JSON Patch.

- `jd_render_diff_merge(diff_elements jd_diff_element[]) RETURNS jd_merge`
  - Convert structured diff elements to RFC 7386 Merge Patch.

- `jd_translate_diff_format(diff_content jsonb, input_format jd_diff_format, output_format jd_diff_format) RETURNS jsonb`
  - Translate a diff representation between formats `jd`, `patch`, and `merge`.
  - Semantics:
    - If `input_format = output_format`, the value is returned unchanged.
    - If either format is `jd`, the jd content is passed/returned as a JSON string value containing the jd native text.
    - Translations convert via the internal structured diff representation.
  - Examples:
    - `select jd_translate_diff_format('"@ [\"a\"]\n+ 1\n"'::jsonb, 'jd', 'patch');`
    - `select jd_translate_diff_format('[{"op":"add","path":"/a","value":1}]'::jsonb, 'patch', 'jd');`

Render helper

- `jd_render_json(value jsonb, options jd_option DEFAULT '[]'::jsonb) RETURNS text`
  - Render normalized JSON text (no YAML support in PL/pgSQL).

Optional public utility

- `jd_options_normalize(options jd_option) RETURNS jd_option`
  - Validate/normalize an options array (no-op if already valid/canonical).

Private helper functions (`_jd_` prefix)

Validators for domains (IMMUTABLE)

- `_jd_validate_options(options jsonb) RETURNS boolean`
- `_jd_validate_path(path jsonb) RETURNS boolean`
- `_jd_validate_rfc6902(patch jsonb) RETURNS boolean`
- `_jd_validate_rfc7386(merge jsonb) RETURNS boolean` (optional)

Options/path parsing and normalization

- `_jd_options_parse(options jd_option) RETURNS jsonb`  -- optional normalized internal form
- `_jd_path_normalize(path jd_path) RETURNS jd_path`

Equality and numeric precision

- `_jd_equal_impl(a jsonb, b jsonb, options jd_option) RETURNS boolean`
- `_jd_number_equal(a jsonb, b jsonb, precision numeric) RETURNS boolean`
- `_jd_setkeys_project(obj jsonb, keynames text[]) RETURNS jsonb`

Diff construction and rendering

- `_jd_diff_build(a jsonb, b jsonb, base_path jd_path, options jd_option) RETURNS jd_diff_element[]`
- `_jd_diff_render_text(diff_elems jd_diff_element[], options jd_option) RETURNS text`
- `_jd_diff_render_patch(diff_elems jd_diff_element[]) RETURNS jd_patch`
- `_jd_diff_render_merge(diff_elems jd_diff_element[]) RETURNS jd_merge`

Diff parsing and patching

- `_jd_read_diff_text(diff_text text) RETURNS jd_diff_element[]`
- `_jd_patch_apply(value jsonb, diff_elems jd_diff_element[]) RETURNS jsonb`
- `_jd_patch_apply_element(value jsonb, de jd_diff_element) RETURNS jsonb`
- `_jd_patch_merge_strategy(path jd_path, old jsonb, new jsonb) RETURNS jsonb`

Utility

- `_jd_typeof(j jsonb) RETURNS text`

Examples

Diff and render jd text

```sql
select jd_diff_text(
  '{"foo":["bar","baz"]}'::jsonb,
  '{"foo":["bar","bam","boom"]}'::jsonb,
  '[]'::jsonb
);
```

Equality with precision

```sql
select jd_equal('1.000001'::jsonb, '1.000002'::jsonb, '[{"precision":1e-5}]');
-- true
```

Treat array of objects as a set with keys

```sql
select jd_diff_text(
  '{"items":[{"id":1,"v":"a"},{"id":2,"v":"b"}]}'::jsonb,
  '{"items":[{"id":2,"v":"b"},{"id":1,"v":"z"}]}'::jsonb,
  '[{"@":["items",{}],"^":["SET", {"setkeys":["id"]}]}]'
);
```

Apply RFC 6902 patch

```sql
select jd_apply_patch(
  '{"a":1}'::jsonb,
  '[{"op":"replace","path":"/a","value":2},{"op":"add","path":"/b","value":3}]'::jsonb
);
-- {"a":2,"b":3}
```

MERGE option vs JSON Merge Patch (RFC 7386)

- MERGE is a semantic option that changes how diffs are constructed and how patches apply:
  - Objects merge recursively.
  - Arrays replace entirely (no element-wise merge).
  - Null indicates deletion when applied.
  - In jd text, MERGE can appear as either `^ "MERGE"` or legacy `^ {"Merge":true}`.

- JSON Merge Patch (RFC 7386) is a serialization format for merge-style patches. It is a single JSON object where keys map to changes, nested objects recurse, arrays replace, and `null` deletes a property.

Relevant SQL entrypoints (PL/pgSQL variant):

- Compute diffs in various formats
  - `select jd_diff(a, b, options, 'jd')` → jd diff text returned as a JSONB string
  - `select jd_diff(a, b, options, 'merge')` or `select jd_diff_merge(a, b, options)` → RFC 7386 object
  - `select jd_diff(a, b, options, 'patch')` or `select jd_diff_patch(a, b, options)` → RFC 6902 array

- Translate between formats
  - `select jd_translate_diff_format(diff_jsonb, 'merge', 'jd')` includes a MERGE header in the produced jd text.
  - `select jd_translate_diff_format(diff_jsonb, 'jd', 'merge')` emits RFC 7386 when the jd text contains a MERGE header.

Notes:

- Requesting `'merge'` output implies merge semantics for the produced diff, mirroring upstream jd CLI behavior.
- Rendering to RFC 7386 requires merge-compatible elements; translation from non-merge diffs to RFC 7386 is limited to leaf property replacements/removals.

Scope and constraints (PL/pgSQL variant)

- JSONB-only: no YAML input/output.
- Options are provided in upstream jd JSON encoding via `jd_option` domain and validated by `_jd_validate_options`.
- Path arrays follow upstream jd path syntax and are validated by `_jd_validate_path`.
- Merge vs strict patch semantics are captured per-hunk by `jd_metadata.merge`.
- Rendering option `COLOR` may be a no-op in PL/pgSQL rendering; textual diff format remains the target.
