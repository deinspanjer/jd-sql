-- jsonb_diff_merge.sql
--
-- Purpose: Demonstrate diffing and merging JSONB data in three ways:
--  1) Using only built-in PostgreSQL JSONB operators/functions
--  2) Using only built-in capabilities of plv8 (JavaScript in PostgreSQL)
--  3) Placeholder notes outlining advantages of using jd-sql
--
-- This file is designed to be copy/paste runnable in psql. You can run
-- individual sections independently. Nothing is created permanently
-- except two helper functions in the plv8 section (you can DROP them
-- after experimenting).

-- ================================================================
-- 1) Using only built-in PostgreSQL functions/operators
-- ================================================================
-- Example inputs
\echo '--- Built-in JSONB diff/merge examples ---'
WITH
  a(doc) AS (
    VALUES (
      '{
         "name": "alpha",
         "tags": ["red", "blue"],
         "count": 1,
         "meta": {"owner": "dev", "active": true},
         "old": "remove-me"
       }'::jsonb
    )
  ),
  b(doc) AS (
    VALUES (
      '{
         "name": "alpha",
         "tags": ["red", "green"],
         "count": 2,
         "meta": {"owner": "devops"},
         "extra": "new"
       }'::jsonb
    )
  )
-- Basic key-level diff using jsonb_object_keys and comparisons
SELECT
  ARRAY(
    SELECT k FROM (
      SELECT k FROM jsonb_object_keys((SELECT doc FROM a)) AS k
      EXCEPT
      SELECT k FROM jsonb_object_keys((SELECT doc FROM b)) AS k
    ) s
  )                        AS removed_keys,
  ARRAY(
    SELECT k FROM (
      SELECT k FROM jsonb_object_keys((SELECT doc FROM b)) AS k
      EXCEPT
      SELECT k FROM jsonb_object_keys((SELECT doc FROM a)) AS k
    ) s
  )                        AS added_keys,
  ARRAY(
    SELECT k
    FROM (
      SELECT k
      FROM jsonb_object_keys((SELECT doc FROM a)) AS k
      INTERSECT
      SELECT k
      FROM jsonb_object_keys((SELECT doc FROM b)) AS k
    ) s
    WHERE (SELECT (SELECT doc FROM a)->k) IS DISTINCT FROM (SELECT (SELECT doc FROM b)->k)
  )                        AS changed_keys;

-- Additional note/examples for built-ins:
-- - In the example above, the top-level key "old" was present in A and
--   removed from B, so it will appear under removed_keys.
-- - A nested key was also removed: meta.active (present in A, missing in B).
--   This basic top-level diff does NOT detect nested removals; detecting them
--   requires manual traversal or alternative tooling. See the plv8 and jd-sql
--   sections below for approaches to deep diffs.

-- Show the specific value-level changes for changed keys
WITH a AS (SELECT '{"count":1,"tags":["red","blue"],"meta":{"owner":"dev","active":true}}'::jsonb AS doc),
     b AS (SELECT '{"count":2,"tags":["red","green"],"meta":{"owner":"devops"}}'::jsonb AS doc)
SELECT k AS changed_key,
       (SELECT doc FROM a)->k AS a_val,
       (SELECT doc FROM b)->k AS b_val
FROM (
  SELECT k
  FROM jsonb_object_keys((SELECT doc FROM a)) AS k
  INTERSECT
  SELECT k
  FROM jsonb_object_keys((SELECT doc FROM b)) AS k
) s
WHERE (SELECT (SELECT doc FROM a)->k) IS DISTINCT FROM (SELECT (SELECT doc FROM b)->k)
ORDER BY k;

-- Simple merge using the jsonb concatenation operator (||)
-- Note: For duplicate keys, right-hand side wins. Does not deeply merge arrays/objects.
SELECT (
  '{"a":1, "obj": {"x":1}, "arr":[1,2]}'::jsonb ||
  '{"b":2, "obj": {"y":2}, "arr":[3]}'::jsonb
) AS shallow_merge_result;

-- Targeted updates with jsonb_set; demonstrates partial/deep updates
SELECT jsonb_set(
         jsonb_set('{"obj":{"x":1,"y":2}}'::jsonb, '{obj,x}', '10'::jsonb),
         '{obj,y}', '20'::jsonb, true
       ) AS deep_update_result;

-- Takeaways for built-ins (in short):
-- - You can detect added/removed/changed top-level keys and perform shallow merges with ||.
-- - Deep diffs require manual traversal (CTEs/recursive queries) and quickly become complex.
-- - Array semantics are not handled structurally (e.g., LCS) by built-ins.


