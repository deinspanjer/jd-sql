-- jd_pg_plpgsql.sql
--
-- License: MIT
-- This file is licensed under the MIT License. See the LICENSE file at
-- github.com/deinspanjer/jd-sql/LICENSE for full license text.
--
-- Copyright (c) 2025 Daniel Einspanjer
--
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
--     • Root scalar replace and array core cases with simple context
-- - The primary output is a jd v2-style textual diff (lines starting with ^, @, -, +, or space).
-- - A simple patcher is also provided which applies a simplified operation array format.
-- - Future versions will expand coverage towards full jd compatibility.
--
-- Installation:
--   \i sql/jd_pg_plpgsql.sql
--
-- Usage:
--   SELECT jd_diff('{"a":1}'::jsonb, '{"a":2,"b":3}'::jsonb, NULL);
--   SELECT jd_diff('{"a":1}'::jsonb, '{"a":2,"b":3}'::jsonb, '[{"@":[],"^":["DIFF_ON"]}]');
--   SELECT jd_patch('{"a":1}'::jsonb, '[{"op":"replace","path":["a"],"value":2},{"op":"add","path":["b"],"value":3}]', NULL);
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
  num numeric;
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
    -- Scalars: Render numbers without trailing .0 when integral; otherwise use jsonb::text
    IF t = 'number' THEN
      -- Render numeric in minimal JSON form: trim trailing zeros after decimal
      -- Start from the textual representation to preserve exponent forms
      out := j#>>'{}';
      -- If it looks like a plain decimal (no exponent), trim trailing zeros and possible trailing dot
      IF position('e' in lower(out)) = 0 AND position('E' in out) = 0 THEN
        IF position('.' in out) > 0 THEN
          -- Remove trailing zeros
          WHILE right(out, 1) = '0' LOOP
            out := left(out, length(out)-1);
          END LOOP;
          -- If a trailing dot remains, remove it
          IF right(out, 1) = '.' THEN
            out := left(out, length(out)-1);
          END IF;
        END IF;
      END IF;
      RETURN out;
    ELSE
      -- For non-number scalars (string/boolean/null): Postgres jsonb::text is compact and correct
      RETURN j::text;
    END IF;
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
    -- Render compactly: for objects/arrays use _jd_render_value to avoid spaces
    IF jsonb_typeof(v) IN ('object','array') THEN
      out := out || _jd_render_value(v);
    ELSE
      -- v::text renders valid JSON scalars (strings quoted, numbers plain)
      out := out || v::text;
    END IF;
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


