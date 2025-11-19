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


CREATE OR REPLACE FUNCTION jd_diff(a jsonb, b jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  ta text := jsonb_typeof(a);
  tb text := jsonb_typeof(b);
  ops jsonb := '[]'::jsonb;
  k text;
BEGIN
  -- If types differ or either is scalar while not equal: whole-value replace
  IF ta IS DISTINCT FROM tb OR _jd_is_scalar(a) OR _jd_is_scalar(b) THEN
    IF a IS DISTINCT FROM b THEN
      RETURN jsonb_build_array(jsonb_build_object(
        'op','replace', 'path','[]'::jsonb, 'value', b
      ));
    ELSE
      RETURN '[]'::jsonb;
    END IF;
  END IF;

  -- For objects: compute adds, removes, replaces for top-level keys
  IF ta = 'object' THEN
    -- Removed keys (present in a, absent in b)
    FOR k IN
      SELECT key FROM jsonb_object_keys(a) AS key
      EXCEPT
      SELECT key FROM jsonb_object_keys(b) AS key
    LOOP
      ops := ops || jsonb_build_array(jsonb_build_object(
        'op','remove', 'path', jsonb_build_array(k)
      ));
    END LOOP;

    -- Added keys (present in b, absent in a)
    FOR k IN
      SELECT key FROM jsonb_object_keys(b) AS key
      EXCEPT
      SELECT key FROM jsonb_object_keys(a) AS key
    LOOP
      ops := ops || jsonb_build_array(jsonb_build_object(
        'op','add', 'path', jsonb_build_array(k), 'value', b->k
      ));
    END LOOP;

    -- Changed keys (present in both, values differ)
    FOR k IN
      SELECT key
      FROM (
        SELECT key FROM jsonb_object_keys(a) AS key
        INTERSECT
        SELECT key FROM jsonb_object_keys(b) AS key
      ) s
      WHERE a->key IS DISTINCT FROM b->key
    LOOP
      ops := ops || jsonb_build_array(jsonb_build_object(
        'op','replace', 'path', jsonb_build_array(k), 'value', b->k
      ));
    END LOOP;

    RETURN ops;
  ELSIF ta = 'array' THEN
    -- Arrays: for now, only detect whole-value replace when unequal
    IF a IS DISTINCT FROM b THEN
      RETURN jsonb_build_array(jsonb_build_object(
        'op','replace', 'path','[]'::jsonb, 'value', b
      ));
    END IF;
    RETURN '[]'::jsonb;
  ELSE
    -- Fallback: if equal, no ops; otherwise replace
    IF a IS DISTINCT FROM b THEN
      RETURN jsonb_build_array(jsonb_build_object(
        'op','replace', 'path','[]'::jsonb, 'value', b
      ));
    END IF;
    RETURN '[]'::jsonb;
  END IF;
END;
$$;

COMMENT ON FUNCTION jd_diff(jsonb, jsonb) IS 'Compute a simplified jd-like diff between JSONB values. Supports top-level object adds/removes/replaces and whole-value replace for arrays/scalars.';


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