-- ================================================================
-- 2) Using only built-in capabilities of plv8
-- ================================================================
-- plv8 enables writing JavaScript functions for JSON manipulation. Below
-- are small illustrative functions for deep diff and deep merge. They are
-- intended as examples, not production-hardened implementations.

-- Enable plv8 in your database (once per DB):
--   CREATE EXTENSION IF NOT EXISTS plv8;

-- Deep merge (objects only; arrays are replaced by right side)
CREATE OR REPLACE FUNCTION plv8_jsonb_deep_merge(a jsonb, b jsonb)
RETURNS jsonb
LANGUAGE plv8
AS $$
  function isObject(x){ return x && x.constructor === Object; }
  function merge(a,b){
    if (isObject(a) && isObject(b)){
      const out = {...a};
      for (const k of Object.keys(b)){
        if (isObject(out[k]) && isObject(b[k])){
          out[k] = merge(out[k], b[k]);
        } else {
          out[k] = b[k];
        }
      }
      return out;
    }
    // Arrays and primitives: right wins (replace)
    return b;
  }
  const aj = (a === null || a === undefined) ? null : a;
  const bj = (b === null || b === undefined) ? null : b;
  if (aj === null) return b;
  if (bj === null) return a;
  return merge(aj, bj);
$$;

-- Minimal deep diff producing a structural map of changes:
-- Output shape: { add: {...}, remove: [paths...], replace: {...} }
CREATE OR REPLACE FUNCTION plv8_jsonb_deep_diff(a jsonb, b jsonb)
RETURNS jsonb
LANGUAGE plv8
AS $$
  function isObject(x){ return x && x.constructor === Object; }
  function diff(a,b,path){
    const out = { add:{}, replace:{}, remove:[] };
    if (isObject(a) && isObject(b)){
      const akeys = Object.keys(a), bkeys = Object.keys(b);
      const aset = new Set(akeys), bset = new Set(bkeys);
      for (const k of bkeys){
        const p = path.concat(k);
        if (!aset.has(k)){
          out.add[p.join('.')]=b[k];
        } else {
          const d = diff(a[k], b[k], p);
          Object.assign(out.add, d.add);
          Object.assign(out.replace, d.replace);
          out.remove.push.apply(out.remove, d.remove);
        }
      }
      for (const k of akeys){
        if (!bset.has(k)) out.remove.push(path.concat(k).join('.'));
      }
    } else {
      // arrays or primitives: if different, mark replace at parent path
      if (JSON.stringify(a) !== JSON.stringify(b)){
        out.replace[path.join('.')] = b;
      }
    }
    return out;
  }
  const aj = (a === null || a === undefined) ? null : a;
  const bj = (b === null || b === undefined) ? null : b;
  return diff(aj, bj, []);
$$;

-- Try it out
\echo '--- plv8 deep merge ---'
select a, b, merged
from (
    values (
        '{"name":"alpha","obj":{"x":1},"arr":[1,2]}'::jsonb,
        '{"obj":{"y":2},"arr":[9],"extra":true}'::jsonb
    )) as       t(a, b)
cross join lateral plv8_jsonb_deep_merge(a,b) as merged;

\echo '--- plv8 deep diff ---'
select a, b, diff
from (
    values (
        '{"name":"alpha","tags":["red","blue"],"meta":{"owner":"dev","active":true}}'::jsonb,
        '{"name":"alpha","tags":["red","green"],"meta":{"owner":"devops"},"extra":"new"}'::jsonb
    )) as       t(a, b)
cross join lateral plv8_jsonb_deep_diff(a,b) as diff;

-- Cleanup (optional)
-- DROP FUNCTION IF EXISTS plv8_jsonb_deep_merge(jsonb, jsonb);
-- DROP FUNCTION IF EXISTS plv8_jsonb_deep_diff(jsonb, jsonb);


-- ================================================================
-- 3) Why jd-sql?
-- ================================================================
-- Placeholder notes (see README for full details):
-- - Human-readable, stable structural diffs designed for code review.
-- - Minimal array diffs using LCS to avoid noisy patches.
-- - Bidirectional: apply and invert patches reliably.
-- - Format translation: structural jd format, RFC 7386 (merge), subset of RFC 6902 (patch).
-- - Path options and type conversion to tailor diffs for operational use.
-- - Designed to avoid accidental data clobber when merging complex JSON.

-- In short, built-ins and plv8 can be used to craft custom behaviors,
-- but it requires non-trivial SQL for each use case. jd-sql provides a
-- single configurable function to generate diffs and patches in jd format.