-- Numeric closeness check to handle floating point representation edge cases
CREATE OR REPLACE FUNCTION _jd_numbers_close(a jsonb, b jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  na numeric;
  nb numeric;
  diff numeric;
  eps numeric := 1e-15;
BEGIN
  IF a IS NULL OR b IS NULL THEN
    RETURN false;
  END IF;
  IF jsonb_typeof(a) <> 'number' OR jsonb_typeof(b) <> 'number' THEN
    RETURN false;
  END IF;
  -- Cast textual representation to numeric; handle scientific notation as well
  na := (a#>>'{}')::numeric;
  nb := (b#>>'{}')::numeric;
  diff := abs(na - nb);
  -- Use absolute epsilon for core tests; could extend to relative in future
  RETURN diff <= eps;
END;
$$;

COMMENT ON FUNCTION _jd_numbers_close(jsonb, jsonb) IS 'Internal helper: returns true if two jsonb numbers are within a small epsilon.';


-- Options helpers
-- Determine if prefix is a prefix of path (both jsonb arrays)
CREATE OR REPLACE FUNCTION _jd_path_is_prefix(path jsonb, prefix jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  lp int := COALESCE(jsonb_array_length(prefix), 0);
  lpath int := COALESCE(jsonb_array_length(path), 0);
  i int := 0;
BEGIN
  IF lp = 0 THEN
    RETURN true;
  END IF;
  IF lp > lpath THEN
    RETURN false;
  END IF;
  WHILE i < lp LOOP
    IF (path->i) IS DISTINCT FROM (prefix->i) THEN
      RETURN false;
    END IF;
    i := i + 1;
  END LOOP;
  RETURN true;
END;
$$;

COMMENT ON FUNCTION _jd_path_is_prefix(jsonb, jsonb) IS 'Internal helper: true if prefix jsonb array is a prefix of path array.';


CREATE OR REPLACE FUNCTION _jd_apply_option_dir(dir jsonb, diffing_on boolean, eps numeric, set_mode boolean, setkeys jsonb, multiset_mode boolean, color_mode boolean)
RETURNS TABLE(new_diffing_on boolean, new_eps numeric, new_set_mode boolean, new_setkeys jsonb, new_multiset boolean, new_color boolean)
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  t text := jsonb_typeof(dir);
  key text;
  val jsonb;
  out_diffing_on boolean := diffing_on;
  out_eps numeric := eps;
  out_set boolean := set_mode;
  out_setkeys jsonb := setkeys; -- jsonb array of strings or null
  out_multiset boolean := multiset_mode;
  out_color boolean := color_mode;
BEGIN
  IF t = 'string' THEN
    IF dir#>>'{}' = 'DIFF_ON' THEN
      out_diffing_on := true;
    ELSIF dir#>>'{}' = 'DIFF_OFF' THEN
      out_diffing_on := false;
    ELSIF dir#>>'{}' = 'SET' THEN
      out_set := true;
    ELSIF dir#>>'{}' = 'MULTISET' THEN
      out_multiset := true;
    ELSIF dir#>>'{}' = 'COLOR' THEN
      out_color := true;
    END IF;
  ELSIF t = 'object' THEN
    IF dir ? 'precision' THEN
      out_eps := (dir->>'precision')::numeric;
    END IF;
    IF dir ? 'setkeys' THEN
      -- Accept only valid array of strings; ignore otherwise
      IF jsonb_typeof(dir->'setkeys') = 'array' THEN
        out_setkeys := dir->'setkeys';
      END IF;
    END IF;
  END IF;
  RETURN QUERY SELECT out_diffing_on, out_eps, out_set, out_setkeys, out_multiset, out_color;
END;
$$;

COMMENT ON FUNCTION _jd_apply_option_dir(jsonb, boolean, numeric, boolean, jsonb, boolean, boolean) IS 'Internal helper: applies a single option directive to state and returns updated values (including set/setkeys, multiset, and color).';


-- Compute effective options state (diffingOn, precision) at a given path
CREATE OR REPLACE FUNCTION _jd_options_state(options jsonb, path jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  diffing_on boolean := true;  -- default ON
  precision numeric := 1e-15;  -- default epsilon
  set_mode boolean := false;    -- default normal array (not set)
  setkeys jsonb := NULL;        -- default no setkeys
  multiset_mode boolean := false; -- default normal array (no multiset)
  color_mode boolean := false;    -- default no color
  elem jsonb;
  t text;
  dirs jsonb;
  d jsonb;
BEGIN
  IF options IS NULL OR jsonb_typeof(options) <> 'array' THEN
    RETURN jsonb_build_object('diffingOn', diffing_on, 'precision', precision, 'set', set_mode, 'setkeys', setkeys, 'multiset', multiset_mode, 'color', color_mode);
  END IF;

  FOR elem IN SELECT e FROM jsonb_array_elements(options) AS z(e)
  LOOP
    t := jsonb_typeof(elem);
    IF t = 'object' AND elem ? '@' AND elem ? '^' THEN
      -- PathOptions element
      IF _jd_path_is_prefix(path, COALESCE(elem->'@', '[]'::jsonb)) THEN
        dirs := elem->'^';
        IF jsonb_typeof(dirs) = 'array' THEN
          FOR d IN SELECT e FROM jsonb_array_elements(dirs) AS y(e) LOOP
            SELECT new_diffing_on, new_eps, new_set_mode, new_setkeys, new_multiset, new_color INTO diffing_on, precision, set_mode, setkeys, multiset_mode, color_mode
            FROM _jd_apply_option_dir(d, diffing_on, precision, set_mode, setkeys, multiset_mode, color_mode);
          END LOOP;
        ELSE
          SELECT new_diffing_on, new_eps, new_set_mode, new_setkeys, new_multiset, new_color INTO diffing_on, precision, set_mode, setkeys, multiset_mode, color_mode
          FROM _jd_apply_option_dir(dirs, diffing_on, precision, set_mode, setkeys, multiset_mode, color_mode);
        END IF;
      END IF;
    ELSE
      -- Global option applied everywhere (treat element itself as a directive)
      SELECT new_diffing_on, new_eps, new_set_mode, new_setkeys, new_multiset, new_color INTO diffing_on, precision, set_mode, setkeys, multiset_mode, color_mode
      FROM _jd_apply_option_dir(elem, diffing_on, precision, set_mode, setkeys, multiset_mode, color_mode);
    END IF;
  END LOOP;

  RETURN jsonb_build_object('diffingOn', diffing_on, 'precision', precision, 'set', set_mode, 'setkeys', setkeys, 'multiset', multiset_mode, 'color', color_mode);
END;
$$;

COMMENT ON FUNCTION _jd_options_state(jsonb, jsonb) IS 'Internal helper: computes effective options at a given path (diffingOn, precision, set, setkeys).';


-- Build an identifier object from a source object using supplied keys array
CREATE OR REPLACE FUNCTION _jd_ident_from_keys(obj jsonb, keys jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  i int := 0;
  n int := COALESCE(jsonb_array_length(keys), 0);
  k text;
  ident jsonb := '{}'::jsonb;
BEGIN
  IF obj IS NULL OR jsonb_typeof(obj) <> 'object' THEN
    RETURN NULL;
  END IF;
  WHILE i < n LOOP
    k := keys->>i;
    IF k IS NOT NULL THEN
      ident := ident || jsonb_build_object(k, obj->k);
    END IF;
    i := i + 1;
  END LOOP;
  RETURN ident;
END;
$$;

COMMENT ON FUNCTION _jd_ident_from_keys(jsonb, jsonb) IS 'Internal helper: returns an identifier object composed of the specified keys from obj.';


CREATE OR REPLACE FUNCTION _jd_numbers_close_prec(a jsonb, b jsonb, eps numeric)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  na numeric;
  nb numeric;
  diff numeric;
BEGIN
  IF a IS NULL OR b IS NULL THEN
    RETURN false;
  END IF;
  IF jsonb_typeof(a) <> 'number' OR jsonb_typeof(b) <> 'number' THEN
    RETURN false;
  END IF;
  na := (a#>>'{}')::numeric;
  nb := (b#>>'{}')::numeric;
  diff := abs(na - nb);
  RETURN diff <= eps;
END;
$$;

COMMENT ON FUNCTION _jd_numbers_close_prec(jsonb, jsonb, numeric) IS 'Internal helper: numeric closeness with specified epsilon.';


CREATE OR REPLACE FUNCTION _jd_diff_array(a jsonb, b jsonb, path jsonb, options jsonb)
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
  st jsonb := _jd_options_state(options, path);
  set_mode boolean := COALESCE((st->>'set')::boolean, false);
  setkeys jsonb := st->'setkeys';
  multiset_mode boolean := COALESCE((st->>'multiset')::boolean, false);
  v jsonb;
BEGIN
  -- Honor DIFF_ON/OFF at the current path
  IF COALESCE((st->>'diffingOn')::boolean, true) = false THEN
    RETURN '';
  END IF;

  -- Simple SET mode (ignore order, ignore duplicates) when enabled and no setkeys/multiset active
  IF set_mode = true AND setkeys IS NULL AND multiset_mode = false THEN
    DECLARE
      a_set jsonb := '[]'::jsonb;
      b_set jsonb := '[]'::jsonb;
      elem jsonb;
      exists_in boolean;
      rem jsonb := '[]'::jsonb;
      add jsonb := '[]'::jsonb;
    BEGIN
      -- Build distinct sets from a and b (by JSONB equality)
      FOR elem IN SELECT e FROM jsonb_array_elements(a) AS z(e) LOOP
        SELECT EXISTS (
          SELECT 1 FROM jsonb_array_elements(a_set) AS s(x) WHERE s.x = elem
        ) INTO exists_in;
        IF NOT exists_in THEN
          a_set := a_set || jsonb_build_array(elem);
        END IF;
      END LOOP;
      FOR elem IN SELECT e FROM jsonb_array_elements(b) AS z(e) LOOP
        SELECT EXISTS (
          SELECT 1 FROM jsonb_array_elements(b_set) AS s(x) WHERE s.x = elem
        ) INTO exists_in;
        IF NOT exists_in THEN
          b_set := b_set || jsonb_build_array(elem);
        END IF;
      END LOOP;

      -- Compute removals (in a_set but not in b_set)
      FOR elem IN SELECT x FROM jsonb_array_elements(a_set) AS s(x) LOOP
        SELECT EXISTS (
          SELECT 1 FROM jsonb_array_elements(b_set) AS t(y) WHERE t.y = elem
        ) INTO exists_in;
        IF NOT exists_in THEN
          rem := rem || jsonb_build_array(elem);
        END IF;
      END LOOP;
      -- Compute additions (in b_set but not in a_set)
      FOR elem IN SELECT y FROM jsonb_array_elements(b_set) AS t(y) LOOP
        SELECT EXISTS (
          SELECT 1 FROM jsonb_array_elements(a_set) AS s(x) WHERE s.x = elem
        ) INTO exists_in;
        IF NOT exists_in THEN
          add := add || jsonb_build_array(elem);
        END IF;
      END LOOP;

      -- If sets are equal, no diff
      IF jsonb_array_length(rem) = 0 AND jsonb_array_length(add) = 0 THEN
        RETURN '';
      END IF;

      -- Emit a set-style diff block at a synthetic index {}
      idx_path := _jd_path_append(path, '{}'::jsonb);
      out := out || '@ ' || _jd_render_path(idx_path) || E'\n';
      -- Removals
      FOR elem IN SELECT x FROM jsonb_array_elements(rem) AS s(x) LOOP
        out := out || '- ' || _jd_render_value(elem) || E'\n';
      END LOOP;
      -- Additions
      FOR elem IN SELECT y FROM jsonb_array_elements(add) AS t(y) LOOP
        out := out || '+ ' || _jd_render_value(elem) || E'\n';
      END LOOP;
      RETURN out;
    END;
  END IF;

  -- SetKeys mode: arrays of objects matched by identifier keys
  IF setkeys IS NOT NULL AND jsonb_typeof(setkeys) = 'array' THEN
    DECLARE
      header_written boolean := false;
      obj_id jsonb;
      a_val jsonb;
      b_val jsonb;
      subdiff text;
    BEGIN
      -- Deletions (ids in a but not in b)
      FOR obj_id, a_val IN
        SELECT _id, val
        FROM (
          SELECT (_jd_ident_from_keys(e, setkeys)) AS _id, e AS val, min(ord) AS o
          FROM jsonb_array_elements(a) WITH ORDINALITY z(e,ord)
          WHERE jsonb_typeof(e) = 'object'
          GROUP BY _id, e
        ) aa
        WHERE NOT EXISTS (
          SELECT 1 FROM (
            SELECT (_jd_ident_from_keys(e, setkeys)) AS _id
            FROM jsonb_array_elements(b) z(e)
            WHERE jsonb_typeof(e) = 'object'
          ) bb WHERE bb._id = aa._id
        )
        ORDER BY o
      LOOP
        IF NOT header_written THEN
          out := out || '^ ' || _jd_render_value(jsonb_build_object('setkeys', setkeys)) || E'\n';
          header_written := true;
        END IF;
        out := out || '@ ' || _jd_render_path(_jd_path_append(path, obj_id)) || E'\n';
        out := out || '- ' || _jd_render_value(a_val) || E'\n';
      END LOOP;

      -- Additions (ids in b but not in a)
      FOR obj_id, b_val IN
        SELECT _id, val
        FROM (
          SELECT (_jd_ident_from_keys(e, setkeys)) AS _id, e AS val, min(ord) AS o
          FROM jsonb_array_elements(b) WITH ORDINALITY z(e,ord)
          WHERE jsonb_typeof(e) = 'object'
          GROUP BY _id, e
        ) bb
        WHERE NOT EXISTS (
          SELECT 1 FROM (
            SELECT (_jd_ident_from_keys(e, setkeys)) AS _id
            FROM jsonb_array_elements(a) z(e)
            WHERE jsonb_typeof(e) = 'object'
          ) aa WHERE aa._id = bb._id
        )
        ORDER BY o
      LOOP
        IF NOT header_written THEN
          out := out || '^ ' || _jd_render_value(jsonb_build_object('setkeys', setkeys)) || E'\n';
          header_written := true;
        END IF;
        out := out || '@ ' || _jd_render_path(_jd_path_append(path, obj_id)) || E'\n';
        out := out || '+ ' || _jd_render_value(b_val) || E'\n';
      END LOOP;

      -- Matched ids: recurse into object diffs (use only the first occurrence per id on each side)
      FOR obj_id, a_val, b_val IN
        WITH a_first AS (
          SELECT DISTINCT ON (_id)
                 _id,
                 val
          FROM (
            SELECT (_jd_ident_from_keys(e, setkeys)) AS _id, e AS val, ord
            FROM jsonb_array_elements(a) WITH ORDINALITY z(e,ord)
            WHERE jsonb_typeof(e) = 'object'
          ) s
          ORDER BY _id, ord
        ), b_first AS (
          SELECT DISTINCT ON (_id)
                 _id,
                 val
          FROM (
            SELECT (_jd_ident_from_keys(e, setkeys)) AS _id, e AS val, ord
            FROM jsonb_array_elements(b) WITH ORDINALITY z(e,ord)
            WHERE jsonb_typeof(e) = 'object'
          ) s
          ORDER BY _id, ord
        )
        SELECT a_first._id, a_first.val, b_first.val
        FROM a_first JOIN b_first USING (_id)
        ORDER BY _id::text
      LOOP
        subdiff := _jd_diff_text(a_val, b_val, _jd_path_append(path, obj_id), options);
        IF subdiff IS NOT NULL AND subdiff <> '' THEN
          IF NOT header_written THEN
            out := out || '^ ' || _jd_render_value(jsonb_build_object('setkeys', setkeys)) || E'\n';
            header_written := true;
          END IF;
          out := out || subdiff;
        END IF;
      END LOOP;

      -- Handle duplicate occurrences for ids present in both arrays: remove extras from A, add extras from B
      -- Extras in A (beyond the first occurrence) should be deleted by index
      FOR i, v IN
        WITH a_elems AS (
          SELECT (_jd_ident_from_keys(e, setkeys)) AS _id, e AS val, ord
          FROM jsonb_array_elements(a) WITH ORDINALITY z(e,ord)
          WHERE jsonb_typeof(e) = 'object'
        ), b_ids AS (
          SELECT DISTINCT (_jd_ident_from_keys(e, setkeys)) AS _id
          FROM jsonb_array_elements(b) z(e)
          WHERE jsonb_typeof(e) = 'object'
        ), a_dups AS (
          SELECT _id, val, ord, min(ord) OVER (PARTITION BY _id) AS first_ord
          FROM a_elems
        )
        SELECT ord, val
        FROM a_dups
        WHERE _id IN (SELECT _id FROM b_ids) AND ord > first_ord
        ORDER BY ord
      LOOP
        IF NOT header_written THEN
          out := out || '^ ' || _jd_render_value(jsonb_build_object('setkeys', setkeys)) || E'\n';
          header_written := true;
        END IF;
        out := out || '@ ' || _jd_render_path(_jd_path_append(path, to_jsonb(i - 1))) || E'\n';
        out := out || '- ' || _jd_render_value(v) || E'\n';
      END LOOP;

      -- Extras in B (beyond the first occurrence) should be added by index
      FOR i, v IN
        WITH b_elems AS (
          SELECT (_jd_ident_from_keys(e, setkeys)) AS _id, e AS val, ord
          FROM jsonb_array_elements(b) WITH ORDINALITY z(e,ord)
          WHERE jsonb_typeof(e) = 'object'
        ), a_ids AS (
          SELECT DISTINCT (_jd_ident_from_keys(e, setkeys)) AS _id
          FROM jsonb_array_elements(a) z(e)
          WHERE jsonb_typeof(e) = 'object'
        ), b_dups AS (
          SELECT _id, val, ord, min(ord) OVER (PARTITION BY _id) AS first_ord
          FROM b_elems
        )
        SELECT ord, val
        FROM b_dups
        WHERE _id IN (SELECT _id FROM a_ids) AND ord > first_ord
        ORDER BY ord
      LOOP
        IF NOT header_written THEN
          out := out || '^ ' || _jd_render_value(jsonb_build_object('setkeys', setkeys)) || E'\n';
          header_written := true;
        END IF;
        out := out || '@ ' || _jd_render_path(_jd_path_append(path, to_jsonb(i - 1))) || E'\n';
        out := out || '+ ' || _jd_render_value(v) || E'\n';
      END LOOP;

      RETURN out;
    END;
  END IF;

  -- Multiset mode: compare counts ignoring order, allow duplicates
  IF multiset_mode THEN
    DECLARE
      have_diff boolean := false;
      cnt int;
      val jsonb;
    BEGIN
      -- quick equality check by counts
      IF NOT EXISTS (
        SELECT 1 FROM (
          SELECT e AS v, count(*) AS c FROM jsonb_array_elements(a) z(e) GROUP BY e
        ) aa FULL JOIN (
          SELECT e AS v, count(*) AS c FROM jsonb_array_elements(b) z(e) GROUP BY e
        ) bb ON aa.v = bb.v
        WHERE COALESCE(aa.c,0) <> COALESCE(bb.c,0)
      ) THEN
        RETURN '';
      END IF;

      out := out || '^ ' || '"MULTISET"' || E'\n';
      out := out || '@ ' || _jd_render_path(_jd_path_append(path, '[]'::jsonb)) || E'\n';

      -- Deletions: values where a has more than b
      FOR val, cnt IN
        SELECT _v, (a_c - COALESCE(b_c,0)) AS n
        FROM (
          SELECT e AS _v, count(*) AS a_c FROM jsonb_array_elements(a) z(e) GROUP BY e
        ) A LEFT JOIN (
          SELECT e AS _v, count(*) AS b_c FROM jsonb_array_elements(b) z(e) GROUP BY e
        ) B USING (_v)
        WHERE (a_c - COALESCE(b_c,0)) > 0
        ORDER BY 1
      LOOP
        WHILE cnt > 0 LOOP
          out := out || '- ' || _jd_render_value(val) || E'\n';
          cnt := cnt - 1;
        END LOOP;
      END LOOP;

      -- Additions: values where b has more than a
      FOR val, cnt IN
        SELECT _v, (b_c - COALESCE(a_c,0)) AS n
        FROM (
          SELECT e AS _v, count(*) AS b_c FROM jsonb_array_elements(b) z(e) GROUP BY e
        ) B LEFT JOIN (
          SELECT e AS _v, count(*) AS a_c FROM jsonb_array_elements(a) z(e) GROUP BY e
        ) A USING (_v)
        WHERE (b_c - COALESCE(a_c,0)) > 0
        ORDER BY 1
      LOOP
        WHILE cnt > 0 LOOP
          out := out || '+ ' || _jd_render_value(val) || E'\n';
          cnt := cnt - 1;
        END LOOP;
      END LOOP;

      RETURN out;
    END;
  END IF;

  -- Set mode: compare ignoring order; header and {} path marker
  IF set_mode THEN
    -- Build removals: unique elements in a not present in b
    out := out; -- no-op for clarity
    -- Determine differences
    DECLARE
      have_diff boolean := false;
    BEGIN
      -- Check if sets are equal quickly
      -- If every distinct elem in a exists in b and vice versa, then no diff
      IF NOT EXISTS (
        SELECT 1 FROM (
          SELECT DISTINCT e AS v FROM jsonb_array_elements(a) z(e)
        ) aa
        WHERE NOT EXISTS (
          SELECT 1 FROM jsonb_array_elements(b) bb(e) WHERE bb.e = aa.v
        )
      ) AND NOT EXISTS (
        SELECT 1 FROM (
          SELECT DISTINCT e AS v FROM jsonb_array_elements(b) z(e)
        ) bb
        WHERE NOT EXISTS (
          SELECT 1 FROM jsonb_array_elements(a) aa(e) WHERE aa.e = bb.v
        )
      ) THEN
        RETURN '';
      END IF;

      out := out || '^ ' || '"SET"' || E'\n';
      out := out || '@ ' || _jd_render_path(_jd_path_append(path, '{}'::jsonb)) || E'\n';

      -- Deletions in deterministic order: by original order of a, but unique and only those not in b
      FOR v IN
        SELECT val FROM (
          SELECT e AS val, min(ord) AS o
          FROM (
            SELECT e, ord
            FROM jsonb_array_elements(a) WITH ORDINALITY t(e,ord)
          ) x
          GROUP BY e
          HAVING NOT EXISTS (
            SELECT 1 FROM jsonb_array_elements(b) q(e2) WHERE q.e2 = e
          )
        ) s
        ORDER BY o
      LOOP
        out := out || '- ' || _jd_render_value(v) || E'\n';
      END LOOP;

      -- Additions in deterministic order: by original order of b, but unique and only those not in a
      FOR v IN
        SELECT val FROM (
          SELECT e AS val, min(ord) AS o
          FROM (
            SELECT e, ord
            FROM jsonb_array_elements(b) WITH ORDINALITY t(e,ord)
          ) x
          GROUP BY e
          HAVING NOT EXISTS (
            SELECT 1 FROM jsonb_array_elements(a) q(e2) WHERE q.e2 = e
          )
        ) s
        ORDER BY o
      LOOP
        out := out || '+ ' || _jd_render_value(v) || E'\n';
      END LOOP;

      RETURN out;
    END;
  END IF;
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

  -- For normal arrays, compute common prefix/suffix while treating numerically-close numbers as equal per options
  WHILE p < la AND p < lb LOOP
    idx_path := _jd_path_append(path, to_jsonb(p));
    IF jsonb_typeof(a->p) = 'number' AND jsonb_typeof(b->p) = 'number' THEN
      IF NOT _jd_numbers_close_prec(a->p, b->p, ((_jd_options_state(options, idx_path)->>'precision')::numeric)) THEN
        EXIT;
      END IF;
    ELSE
      IF (a->p) IS DISTINCT FROM (b->p) THEN
        EXIT;
      END IF;
    END IF;
    p := p + 1;
  END LOOP;

  WHILE (s < la - p) AND (s < lb - p) LOOP
    idx_path := _jd_path_append(path, to_jsonb(lb - s - 1));
    IF jsonb_typeof(a->(la - s - 1)) = 'number' AND jsonb_typeof(b->(lb - s - 1)) = 'number' THEN
      IF NOT _jd_numbers_close_prec(a->(la - s - 1), b->(lb - s - 1), ((_jd_options_state(options, idx_path)->>'precision')::numeric)) THEN
        EXIT;
      END IF;
    ELSE
      IF (a->(la - s - 1)) IS DISTINCT FROM (b->(lb - s - 1)) THEN
        EXIT;
      END IF;
    END IF;
    s := s + 1;
  END LOOP;

  -- If arrays are effectively equal under precision, return no diff
  IF p = la AND p = lb THEN
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

COMMENT ON FUNCTION _jd_diff_array(jsonb, jsonb, jsonb, jsonb) IS 'Internal helper: compute jd-style array diff for core cases with simple prefix/suffix context. Honors options (DIFF_ON/OFF).';


CREATE OR REPLACE FUNCTION _jd_diff_text(a jsonb, b jsonb, path jsonb, options jsonb)
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
  st jsonb := _jd_options_state(options, path);
  eps numeric := ((jsonb_extract_path_text(_jd_options_state(options, path), 'precision'))::numeric);
  color boolean := COALESCE((_jd_options_state(options, path)->>'color')::boolean, false);
  default_eps numeric := 1e-15;
  header_emitted boolean := false;
  diff_here boolean := COALESCE((st->>'diffingOn')::boolean, true);
BEGIN
  -- Handle equality including NULLs/void
  IF a IS NOT DISTINCT FROM b THEN
    RETURN '';
  END IF;

  -- Treat numerically-close numbers as equal to satisfy floating point precision case
  IF ta = 'number' AND tb = 'number' AND _jd_numbers_close_prec(a, b, eps) THEN
    RETURN '';
  END IF;

  -- Emit headers if needed (color and precision) when we are about to output a change at this path
  PERFORM 1; -- placeholder no-op

  -- Void transitions produce single +/- line when allowed at this path
  IF ta = 'void' AND tb <> 'void' THEN
    IF NOT diff_here THEN
      RETURN '';
    END IF;
    IF color THEN
      out := out || '^ ' || '"COLOR"' || E'\n';
      header_emitted := true;
    END IF;
    IF eps IS NOT NULL AND eps <> default_eps THEN
      out := out || '^ ' || _jd_render_value(jsonb_build_object('precision', to_jsonb(eps))) || E'\n';
      header_emitted := true;
    END IF;
    out := out || '@ ' || _jd_render_path(path) || E'\n'
               || '+ ' || _jd_render_value(b) || E'\n';
    RETURN out;
  ELSIF tb = 'void' AND ta <> 'void' THEN
    IF NOT diff_here THEN
      RETURN '';
    END IF;
    IF color THEN
      out := out || '^ ' || '"COLOR"' || E'\n';
      header_emitted := true;
    END IF;
    IF eps IS NOT NULL AND eps <> default_eps THEN
      out := out || '^ ' || _jd_render_value(jsonb_build_object('precision', to_jsonb(eps))) || E'\n';
      header_emitted := true;
    END IF;
    out := out || '@ ' || _jd_render_path(path) || E'\n'
               || '- ' || _jd_render_value(a) || E'\n';
    RETURN out;
  END IF;

  -- Objects: recurse per key
  IF ta = 'object' AND tb = 'object' THEN
    -- removals (deterministic order) — only when emitting at this path is allowed
    FOR k IN
      SELECT key FROM (
        SELECT key FROM jsonb_object_keys(a) AS key
        EXCEPT
        SELECT key FROM jsonb_object_keys(b) AS key
      ) x
      ORDER BY key
    LOOP
      IF diff_here THEN
        IF out = '' THEN
          IF color THEN
            out := out || '^ ' || '"COLOR"' || E'\n';
          END IF;
          IF eps IS NOT NULL AND eps <> default_eps THEN
            out := out || '^ ' || _jd_render_value(jsonb_build_object('precision', to_jsonb(eps))) || E'\n';
          END IF;
        END IF;
        out := out || '@ ' || _jd_render_path(_jd_path_append(path, to_jsonb(k))) || E'\n'
                    || '- ' || _jd_render_value(a->k) || E'\n';
      END IF;
    END LOOP;

    -- changes (deterministic order)
    FOR k IN
      SELECT key FROM (
        SELECT key FROM jsonb_object_keys(a) AS key
        INTERSECT
        SELECT key FROM jsonb_object_keys(b) AS key
      ) s
      ORDER BY key
    LOOP
      v_a := a->k; v_b := b->k;
      IF v_a IS DISTINCT FROM v_b THEN
        -- Skip differences for numerically-close numbers
        IF jsonb_typeof(v_a) = 'number' AND jsonb_typeof(v_b) = 'number' AND _jd_numbers_close_prec(v_a, v_b, eps) THEN
          -- no-op
        ELSE
          out := out || _jd_diff_text(v_a, v_b, _jd_path_append(path, to_jsonb(k)), options);
        END IF;
      END IF;
    END LOOP;

    -- additions (deterministic order; after changes to match README example)
    FOR k IN
      SELECT key FROM (
        SELECT key FROM jsonb_object_keys(b) AS key
        EXCEPT
        SELECT key FROM jsonb_object_keys(a) AS key
      ) x
      ORDER BY key
    LOOP
      IF diff_here THEN
        IF out = '' THEN
          IF color THEN
            out := out || '^ ' || '"COLOR"' || E'\n';
          END IF;
          IF eps IS NOT NULL AND eps <> default_eps THEN
            out := out || '^ ' || _jd_render_value(jsonb_build_object('precision', to_jsonb(eps))) || E'\n';
          END IF;
        END IF;
        out := out || '@ ' || _jd_render_path(_jd_path_append(path, to_jsonb(k))) || E'\n'
                    || '+ ' || _jd_render_value(b->k) || E'\n';
      END IF;
    END LOOP;

    RETURN out;
  ELSIF ta = 'array' AND tb = 'array' THEN
    RETURN _jd_diff_array(a, b, path, options);
  ELSE
    -- Scalar changes or type changes (non-void): emit replace as -/+ pair when allowed at this path
    IF NOT diff_here THEN
      RETURN '';
    END IF;
    IF color THEN
      out := out || '^ ' || '"COLOR"' || E'\n';
    END IF;
    IF eps IS NOT NULL AND eps <> default_eps THEN
      out := out || '^ ' || _jd_render_value(jsonb_build_object('precision', to_jsonb(eps))) || E'\n';
    END IF;
    out := out || '@ ' || _jd_render_path(path) || E'\n'
               || '- ' || _jd_render_value(a) || E'\n'
               || '+ ' || _jd_render_value(b) || E'\n';
    RETURN out;
  END IF;
END;
$$;

COMMENT ON FUNCTION _jd_diff_text(jsonb, jsonb, jsonb, jsonb) IS 'Internal helper: recursive jd-style textual diff limited to core spec cases. Honors options (DIFF_ON/OFF, precision).';


CREATE OR REPLACE FUNCTION jd_diff(a jsonb, b jsonb, options jsonb DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  body text;
  out text := '';
  elem jsonb;
BEGIN
  body := _jd_diff_text(a, b, '[]'::jsonb, options);

  -- If there is no diff, return immediately (do not emit headers)
  IF COALESCE(body, '') = '' THEN
    RETURN '';
  END IF;

  -- Emit PathOptions headers (objects with '@' and '^') in the order provided
  IF options IS NOT NULL AND jsonb_typeof(options) = 'array' THEN
    FOR elem IN SELECT e FROM jsonb_array_elements(options) AS z(e) LOOP
      IF jsonb_typeof(elem) = 'object' AND (elem ? '@') AND (elem ? '^') THEN
        out := out || '^ ' || _jd_render_value(elem) || E'\n';
      END IF;
    END LOOP;
  END IF;

  RETURN out || body;
END;
$$;

COMMENT ON FUNCTION jd_diff(jsonb, jsonb, jsonb) IS 'Compute jd spec-like textual diff for core cases. Returns empty string when equal. Honors options (DIFF_ON/OFF, precision).';


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


CREATE OR REPLACE FUNCTION jd_patch(a jsonb, diff jsonb, options jsonb DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  res jsonb := a;
  op jsonb;
BEGIN
  -- Currently, options are not used by patching semantics in this simplified implementation.
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

COMMENT ON FUNCTION jd_patch(jsonb, jsonb, jsonb) IS 'Apply a simplified jd-like diff operation array to a JSONB value. Options parameter accepted for signature compatibility.';
