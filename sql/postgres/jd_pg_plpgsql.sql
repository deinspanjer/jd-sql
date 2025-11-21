-- jd_pg_plpgsql.sql
--
-- Pure PL/pgSQL helpers and entrypoints for jd-sql, a SQL-focused port inspired by
-- the jd project (https://github.com/josephburnett/jd). This initial version
-- focuses on top-level JSONB object diffs and patches using built-in PostgreSQL
-- functionality only (no plv8 integration).
--
-- Scope and compatibility notes:
-- - The jd project defines a rich, human-readable diff format and multiple
--   translation modes. This file provides a pragmatic first step for jd-sql
--   by implementing a small subset that is useful and testable inside Postgres:
--     • Top-level object key adds/removes/replaces
--     • Root scalar replace
-- - The output is a JSONB array of operations compatible with a simplified
--   jd-like structure:
--     [{"op":"add"|"remove"|"replace", "path":[<keys...>], "value":<jsonb?>}]
--   where path is a JSON array of object keys (no array indices yet), and
--   value is required for add/replace and omitted for remove.
-- - Patching applies the above operation set against a JSONB value.
-- - Future versions will expand coverage towards full jd compatibility.
--
-- Installation:
--   \i sql/jd_pg_plpgsql.sql
--
-- Usage:
--   SELECT jd_diff('{"a":1}'::jsonb, '{"a":2,"b":3}'::jsonb);
--   SELECT jd_patch('{"a":1}'::jsonb, '[{"op":"replace","path":["a"],"value":2},{"op":"add","path":["b"],"value":3}]');
--

CREATE OR REPLACE FUNCTION _jd_is_scalar(j jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT jsonb_typeof($1) IN ('string','number','boolean','null');
$$;

COMMENT ON FUNCTION _jd_is_scalar(jsonb) IS 'Internal helper: returns true if the jsonb value is a scalar (string, number, boolean, or null).';


CREATE OR REPLACE FUNCTION _jd_path_text(path jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT COALESCE(string_agg(elem::text, '.'), '')
  FROM jsonb_array_elements_text(COALESCE(path, '[]'::jsonb)) AS e(elem);
$$;

COMMENT ON FUNCTION _jd_path_text(jsonb) IS 'Internal helper: converts a JSON array path (of text keys) into a dotted text path for messages.';


-- Render helpers
CREATE OR REPLACE FUNCTION _jd_render_value(j jsonb)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  t text := CASE WHEN j IS NULL THEN 'void' ELSE jsonb_typeof(j) END;
  out text := '';
  i int;
  n int;
  k text;
  v jsonb;
  first boolean;
BEGIN
  -- SQL NULL indicates no value (should not normally occur for real JSON values)
  IF j IS NULL THEN
    RETURN '';
  END IF;

  IF t = 'object' THEN
    out := '{';
    first := true;
    -- Deterministic key order for stable rendering
    FOR k, v IN
      SELECT key, value FROM jsonb_each(j) ORDER BY key
    LOOP
      IF NOT first THEN
        out := out || ',';
      END IF;
      -- Use to_jsonb(k)::text to ensure proper JSON string quoting for keys
      out := out || to_jsonb(k)::text || ':' || _jd_render_value(v);
      first := false;
    END LOOP;
    out := out || '}';
    RETURN out;
  ELSIF t = 'array' THEN
    out := '[';
    n := COALESCE(jsonb_array_length(j), 0);
    i := 0;
    WHILE i < n LOOP
      IF i > 0 THEN
        out := out || ',';
      END IF;
      out := out || _jd_render_value(j->i);
      i := i + 1;
    END LOOP;
    out := out || ']';
    RETURN out;
  ELSE
    -- Scalars: Postgres jsonb::text is already compact and correct for strings/numbers/booleans/null
    RETURN j::text;
  END IF;
END;
$$;

COMMENT ON FUNCTION _jd_render_value(jsonb) IS 'Internal helper: compact JSON rendering for values (jsonb::text). Returns empty string for SQL NULL (void).';


CREATE OR REPLACE FUNCTION _jd_render_path(path jsonb)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  out text := '[';
  i int := 0;
  n int := COALESCE(jsonb_array_length(path), 0);
  v jsonb;
BEGIN
  WHILE i < n LOOP
    v := path->i;
    IF i > 0 THEN
      out := out || ',';
    END IF;
    -- v::text already renders valid JSON for strings and numbers
    out := out || v::text;
    i := i + 1;
  END LOOP;
  out := out || ']';
  RETURN out;
END;
$$;

COMMENT ON FUNCTION _jd_render_path(jsonb) IS 'Internal helper: render a JSONB path array as jd path string (e.g., ["a",1]).';


CREATE OR REPLACE FUNCTION _jd_path_append(path jsonb, elem jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT COALESCE($1,'[]'::jsonb) || jsonb_build_array($2);
$$;

COMMENT ON FUNCTION _jd_path_append(jsonb, jsonb) IS 'Internal helper: append an element to a JSONB array path.';


CREATE OR REPLACE FUNCTION _jd_diff_array(a jsonb, b jsonb, path jsonb)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  la int := COALESCE(jsonb_array_length(a), 0);
  lb int := COALESCE(jsonb_array_length(b), 0);
  p int := 0; -- common prefix length
  s int := 0; -- common suffix length
  i int;
  out text := '';
  idx_path jsonb;
BEGIN
  -- Find common prefix
  WHILE p < la AND p < lb AND a->p = b->p LOOP
    p := p + 1;
  END LOOP;

  -- Find common suffix (ensure no overlap with prefix)
  WHILE (s < la - p) AND (s < lb - p) AND (a->(la - 1 - s)) = (b->(lb - 1 - s)) LOOP
    s := s + 1;
  END LOOP;

  IF la = lb AND p = la THEN
    RETURN '';
  END IF;

  idx_path := _jd_path_append(path, to_jsonb(p));
  out := out || '@ ' || _jd_render_path(idx_path) || E'\n';

  IF p = 0 THEN
    out := out || '[' || E'\n';
  ELSE
    out := out || '  ' || _jd_render_value(a->(p-1)) || E'\n';
  END IF;

  -- deletions (from a[p .. la-s-1])
  i := p;
  WHILE i < la - s LOOP
    out := out || '- ' || _jd_render_value(a->i) || E'\n';
    i := i + 1;
  END LOOP;

  -- additions (from b[p .. lb-s-1])
  i := p;
  WHILE i < lb - s LOOP
    out := out || '+ ' || _jd_render_value(b->i) || E'\n';
    i := i + 1;
  END LOOP;

  IF s = 0 THEN
    out := out || ']' || E'\n';
  ELSE
    out := out || '  ' || _jd_render_value(a->(la - s)) || E'\n';
  END IF;

  RETURN out;
END;
$$;

COMMENT ON FUNCTION _jd_diff_array(jsonb, jsonb, jsonb) IS 'Internal helper: compute jd-style array diff for core cases with simple prefix/suffix context.';


CREATE OR REPLACE FUNCTION _jd_diff_text(a jsonb, b jsonb, path jsonb)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  out text := '';
  ta text := CASE WHEN a IS NULL THEN 'void' ELSE jsonb_typeof(a) END;
  tb text := CASE WHEN b IS NULL THEN 'void' ELSE jsonb_typeof(b) END;
  k text;
  v_a jsonb;
  v_b jsonb;
BEGIN
  -- Handle equality including NULLs/void
  IF a IS NOT DISTINCT FROM b THEN
    RETURN '';
  END IF;

  -- Void transitions produce single +/- line
  IF ta = 'void' AND tb <> 'void' THEN
    out := out || '@ ' || _jd_render_path(path) || E'\n'
               || '+ ' || _jd_render_value(b) || E'\n';
    RETURN out;
  ELSIF tb = 'void' AND ta <> 'void' THEN
    out := out || '@ ' || _jd_render_path(path) || E'\n'
               || '- ' || _jd_render_value(a) || E'\n';
    RETURN out;
  END IF;

  -- Objects: recurse per key
  IF ta = 'object' AND tb = 'object' THEN
    -- removals
    FOR k IN
      SELECT key FROM jsonb_object_keys(a) AS key
      EXCEPT
      SELECT key FROM jsonb_object_keys(b) AS key
    LOOP
      out := out || '@ ' || _jd_render_path(_jd_path_append(path, to_jsonb(k))) || E'\n'
                  || '- ' || _jd_render_value(a->k) || E'\n';
    END LOOP;

    -- additions
    FOR k IN
      SELECT key FROM jsonb_object_keys(b) AS key
      EXCEPT
      SELECT key FROM jsonb_object_keys(a) AS key
    LOOP
      out := out || '@ ' || _jd_render_path(_jd_path_append(path, to_jsonb(k))) || E'\n'
                  || '+ ' || _jd_render_value(b->k) || E'\n';
    END LOOP;

    -- changes
    FOR k IN
      SELECT key
      FROM (
        SELECT key FROM jsonb_object_keys(a) AS key
        INTERSECT
        SELECT key FROM jsonb_object_keys(b) AS key
      ) s
    LOOP
      v_a := a->k; v_b := b->k;
      IF v_a IS DISTINCT FROM v_b THEN
        out := out || _jd_diff_text(v_a, v_b, _jd_path_append(path, to_jsonb(k)));
      END IF;
    END LOOP;

    RETURN out;
  ELSIF ta = 'array' AND tb = 'array' THEN
    RETURN _jd_diff_array(a, b, path);
  ELSE
    -- Scalar changes or type changes (non-void): emit replace as -/+ pair
    out := out || '@ ' || _jd_render_path(path) || E'\n'
               || '- ' || _jd_render_value(a) || E'\n'
               || '+ ' || _jd_render_value(b) || E'\n';
    RETURN out;
  END IF;
END;
$$;

COMMENT ON FUNCTION _jd_diff_text(jsonb, jsonb, jsonb) IS 'Internal helper: recursive jd-style textual diff limited to core spec cases.';


CREATE OR REPLACE FUNCTION jd_diff(a jsonb, b jsonb)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  RETURN _jd_diff_text(a, b, '[]'::jsonb);
END;
$$;

COMMENT ON FUNCTION jd_diff(jsonb, jsonb) IS 'Compute jd spec-like textual diff for core cases. Returns empty string when equal.';


CREATE OR REPLACE FUNCTION _jd_apply_op(doc jsonb, op jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  oper text := op->>'op';
  path jsonb := COALESCE(op->'path', '[]'::jsonb);
  p0 text;
  val jsonb := op->'value';
BEGIN
  -- Only support empty path (root) or single-key top-level paths for now
  IF jsonb_array_length(path) = 0 THEN
    IF oper = 'replace' THEN
      RETURN val;
    ELSIF oper = 'add' THEN
      -- add at root is equivalent to replace
      RETURN val;
    ELSIF oper = 'remove' THEN
      -- removing root yields NULL (jd void). Represent with jsonb 'null'.
      RETURN 'null'::jsonb;
    ELSE
      RAISE EXCEPTION 'Unsupported op at root: %', oper;
    END IF;
  ELSIF jsonb_array_length(path) = 1 THEN
    p0 := path->>0;
    IF oper = 'remove' THEN
      IF jsonb_typeof(doc) <> 'object' THEN
        RAISE EXCEPTION 'Cannot remove key % from non-object at path %', p0, _jd_path_text(path);
      END IF;
      RETURN doc - p0;
    ELSIF oper = 'add' THEN
      IF jsonb_typeof(doc) <> 'object' THEN
        RAISE EXCEPTION 'Cannot add key % to non-object at path %', p0, _jd_path_text(path);
      END IF;
      RETURN jsonb_set(doc, ARRAY[p0], val, true);
    ELSIF oper = 'replace' THEN
      IF jsonb_typeof(doc) = 'object' THEN
        RETURN jsonb_set(doc, ARRAY[p0], val, true);
      ELSE
        RAISE EXCEPTION 'Cannot replace at key % on non-object at path %', p0, _jd_path_text(path);
      END IF;
    ELSE
      RAISE EXCEPTION 'Unsupported op: %', oper;
    END IF;
  ELSE
    RAISE EXCEPTION 'Nested paths are not yet supported (path: %)', _jd_path_text(path);
  END IF;
END;
$$;

COMMENT ON FUNCTION _jd_apply_op(jsonb, jsonb) IS 'Internal helper: apply a single simplified jd-like operation to a JSONB document.';


CREATE OR REPLACE FUNCTION jd_patch(a jsonb, diff jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  res jsonb := a;
  op jsonb;
BEGIN
  IF diff IS NULL OR diff = 'null'::jsonb THEN
    RETURN res;
  END IF;
  IF jsonb_typeof(diff) <> 'array' THEN
    RAISE EXCEPTION 'jd_patch expects an array of operations, got %', jsonb_typeof(diff);
  END IF;
  FOR op IN SELECT t.elem FROM jsonb_array_elements(diff) AS t(elem)
  LOOP
    res := _jd_apply_op(res, op);
  END LOOP;
  RETURN res;
END;
$$;

COMMENT ON FUNCTION jd_patch(jsonb, jsonb) IS 'Apply a simplified jd-like diff operation array to a JSONB value.';
