-- PostgreSQL PL/pgSQL implementation surface for jd-sql (PL/pgSQL variant).
--
-- License: MIT
-- This file is licensed under the MIT License. See the LICENSE file at
-- github.com/deinspanjer/jd-sql/LICENSE for full license text.
--
-- Copyright (c) 2025 Daniel Einspanjer

-- --------------------------------------------------------------------------------
-- Drop existing objects (dev-friendly)
-- --------------------------------------------------------------------------------
do
$$
    begin
        if exists (select 1
                   from pg_type
                   where typname = 'jd_diff_element') then
            execute 'drop type jd_diff_element cascade';
        end if;
    end
$$;
do
$$
    begin
        if exists (select 1
                   from pg_type
                   where typname = 'jd_metadata') then
            execute 'drop type jd_metadata cascade';
        end if;
    end
$$;
do
$$
    begin
        if exists (select 1
                   from pg_type
                   where typname = 'jd_option') then
            execute 'drop domain jd_option cascade';
        end if;
    end
$$;
do
$$
    begin
        if exists (select 1
                   from pg_type
                   where typname = 'jd_path') then
            execute 'drop domain jd_path cascade';
        end if;
    end
$$;
do
$$
    begin
        if exists (select 1
                   from pg_type
                   where typname = 'jd_patch') then
            execute 'drop domain jd_patch cascade';
        end if;
    end
$$;
do
$$
    begin
        if exists (select 1
                   from pg_type
                   where typname = 'jd_merge') then
            execute 'drop domain jd_merge cascade';
        end if;
    end
$$;
do
$$
    begin
        if exists (select 1
                   from pg_type
                   where typname = 'jd_diff_format') then
            execute 'drop type jd_diff_format cascade';
        end if;
    end
$$;

-- --------------------------------------------------------------------------------
-- Validators
-- --------------------------------------------------------------------------------
create or replace function _jd_validate_options(options jsonb) returns boolean
    language plpgsql
    immutable as
$$
begin
    -- Initial milestone: be permissive; accept any JSON array as options.
    if options is null then return false; end if;
    return jsonb_typeof(options) = 'array';
end
$$;

create or replace function _jd_validate_path(path jsonb) returns boolean
    language plpgsql
    immutable as
$$
declare
    elem jsonb;
    t    text;
begin
    if path is null or jsonb_typeof(path) <> 'array' then return false; end if;
    for elem in select e from jsonb_array_elements(path) as z(e)
        loop
            t := jsonb_typeof(elem);
            if t in ('string', 'number') then continue; end if;
            if t = 'object' then continue; end if;
            if t = 'array' then
                if jsonb_array_length(elem) = 0 then continue; end if;
                if jsonb_array_length(elem) = 1 and jsonb_typeof(elem -> 0) = 'object' then continue; end if;
                return false;
            end if;
            return false;
        end loop;
    return true;
end
$$;

create or replace function _jd_validate_rfc6902(patch jsonb) returns boolean
    language plpgsql
    immutable as
$$
declare
    op jsonb;
    o  text;
begin
    if patch is null or jsonb_typeof(patch) <> 'array' then return false; end if;
    for op in select e from jsonb_array_elements(patch) as z(e)
        loop
            if jsonb_typeof(op) <> 'object' then return false; end if;
            o := op ->> 'op';
            if o not in ('add', 'remove', 'replace', 'move', 'copy', 'test') then return false; end if;
            if (o in ('add', 'replace', 'test')) and not (op ? 'value') then return false; end if;
            if not (op ? 'path') then return false; end if;
        end loop;
    return true;
end
$$;

-- --------------------------------------------------------------------------------
-- Domains and Types
-- --------------------------------------------------------------------------------
create domain jd_option as jsonb check (value is null or _jd_validate_options(value));
create domain jd_path as jsonb check (value is null or _jd_validate_path(value));
create domain jd_patch as jsonb check (value is null or _jd_validate_rfc6902(value));
create domain jd_merge as jsonb check (value is null or jsonb_typeof(value) = 'object');

-- diff format enum (Milestone 6)
create type jd_diff_format as enum ('jd','patch','merge');

create type jd_metadata as
(
    merge boolean
);

create type jd_diff_element as
(
    metadata jd_metadata,
    options  jd_option,
    path     jd_path,
    before   jsonb[],
    remove   jsonb[],
    add      jsonb[],
    after    jsonb[]
);

-- --------------------------------------------------------------------------------
-- Helpers
-- --------------------------------------------------------------------------------
create or replace function _jd_render_json_compact(j jsonb) returns text
    language plpgsql
    immutable as
$$
declare
    t   text;
    out text;
begin
    -- normalize numbers: strip trailing .0 and zeros by casting to numeric then to text
    if j is null then return 'null'; end if;
    if jsonb_typeof(j) = 'number' then
        t := j::text;
        if position('.' in t) > 0 then t := rtrim(rtrim(t, '0'), '.'); end if;
        return t;
    end if;
    -- For non-numbers, render compactly (no spaces after ':' or ',')
    out := j::text;
    out := replace(replace(out, ': ', ':'), ', ', ',');
    return out;
end
$$;

-- option helpers
create or replace function _jd_option_has(options jd_option, name text) returns boolean
    language sql
    immutable as
$$
select exists (select 1
               from jsonb_array_elements(coalesce($1, '[]'::jsonb)) as z(e)
               where (jsonb_typeof(e) = 'string' and e::text = to_jsonb($2)::text)
                  or (jsonb_typeof(e) = 'object' and (e ? lower($2) or e ? $2)))
$$;

create or replace function _jd_option_get_setkeys(options jd_option) returns text[]
    language plpgsql
    immutable as
$$
declare
    e   jsonb;
    out text[] := array []::text[];
    arr jsonb;
    i   int;
begin
    for e in select x from jsonb_array_elements(coalesce(options, '[]'::jsonb)) as t(x)
        loop
            if jsonb_typeof(e) = 'object' and (e ? 'setkeys') then
                arr := e -> 'setkeys';
                if jsonb_typeof(arr) = 'array' then
                    i := 0;
                    while i < jsonb_array_length(arr)
                        loop
                            out := out || (arr ->> i);
                            i := i + 1;
                        end loop;
                end if;
            end if;
        end loop;
    if array_length(out, 1) is null then return null; end if;
    return out;
end
$$;

create or replace function _jd_object_identity(v jsonb, setkeys text[]) returns jsonb
    language plpgsql
    immutable as
$$
declare
    ident jsonb := '{}'::jsonb;
    k     text;
begin
    if v is null or jsonb_typeof(v) <> 'object' then return null; end if;
    if setkeys is null or array_length(setkeys, 1) is null then return null; end if;
    -- ensure deterministic key order: sort keys lexicographically
    for k in select keyname from unnest(setkeys) as t(keyname) order by 1
        loop
            ident := jsonb_set(ident, array [k], v -> k, true);
        end loop;
    return ident;
end
$$;

create or replace function _jd_array_key(v jsonb, setkeys text[]) returns text
    language plpgsql
    immutable as
$$
declare
    ident jsonb;
begin
    if setkeys is not null and jsonb_typeof(v) = 'object' then
        ident := _jd_object_identity(v, setkeys);
        return ident::text;
    else
        return v::text;
    end if;
end
$$;

-- Path helpers for DIFF_ON/DIFF_OFF path gating
create or replace function _jd_path_is_prefix(prefix jsonb, path jsonb) returns boolean
    language plpgsql
    immutable as
$$
declare
    lp int;
    l  int;
    i  int := 0;
begin
    if prefix is null or jsonb_typeof(prefix) <> 'array' then return false; end if;
    if path is null or jsonb_typeof(path) <> 'array' then return false; end if;
    lp := jsonb_array_length(prefix); l := jsonb_array_length(path);
    if lp > l then return false; end if;
    while i < lp
        loop
            if (prefix -> i) is distinct from (path -> i) then return false; end if;
            i := i + 1;
        end loop;
    return true;
end
$$;

-- Compute effective options for a given path by combining global options
-- with path-scoped directives that apply to cur_path. Excludes DIFF_ON/OFF.
create or replace function _jd_effective_options(options jd_option, cur_path jd_path) returns jd_option
    language plpgsql
    immutable as
$$
declare
    e   jsonb;
    out jsonb := '[]'::jsonb;
    dir jsonb;
    atp jsonb;
    d   jsonb;
begin
    if options is null or jsonb_typeof(options) <> 'array' then return '[]'::jsonb; end if;
    -- global entries (no '@'/'^')
    for e in select x from jsonb_array_elements(options) as t(x)
        loop
            if jsonb_typeof(e) = 'string' then
                if e::text in ('"SET"', '"MULTISET"', '"MERGE"') then out := out || jsonb_build_array(e); end if;
            elsif jsonb_typeof(e) = 'object' then
                if (not (e ? '@') and not (e ? '^')) then
                    if (e ? 'setkeys') or (e ? 'precision') then out := out || jsonb_build_array(e); end if;
                end if;
            end if;
        end loop;
    -- path-scoped directives
    for e in select x from jsonb_array_elements(options) as t(x)
        loop
            if jsonb_typeof(e) = 'object' and (e ? '@') and (e ? '^') then
                atp := e -> '@'; dir := e -> '^';
                if jsonb_typeof(atp) = 'array' and jsonb_typeof(dir) = 'array' then
                    if _jd_path_is_prefix(atp, coalesce(cur_path, '[]'::jsonb)) then
                        for d in select x from jsonb_array_elements(dir) as t2(x)
                            loop
                                if jsonb_typeof(d) = 'string' then
                                    if d::text in ('"SET"', '"MULTISET"', '"MERGE"') then
                                        out := out || jsonb_build_array(d);
                                    end if; -- ignore DIFF_ON/OFF
                                elsif jsonb_typeof(d) = 'object' then
                                    if (d ? 'setkeys') or (d ? 'precision') then
                                        out := out || jsonb_build_array(d);
                                    end if;
                                end if;
                            end loop;
                    end if;
                end if;
            end if;
        end loop;
    return out;
end
$$;

create or replace function _jd_diff_allowed(cur_path jd_path, options jd_option) returns boolean
    language plpgsql
    immutable as
$$
declare
    e         jsonb;
    atp       jsonb;
    dir       jsonb;
    on_depth  int     := null;
    off_depth int     := null;
    depth     int;
    on_any    boolean := false;
begin
    -- Default allow when no gating options present
    if options is null or jsonb_typeof(options) <> 'array' then return true; end if;
    for e in select x from jsonb_array_elements(options) as t(x)
        loop
            if jsonb_typeof(e) = 'object' and (e ? '@') and (e ? '^') then
                atp := e -> '@'; dir := e -> '^';
                if jsonb_typeof(atp) = 'array' and jsonb_typeof(dir) = 'array' then
                    -- track presence of any DIFF_ON directives globally
                    if exists(select 1
                              from jsonb_array_elements(dir) d0(x)
                              where jsonb_typeof(d0.x) = 'string' and (d0.x::text) = '"DIFF_ON"') then
                        on_any := true;
                    end if;
                    if _jd_path_is_prefix(atp, coalesce(cur_path, '[]'::jsonb)) then
                        depth := jsonb_array_length(atp);
                        -- scan directives for DIFF_ON/OFF
                        if exists(select 1 from jsonb_array_elements(dir) d(x) where jsonb_typeof(d.x) = 'string'
                                                                                 and (d.x::text) = '"DIFF_ON"') then
                            if on_depth is null or depth > on_depth then on_depth := depth; end if;
                        end if;
                        if exists(select 1 from jsonb_array_elements(dir) d2(x) where jsonb_typeof(d2.x) = 'string'
                                                                                  and (d2.x::text) = '"DIFF_OFF"') then
                            if off_depth is null or depth > off_depth then off_depth := depth; end if;
                        end if;
                    end if;
                end if;
            end if;
        end loop;
    -- If any DIFF_ON directive exists globally, enforce allowlist semantics:
    -- only paths under a DIFF_ON-prefixed entry are allowed unless also explicitly turned off deeper.
    if on_any and on_depth is null then
        -- No matching DIFF_ON prefix for this path; suppress it regardless of DIFF_OFF
        return false;
    end if;
    if on_depth is not null then return true; end if;
    if off_depth is not null then return false; end if;
    return true;
end
$$;

-- --------------------------------------------------------------------------------
-- Public API (struct-first)
-- --------------------------------------------------------------------------------

create or replace function _jd_option_get_precision(options jd_option) returns numeric
    language plpgsql
    immutable as
$$
declare
    e jsonb;
    p jsonb;
begin
    for e in select x from jsonb_array_elements(coalesce(options, '[]'::jsonb)) as t(x)
        loop
            if jsonb_typeof(e) = 'object' and (e ? 'precision') then
                p := e -> 'precision';
                if p is null then continue; end if;
                if jsonb_typeof(p) = 'number' then return (p::text)::numeric; end if;
            end if;
        end loop;
    return null;
end
$$;

create or replace function _jd_numbers_equal(a jsonb, b jsonb, tol numeric) returns boolean
    language plpgsql
    immutable as
$$
declare
    av      numeric;
    bv      numeric;
    eff_tol numeric;
begin
    if jsonb_typeof(a) <> 'number' or jsonb_typeof(b) <> 'number' then return null; end if;
    av := (a::text)::numeric; bv := (b::text)::numeric;
    -- Default tolerance to a small epsilon to smooth floating-point textual variants
    eff_tol := coalesce(tol, 1e-15);
    if eff_tol = 0 then return av = bv; end if;
    return abs(av - bv) <= eff_tol;
end
$$;

create or replace function _jd_json_equal(a jsonb, b jsonb, options jd_option) returns boolean
    language plpgsql
    immutable as
$$
declare
begin
    if a is null and b is null then return true; end if;
    if a is null or b is null then return false; end if;
    if jsonb_typeof(a) = 'number' and jsonb_typeof(b) = 'number' then
        return _jd_numbers_equal(a, b, _jd_option_get_precision(options));
    end if;
    return a is not distinct from b;
end
$$;

create or replace function jd_equal(a jsonb, b jsonb, options jd_option default '[]'::jsonb) returns boolean
    language sql
    stable as
$$
select _jd_json_equal($1, $2, $3)
$$;

-- Internal recursive helper with explicit path
create or replace function _jd_diff_struct(a jsonb, b jsonb, cur_path jd_path, options jd_option, debug bool default false) returns setof jd_diff_element
    language plpgsql
    stable as
$$
declare
    elem     jd_diff_element;
    k        text;
    la       int;
    lb       int;
    i        int;
    p        int;
    s        int;
    wa       int;
    wb       int;
    loc_opts jd_option := _jd_effective_options(options, cur_path);
    is_merge boolean := null; -- effective MERGE option at current path
begin
    if debug then
        raise debug 'jd_diff_struct(%, %, %, %); eq?=%; eff_opts=%', a, b, cur_path, options, _jd_json_equal(a, b, loc_opts), loc_opts;
    end if;
    -- cache effective merge flag for this path
    is_merge := _jd_option_has(loc_opts, 'MERGE');
    if _jd_json_equal(a, b, loc_opts) then return; end if;

    -- Handle void (SQL NULL) on either side as add-only or remove-only at current path
    if a is null or b is null then
        if debug then
            if a is null then
                raise debug 'null-handling at %: a is null, add b', coalesce(cur_path, '[]'::jsonb);
            elsif b is null then
                raise debug 'null-handling at %: b is null, remove a', coalesce(cur_path, '[]'::jsonb);
            end if;
        end if;
        elem.metadata := row (is_merge)::jd_metadata;
        elem.options := coalesce(options, '[]'::jsonb);
        elem.path := coalesce(cur_path, '[]'::jsonb);
        elem.before := null;
        if a is null then
            elem.remove := null;
            elem.add := array [b];
        elsif b is null then
            elem.remove := array [a];
            elem.add := null;
        end if;
        elem.after := null;
        return next elem;
        return;
    end if;

    if jsonb_typeof(a) = 'object' and jsonb_typeof(b) = 'object' then
        if debug then
            raise debug 'object branch at %', coalesce(cur_path, '[]'::jsonb);
        end if;
        -- removals (emit first)
        if debug then
            raise debug 'object removals at %', coalesce(cur_path, '[]'::jsonb);
        end if;
        for k in select key
                 from (select key
                       from jsonb_object_keys(a) as key
                       except
                       select key
                       from jsonb_object_keys(b) as key) s
                 order by 1
            loop
                if debug then
                    raise debug ' - remove key %', k;
                end if;
                elem.metadata := row (is_merge)::jd_metadata;
                elem.options := coalesce(options, '[]'::jsonb);
                elem.path := coalesce(cur_path, '[]'::jsonb) || jsonb_build_array(to_jsonb(k));
                elem.before := null;
                elem.remove := array [a -> k];
                elem.add := null;
                elem.after := null;
                return next elem;
            end loop;

        -- replacements or nested diffs (emit second)
        if debug then
            raise debug 'object common keys (recurse/replace) at %', coalesce(cur_path, '[]'::jsonb);
        end if;
        for k in select key
                 from (select key
                       from jsonb_object_keys(a) as key
                       intersect
                       select key
                       from jsonb_object_keys(b) as key) s
                 order by 1
            loop
                declare
                    child_path jsonb     := coalesce(cur_path, '[]'::jsonb) || jsonb_build_array(to_jsonb(k));
                    child_opts jd_option := _jd_effective_options(options, child_path);
                    child_is_merge boolean := _jd_option_has(child_opts, 'MERGE');
                begin
                    if ((jsonb_typeof(a -> k) = 'object' and jsonb_typeof(b -> k) = 'object') or
                        (jsonb_typeof(a -> k) = 'array' and jsonb_typeof(b -> k) = 'array')) then
                        -- Recurse; deeper level will use its own effective options for equality
                        if debug then
                            raise debug ' - recurse into %', child_path;
                        end if;
                        return query select * from _jd_diff_struct(a -> k, b -> k, child_path, options, debug);
                    else
                        -- Scalars or differing types: decide using child-specific options (e.g., precision)
                        if not _jd_json_equal(a -> k, b -> k, child_opts) then
                            if debug then
                                raise debug ' - replace scalar at % (opts=%)', child_path, child_opts;
                            end if;
                            elem.metadata := row (child_is_merge)::jd_metadata;
                            elem.options := coalesce(options, '[]'::jsonb);
                            elem.path := child_path;
                            elem.before := null;
                            elem.remove := array [a -> k];
                            elem.add := array [b -> k];
                            elem.after := null;
                            return next elem;
                        end if;
                    end if;
                end;
            end loop;

        -- additions (emit last)
        if debug then
            raise debug 'object additions at %', coalesce(cur_path, '[]'::jsonb);
        end if;
        for k in select key
                 from (select key
                       from jsonb_object_keys(b) as key
                       except
                       select key
                       from jsonb_object_keys(a) as key) s
                 order by 1
            loop
                if debug then
                    raise debug ' - add key %', k;
                end if;
                elem.metadata := row (is_merge)::jd_metadata;
                elem.options := coalesce(options, '[]'::jsonb);
                elem.path := coalesce(cur_path, '[]'::jsonb) || jsonb_build_array(to_jsonb(k));
                elem.before := null;
                elem.remove := null;
                elem.add := array [b -> k];
                elem.after := null;
                return next elem;
            end loop;
        return;
    end if;

    if jsonb_typeof(a) = 'array' and jsonb_typeof(b) = 'array' then
        if debug then
            raise debug 'array branch at % (opts=%)', coalesce(cur_path, '[]'::jsonb), loc_opts;
        end if;
        -- If MERGE semantics are enabled at this path, arrays are replaced wholesale
        if _jd_option_has(loc_opts, 'MERGE') then
            if debug then
                raise debug 'array MERGE at %', coalesce(cur_path, '[]'::jsonb);
            end if;
            elem.metadata := row (is_merge)::jd_metadata; -- mark merge semantics awareness
            elem.options := coalesce(options, '[]'::jsonb);
            elem.path := coalesce(cur_path, '[]'::jsonb);
            elem.before := null;
            elem.remove := null;
            elem.add := array [b];
            elem.after := null;
            return next elem;
            return;
        end if;

        -- Option: SET/MULTISET or setkeys for arrays
        if _jd_option_has(loc_opts, 'MULTISET') or _jd_option_has(loc_opts, 'SET') or
           _jd_option_get_setkeys(loc_opts) is not null then
            -- Handle arrays as sets/multisets; for setkeys, treat objects by identity
            declare
                is_multi boolean := _jd_option_has(loc_opts, 'MULTISET');
                setkeys  text[]  := _jd_option_get_setkeys(loc_opts);
                ah       jsonb;
                bh       jsonb; -- element during iteration
                hkey     text; -- hash key
                -- maps stored as temporary jsonb objects mapping key->count or key->jsonb element
                amap     jsonb   := '{}'::jsonb;
                bmap     jsonb   := '{}'::jsonb;
                counts   boolean := is_multi; -- whether to track counts
            begin
                if debug then
                    raise debug 'array set-mode at %: mode=%, setkeys=%', coalesce(cur_path, '[]'::jsonb), case when counts then 'MULTISET' else 'SET' end, setkeys;
                end if;
                -- build amap
                i := 0; la := coalesce(jsonb_array_length(a), 0);
                while i < la
                    loop
                        ah := a -> i; hkey := _jd_array_key(ah, setkeys);
                        if counts then
                            if (amap ? hkey) then
                                amap := jsonb_set(amap, array [hkey], to_jsonb(((amap ->> hkey)::int + 1)), true);
                            else
                                amap := jsonb_set(amap, array [hkey], to_jsonb(1), true);
                            end if;
                        else
                            -- preserve first occurrence for representative when duplicates exist
                            if not (amap ? hkey) then amap := jsonb_set(amap, array [hkey], ah, true); end if;
                        end if;
                        i := i + 1;
                    end loop;
                -- build bmap
                i := 0; lb := coalesce(jsonb_array_length(b), 0);
                while i < lb
                    loop
                        bh := b -> i; hkey := _jd_array_key(bh, setkeys);
                        if counts then
                            if (bmap ? hkey) then
                                bmap := jsonb_set(bmap, array [hkey], to_jsonb(((bmap ->> hkey)::int + 1)), true);
                            else
                                bmap := jsonb_set(bmap, array [hkey], to_jsonb(1), true);
                            end if;
                        else
                            if not (bmap ? hkey) then bmap := jsonb_set(bmap, array [hkey], bh, true); end if;
                        end if;
                        i := i + 1;
                    end loop;
                if debug then
                    raise debug 'built maps at %: |A|=%, |B|=%', coalesce(cur_path, '[]'::jsonb), la, lb;
                end if;

                -- For setkeys and objects present in both, recurse into changed objects
                if setkeys is not null then
                    for hkey in select key
                                from (select key
                                      from jsonb_object_keys(amap) as key
                                      intersect
                                      select key
                                      from jsonb_object_keys(bmap) as key) s
                                order by 1
                        loop
                            ah := amap -> hkey; bh := bmap -> hkey;
                            -- when counts, value is count. fetch real objects from original arrays by searching first match
                            if counts then
                                -- find representative objects for this key from arrays
                                ah := null; bh := null;
                                i := 0;
                                while i < la and ah is null
                                    loop
                                        if _jd_array_key(a -> i, setkeys) = hkey then ah := a -> i; end if; i := i + 1;
                                    end loop;
                                i := 0;
                                while i < lb and bh is null
                                    loop
                                        if _jd_array_key(b -> i, setkeys) = hkey then bh := b -> i; end if; i := i + 1;
                                    end loop;
                            end if;
                            -- For identity-matched objects, emit shallow field replacements for differing scalar fields
                            if ah is distinct from bh then
                                declare
                                    kk    text;
                                    aval  jsonb;
                                    bval  jsonb;
                                    ipath jsonb := coalesce(cur_path, '[]'::jsonb) ||
                                                   jsonb_build_array(_jd_object_identity(ah, setkeys));
                                begin
                                    if debug then
                                        raise debug 'identity match at % key %, checking scalar fields', ipath, hkey;
                                    end if;
                                    for kk in select key
                                              from (select key
                                                    from jsonb_object_keys(ah) as key
                                                    union
                                                    select key
                                                    from jsonb_object_keys(bh) as key) u
                                              order by 1
                                        loop
                                            aval := ah -> kk; bval := bh -> kk;
                                            if aval is null or bval is null then
                                                -- additions/removals at fields are not required by current edge case; skip to keep scope tight
                                                continue;
                                            end if;
                                            if jsonb_typeof(aval) <> 'object' and jsonb_typeof(aval) <> 'array' and
                                               jsonb_typeof(bval) <> 'object' and
                                               jsonb_typeof(bval) <> 'array' and
                                               not _jd_json_equal(aval, bval, loc_opts) then
                                                if debug then
                                                    raise debug ' - field replace at %/%', ipath, kk;
                                                end if;
                                                -- compute effective options for the field path and set merge accordingly
                                                declare
                                                    fld_path jsonb := ipath || jsonb_build_array(to_jsonb(kk));
                                                    fld_opts jd_option := _jd_effective_options(options, fld_path);
                                                    fld_is_merge boolean := _jd_option_has(fld_opts, 'MERGE');
                                                begin
                                                    elem :=
                                                        row (row (fld_is_merge)::jd_metadata, coalesce(options, '[]'::jsonb), fld_path, null, array [aval], array [bval], null);
                                                    return next elem; elem := null;
                                                end;
                                            end if;
                                        end loop;
                                end;
                            end if;
                        end loop;
                    -- handle multiplicity for setkeys: remove extra duplicates in A beyond presence in B
                    declare
                        countsA jsonb := '{}'::jsonb;
                        ca      int;
                        cb      int;
                        need    int;
                    begin
                        -- build counts in A by identity key
                        i := 0;
                        while i < la
                            loop
                                hkey := _jd_array_key(a -> i, setkeys);
                                if (countsA ? hkey) then
                                    countsA := jsonb_set(countsA, array [hkey], to_jsonb(((countsA ->> hkey)::int + 1)),
                                                         true);
                                else
                                    countsA := jsonb_set(countsA, array [hkey], to_jsonb(1), true);
                                end if;
                                i := i + 1;
                            end loop;
                        for hkey in select key from jsonb_object_keys(countsA) as key
                            loop
                                ca := (countsA ->> hkey)::int;
                                cb := case when (bmap ? hkey) then 1 else 0 end; -- presence only for set semantics
                                need := ca - cb;
                                if need > 0 then
                                    if debug then
                                        raise debug ' - multiplicity trim at % key %: removing % extra', coalesce(cur_path, '[]'::jsonb), hkey, need;
                                    end if;
                                    -- remove from the end to match expected index positions
                                    i := la - 1;
                                    while i >= 0 and need > 0
                                        loop
                                            if _jd_array_key(a -> i, setkeys) = hkey then
                                                elem :=
                                                        row (row (is_merge)::jd_metadata, coalesce(options, '[]'::jsonb), coalesce(cur_path, '[]'::jsonb) || jsonb_build_array(to_jsonb(i)), null, array [a -> i], null, null);
                                                return next elem; elem := null;
                                                need := need - 1;
                                            end if;
                                            i := i - 1;
                                        end loop;
                                end if;
                            end loop;
                    end;
                    return; -- completed setkeys handling
                end if;

                -- For MULTISET (bag) or pure SET of scalars (no setkeys), emit removals/additions here and return.
                if counts or setkeys is null then
                    if debug then
                        raise debug 'set/multiset scalar handling at %', coalesce(cur_path, '[]'::jsonb);
                    end if;
                    elem.metadata := row (is_merge)::jd_metadata;
                    elem.options := coalesce(options, '[]'::jsonb);
                    -- path segment differs for SET vs MULTISET
                    if counts then
                        elem.path := coalesce(cur_path, '[]'::jsonb) || jsonb_build_array('[]'::jsonb);
                    else
                        elem.path := coalesce(cur_path, '[]'::jsonb) || jsonb_build_array('{}'::jsonb);
                    end if;
                    elem.before := null; elem.after := null; elem.remove := null; elem.add := null;

                    -- removals
                    for hkey in select key from jsonb_object_keys(amap) as key order by 1
                        loop
                            if counts then
                                declare
                                    ca  int := (amap ->> hkey)::int;
                                    cb  int := coalesce((bmap ->> hkey)::int, 0);
                                    j   int;
                                    val jsonb;
                                begin
                                    if ca > cb then
                                        -- recover value to output
                                        val := null;
                                        if setkeys is not null then
                                            i := 0;
                                            while i < la and val is null
                                                loop
                                                    if _jd_array_key(a -> i, setkeys) = hkey then val := a -> i; end if;
                                                    i := i + 1;
                                                end loop;
                                        else
                                            -- for scalars, key is value::text; rebuild by casting text to jsonb
                                            val := (hkey)::jsonb; -- hkey is text-form JSON
                                        end if;
                                        j := 1;
                                        while j <= (ca - cb)
                                            loop
                                                if elem.remove is null then
                                                    elem.remove := array [val];
                                                else
                                                    elem.remove := array_cat(elem.remove, array [val]);
                                                end if;
                                                j := j + 1;
                                            end loop;
                                    end if;
                                end;
                            else
                                if not (bmap ? hkey) then
                                    -- set scalar removal, collect under [] path
                                    if elem.remove is null then
                                        elem.remove := array [(hkey)::jsonb];
                                    else
                                        elem.remove := array_cat(elem.remove, array [(hkey)::jsonb]);
                                    end if;
                                end if;
                            end if;
                        end loop;

                    -- additions
                    for hkey in select key from jsonb_object_keys(bmap) as key order by 1
                        loop
                            if counts then
                                declare
                                    ca  int := coalesce((amap ->> hkey)::int, 0);
                                    cb  int := (bmap ->> hkey)::int;
                                    j   int;
                                    val jsonb;
                                begin
                                    if cb > ca then
                                        val := null;
                                        if setkeys is not null then
                                            i := 0;
                                            while i < lb and val is null
                                                loop
                                                    if _jd_array_key(b -> i, setkeys) = hkey then val := b -> i; end if;
                                                    i := i + 1;
                                                end loop;
                                        else
                                            val := (hkey)::jsonb;
                                        end if;
                                        j := 1;
                                        while j <= (cb - ca)
                                            loop
                                                if elem.add is null then
                                                    elem.add := array [val];
                                                else
                                                    elem.add := array_cat(elem.add, array [val]);
                                                end if; j := j + 1;
                                            end loop;
                                    end if;
                                end;
                            else
                                if not (amap ? hkey) then
                                    if elem.add is null then
                                        elem.add := array [(hkey)::jsonb];
                                    else
                                        elem.add := array_cat(elem.add, array [(hkey)::jsonb]);
                                    end if;
                                end if;
                            end if;
                        end loop;

                    -- emit combined hunk if present
                    if elem.path is not null and (elem.remove is not null or elem.add is not null) then
                        if debug then
                            raise debug 'emit set/multiset hunk at % (remove=% add=%)', elem.path, coalesce(array_length(elem.remove,1),0), coalesce(array_length(elem.add,1),0);
                        end if;
                        return next elem;
                    end if;
                    return;
                end if;
                -- When setkeys are present (set of objects) we defer multiplicity changes to index-based diff.
            end;
        end if;

        -- index-based array diff with common prefix/suffix trimming
        -- When setkeys are active, all handling is done above; do not fall through to index window logic
        if _jd_option_get_setkeys(loc_opts) is not null then return; end if;
        la := coalesce(jsonb_array_length(a), 0);
        lb := coalesce(jsonb_array_length(b), 0);
        p := 0;
        -- common prefix
        while p < least(la, lb)
            loop
                if not _jd_json_equal(a -> p, b -> p, loc_opts) then exit; end if;
                p := p + 1;
            end loop;
        -- common suffix (avoid overlap with prefix)
        -- When setkeys are active, avoid suffix trimming so trailing multiplicity changes become explicit removals/additions.
        if _jd_option_get_setkeys(loc_opts) is null then
            s := 0; i := 0;
            while (p + s) < la and (p + s) < lb
                loop
                    if not _jd_json_equal(a -> (la - 1 - i), b -> (lb - 1 - i), loc_opts) then exit; end if;
                    s := s + 1; i := i + 1;
                end loop;
        else
            s := 0;
        end if;

        wa := la - p - s; -- window size in a
        wb := lb - p - s; -- window size in b

        if wa = 0 and wb = 0 then
            return; -- arrays equal (should have been caught earlier)
        end if;

        if debug then
            raise debug 'array window at %: p=% s=% wa=% wb=%', coalesce(cur_path, '[]'::jsonb), p, s, wa, wb;
        end if;

        -- Emit a single hunk for the changed window at index p with context before/after
        elem.metadata := row (is_merge)::jd_metadata;
        elem.options := coalesce(options, '[]'::jsonb);
        elem.path := coalesce(cur_path, '[]'::jsonb) || jsonb_build_array(to_jsonb(p));

        -- before context: omit context when setkeys are active; otherwise include previous or OPEN marker
        if _jd_option_get_setkeys(loc_opts) is not null then
            elem.before := null;
        else
            if p > 0 then
                elem.before := array [a -> (p - 1)];
            else
                elem.before := array [to_jsonb('__OPEN__'::text)];
            end if;
        end if;

        -- window removals (all elements in a's window, in order)
        if wa > 0 then
            elem.remove := null; -- build incrementally
            i := p;
            while i <= (p + wa - 1)
                loop
                    if elem.remove is null or array_length(elem.remove, 1) is null then
                        elem.remove := array [a -> i];
                    else
                        elem.remove := array_cat(elem.remove, array [a -> i]);
                    end if;
                    i := i + 1;
                end loop;
        else
            elem.remove := null;
        end if;

        -- window additions (all elements in b's window, in order)
        if wb > 0 then
            elem.add := null;
            i := p;
            while i <= (p + wb - 1)
                loop
                    if elem.add is null or array_length(elem.add, 1) is null then
                        elem.add := array [b -> i];
                    else
                        elem.add := array_cat(elem.add, array [b -> i]);
                    end if;
                    i := i + 1;
                end loop;
        else
            elem.add := null;
        end if;

        -- after context: omit when setkeys are active; else include next element or CLOSE marker
        if _jd_option_get_setkeys(loc_opts) is not null then
            elem.after := null;
        else
            if s > 0 then
                elem.after := array [a -> (la - s)];
            else
                elem.after := array [to_jsonb('__CLOSE__'::text)];
            end if;
        end if;

        return next elem;
        return;
    end if;

    -- Fallback: single hunk at current path
    if debug then
        raise debug 'fallback hunk at %', coalesce(cur_path, '[]'::jsonb);
    end if;
    elem.metadata := row (is_merge)::jd_metadata;
    elem.options := coalesce(options, '[]'::jsonb);
    elem.path := coalesce(cur_path, '[]'::jsonb);
    elem.before := null;
    elem.remove := array [a];
    elem.add := array [b];
    elem.after := null;
    return next elem;
end
$$;

create or replace function jd_diff_struct(a jsonb, b jsonb, options jd_option default '[]'::jsonb) returns setof jd_diff_element
    language plpgsql
    stable as
$$
declare
    opt jd_option := options;
begin
    return query select * from _jd_diff_struct(a, b, '[]'::jsonb, opt) d where _jd_diff_allowed(d.path, opt);
end
$$;

create or replace function jd_render_diff_text(diff_elements jd_diff_element[],
                                               options jd_option default '[]'::jsonb) returns text
    language plpgsql
    stable as
$$
declare
    out       text := '';
    i         int  := 1;
    n         int  := coalesce(array_length(diff_elements, 1), 0);
    e         jd_diff_element;
    v         jsonb;
    path_text text;
    opt       jsonb;
    seg       jsonb;
    j         int;
begin
    -- if no diffs, return empty string (no headers)
    if n = 0 then return ''; end if;
    -- render option header lines if provided and there are diffs
    if options is not null and jsonb_typeof(options) = 'array' and jsonb_array_length(options) > 0 then
        for opt in select x from jsonb_array_elements(options) as t(x)
            loop
                out := out || '^ ' || _jd_render_json_compact(opt) || E'\n';
            end loop;
    end if;
    while i <= n
        loop
            e := diff_elements[i];
            -- render path compactly using compact segment renderer
            if e.path is null or jsonb_typeof(e.path) <> 'array' then
                path_text := '[]';
            else
                path_text := '[';
                j := 0;
                while j < jsonb_array_length(e.path)
                    loop
                        seg := e.path -> j;
                        if j > 0 then path_text := path_text || ','; end if;
                        path_text := path_text || _jd_render_json_compact(seg);
                        j := j + 1;
                    end loop;
                path_text := path_text || ']';
            end if;
            out := out || '@ ' || path_text || E'\n';
            -- optional context before
            if e.before is not null then
                foreach v in array e.before
                    loop
                        if v = to_jsonb('__OPEN__'::text) then
                            out := out || E'[\n';
                        else
                            out := out || '  ' || _jd_render_json_compact(v) || E'\n';
                        end if;
                    end loop;
            end if;
            if e.remove is not null then
                foreach v in array e.remove
                    loop
                        out := out || '- ' || _jd_render_json_compact(v) || E'\n';
                    end loop;
            end if;
            if e.add is not null then
                foreach v in array e.add
                    loop
                        out := out || '+ ' || _jd_render_json_compact(v) || E'\n';
                    end loop;
            end if;
            -- optional context after
            if e.after is not null then
                foreach v in array e.after
                    loop
                        if v = to_jsonb('__CLOSE__'::text) then
                            out := out || E']\n';
                        else
                            out := out || '  ' || _jd_render_json_compact(v) || E'\n';
                        end if;
                    end loop;
            end if;
            i := i + 1;
        end loop;
    return out;
end
$$;

create or replace function jd_diff_text(a jsonb, b jsonb, options jd_option default '[]'::jsonb) returns text
    language plpgsql
    stable as
$$
declare
    elems jd_diff_element[];
begin
    select array_agg(d) into elems from jd_diff_struct(a, b, options) as d;
    if elems is null or array_length(elems, 1) is null then return ''; end if;
    return jd_render_diff_text(elems, options);
end
$$;

-- Milestone 6: format-aware diff wrapper
create or replace function jd_diff(a jsonb, b jsonb, options jd_option,
                                   format jd_diff_format default 'jd') returns jsonb
    language plpgsql
    stable as
$$
declare
    t text;
begin
    if format = 'jd' then
        t := jd_diff_text(a, b, options);
        return to_jsonb(t);
    elsif format = 'patch' then
        return jd_diff_patch(a, b, options);
    elsif format = 'merge' then
        return jd_diff_merge(a, b, options);
    else
        raise exception 'jd_diff: unknown format %', format;
    end if;
end
$$;

-- Note: Only 4-arg jd_diff(a,b,options,format) is supported from Milestone 6 onward.

-- Milestone 6: translation helper stub (jd-involved flows only in this milestone)
create or replace function jd_translate_diff_format(diff_content jsonb, input_format jd_diff_format,
                                                    output_format jd_diff_format) returns jsonb
    language plpgsql
    stable as
$$
declare
    elems jd_diff_element[];
    t     text;
begin
    -- No-op when formats identical
    if input_format = output_format then return diff_content; end if;

    -- Normalize input to struct elements
    if input_format = 'jd' then
        t := _jd_jsonb_string_value(diff_content);
        elems := _jd_read_diff_text(t);
    elsif input_format = 'patch' then
        elems := jd_read_diff_patch(diff_content);
    elsif input_format = 'merge' then
        elems := jd_read_diff_merge(diff_content);
    else
        raise exception 'jd_translate_diff_format: unknown input format %', input_format;
    end if;

    if elems is null or array_length(elems, 1) is null then
        -- empty diff translates to empty in any format
        if output_format = 'jd' then
            return to_jsonb(''::text);
        elsif output_format = 'patch' then
            return '[]'::jsonb;
        elsif output_format = 'merge' then
            return '{}'::jsonb;
        end if;
    end if;

    -- Render to desired output
    if output_format = 'jd' then
        -- include MERGE header when elements originated from merge
        if input_format = 'merge' then
            t := jd_render_diff_text(elems, '[
              "MERGE"
            ]'::jsonb);
        else
            t := jd_render_diff_text(elems, '[]'::jsonb);
        end if;
        return to_jsonb(t);
    elsif output_format = 'patch' then
        return jd_render_diff_patch(elems);
    elsif output_format = 'merge' then
        return jd_render_diff_merge(elems);
    else
        raise exception 'jd_translate_diff_format: unknown output format %', output_format;
    end if;
end
$$;

-- Minimal RFC 6902 applier: supports /key at root for add/remove/replace
create or replace function jd_apply_patch(value jsonb, patch jd_patch) returns jsonb
    language plpgsql
    stable as
$$
declare
    cur jsonb := value;
    op  jsonb;
    o   text;
    p   text;
    key text;
    val jsonb;
begin
    if jsonb_typeof(patch) <> 'array' then raise exception 'jd_apply_patch expects array'; end if;
    for op in select e from jsonb_array_elements(patch) as z(e)
        loop
            o := op ->> 'op'; p := op ->> 'path'; val := op -> 'value';
            if p is null or left(p, 1) <> '/' or position('/' in substr(p, 2)) > 0 then
                raise exception 'unsupported path % (only /key supported)', p;
            end if;
            key := substr(p, 2);
            if o = 'remove' then
                if jsonb_typeof(cur) <> 'object' then raise exception 'remove requires object root'; end if;
                cur := cur - key;
            elsif o = 'add' or o = 'replace' then
                if jsonb_typeof(cur) <> 'object' then raise exception '% requires object root', o; end if;
                cur := jsonb_set(cur, array [key], val, true);
            else
                raise exception 'unsupported op %', o;
            end if;
        end loop;
    return cur;
end
$$;

-- --------------------------------------------------------------------------------
-- Remaining API stubs (to be implemented in later milestones)
-- --------------------------------------------------------------------------------
-- Path helper: convert jd_path (jsonb array) to RFC6901 pointer
create or replace function _jd_path_to_pointer(path jd_path) returns text
    language plpgsql
    immutable as
$$
declare
    i   int  := 0;
    n   int;
    out text := '';
    v   jsonb;
    seg text;
begin
    n := coalesce(jsonb_array_length(path), 0);
    while i < n
        loop
            v := path -> i;
            if jsonb_typeof(v) = 'string' then
                seg := v::text;
                seg := substr(seg, 2, length(seg) - 2);
                seg := replace(replace(seg, '~', '~0'), '/', '~1');
                out := out || '/' || seg;
            elsif jsonb_typeof(v) = 'number' then
                out := out || '/' || (v::text);
            else
                out := out || '/' || replace(replace(v::text, '~', '~0'), '/', '~1');
            end if;
            i := i + 1;
        end loop;
    return out;
end
$$;

-- Render RFC 6902 JSON Patch from diff struct
create or replace function jd_render_diff_patch(diff_elements jd_diff_element[]) returns jd_patch
    language plpgsql
    stable as
$$
declare
    ops           jsonb := '[]'::jsonb;
    i             int   := 1;
    n             int   := coalesce(array_length(diff_elements, 1), 0);
    e             jd_diff_element;
    p             text;
    last          jsonb;
    last_is_index boolean;
    j             int;
    cnt           int;
begin
    while i <= n
        loop
            e := diff_elements[i];
            p := _jd_path_to_pointer(e.path);
            if coalesce(jsonb_array_length(e.path), 0) > 0 then
                last := e.path -> (jsonb_array_length(e.path) - 1);
                last_is_index := (jsonb_typeof(last) = 'number');
            else
                last_is_index := false;
            end if;

            if e.before is null and e.after is null then
                if e.remove is not null and e.add is not null and array_length(e.remove, 1) = 1 and
                   array_length(e.add, 1) = 1 then
                    -- emit test + remove + add (upstream format expectations)
                    ops := ops || jsonb_build_array(jsonb_build_object('op', 'test', 'path', p, 'value', e.remove[1]));
                    ops := ops ||
                           jsonb_build_array(jsonb_build_object('op', 'remove', 'path', p, 'value', e.remove[1]));
                    ops := ops || jsonb_build_array(jsonb_build_object('op', 'add', 'path', p, 'value', e.add[1]));
                elsif e.remove is not null and array_length(e.remove, 1) = 1 and e.add is null then
                    ops := ops || jsonb_build_array(jsonb_build_object('op', 'test', 'path', p, 'value', e.remove[1]));
                    ops := ops ||
                           jsonb_build_array(jsonb_build_object('op', 'remove', 'path', p, 'value', e.remove[1]));
                elsif e.add is not null and array_length(e.add, 1) = 1 and e.remove is null then
                    ops := ops || jsonb_build_array(jsonb_build_object('op', 'add', 'path', p, 'value', e.add[1]));
                end if;
            else
                if last_is_index then
                    -- deletions at index path
                    if e.remove is not null and array_length(e.remove, 1) is not null then
                        cnt := array_length(e.remove, 1);
                        j := 1;
                        while j <= cnt
                            loop
                                ops := ops ||
                                       jsonb_build_array(jsonb_build_object('op', 'test', 'path', p, 'value', e.remove[j]));
                                ops := ops ||
                                       jsonb_build_array(jsonb_build_object('op', 'remove', 'path', p, 'value', e.remove[j]));
                                j := j + 1;
                            end loop;
                    end if;
                    -- additions at index path (append if e.after indicates close and not a replacement)
                    if e.add is not null and array_length(e.add, 1) is not null then
                        cnt := array_length(e.add, 1); j := 1;
                        while j <= cnt
                            loop
                                -- If this hunk also has removals, treat as in-place replacements at index path
                                if e.remove is not null and array_length(e.remove, 1) is not null then
                                    ops := ops ||
                                           jsonb_build_array(jsonb_build_object('op', 'add', 'path', p, 'value', e.add[j]));
                                elsif e.after is not null and array_length(e.after, 1) is not null and
                                      e.after[1] = to_jsonb('__CLOSE__'::text) then
                                    ops := ops || jsonb_build_array(jsonb_build_object('op', 'add', 'path',
                                                                                       coalesce(nullif(p, ''), '') ||
                                                                                       '/-', 'value', e.add[j]));
                                else
                                    ops := ops ||
                                           jsonb_build_array(jsonb_build_object('op', 'add', 'path', p, 'value', e.add[j]));
                                end if;
                                j := j + 1;
                            end loop;
                    end if;
                end if;
            end if;
            i := i + 1;
        end loop;
    return ops;
end
$$;

create or replace function jd_diff_patch(a jsonb, b jsonb, options jd_option default '[]'::jsonb) returns jd_patch
    language plpgsql
    stable as
$$
declare
    elems jd_diff_element[];
begin
    select array_agg(d) into elems from jd_diff_struct(a, b, options) as d;
    if elems is null or array_length(elems, 1) is null then return '[]'::jsonb; end if;
    return jd_render_diff_patch(elems);
end
$$;

-- Render RFC 7386 Merge Patch from diff struct (objects only at leaf keys)
-- For array element diffs, RFC 7386 semantics require replacing the entire array.
create or replace function jd_render_diff_merge(diff_elements jd_diff_element[]) returns jd_merge
    language plpgsql
    stable as
$$
declare
    out jsonb := '{}'::jsonb;
    i   int   := 1;
    n   int   := coalesce(array_length(diff_elements, 1), 0);
    e   jd_diff_element;
begin
    while i <= n
        loop
            e := diff_elements[i];
            if coalesce(jsonb_array_length(e.path), 0) = 0 then
                -- root-level replacement under merge semantics
                if e.add is not null and array_length(e.add, 1) = 1 then
                    out := e.add[1];
                end if;
            elsif jsonb_typeof(e.path -> (jsonb_array_length(e.path) - 1)) = 'string' then
                -- Treat presence of an add value as a replacement/addition regardless of remove presence
                if e.add is not null and array_length(e.add, 1) = 1 then
                    out := jsonb_set(out, (select array_agg(val)
                                           from jsonb_array_elements_text(e.path) t(val)), e.add[1], true);
                elsif e.remove is not null and array_length(e.remove, 1) = 1 and e.add is null then
                    out := jsonb_set(out, (select array_agg(val)
                                           from jsonb_array_elements_text(e.path) t(val)), 'null'::jsonb, true);
                end if;
            else
                -- Non-string terminal (arrays/indices) do not directly contribute to merge object; skip
                null;
            end if;
            i := i + 1;
        end loop;
    return out;
end
$$;

-- Compute RFC 7386 (JSON Merge Patch)
create or replace function jd_diff_merge(a jsonb, b jsonb, options jd_option default '["MERGE"]'::jsonb) returns jd_merge
    language plpgsql
    stable as
$$
declare
    elems   jd_diff_element[];
    eff_opt jd_option := (coalesce(options, '[]'::jsonb) || '["MERGE"]'::jsonb);
begin
    -- Imply MERGE semantics when rendering merge format regardless of caller options
    select array_agg(d) into elems from jd_diff_struct(a, b, eff_opt) as d;
    if elems is null or array_length(elems, 1) is null then return '{}'::jsonb; end if;
    return jd_render_diff_merge(elems);
end
$$;

-- Apply struct elements (objects at leaf keys)
create or replace function jd_patch_struct(value jsonb, diff_elements jd_diff_element[]) returns jsonb
    language plpgsql
    stable as
$$
declare
    cur           jsonb := value;
    i             int   := 1;
    n             int   := coalesce(array_length(diff_elements, 1), 0);
    e             jd_diff_element;
    last          jsonb;
    idx           int;
    parent_path   text[];
    full_path     text[];
    arr           jsonb;
    prev_expected jsonb;
    next_expected jsonb;
    prev_actual   jsonb;
    next_actual   jsonb;
    v             jsonb;
begin
    while i <= n
        loop
            e := diff_elements[i];
            if coalesce(jsonb_array_length(e.path), 0) = 0 then
                if e.add is not null and array_length(e.add, 1) = 1 then cur := e.add[1]; end if;
            elsif jsonb_typeof(e.path -> (jsonb_array_length(e.path) - 1)) = 'string' then
                if e.add is not null and array_length(e.add, 1) = 1 then
                    cur := jsonb_set(cur, (select array_agg(val)
                                           from jsonb_array_elements_text(e.path) t(val)), e.add[1], true);
                elsif e.remove is not null and e.add is null then
                    -- set null then remove if top-level
                    cur := jsonb_set(cur, (select array_agg(val)
                                           from jsonb_array_elements_text(e.path) t(val)), 'null'::jsonb, true);
                    if jsonb_array_length(e.path) = 1 then cur := cur - (e.path ->> 0); end if;
                end if;
            elsif jsonb_typeof(e.path -> (jsonb_array_length(e.path) - 1)) = 'number' then
                -- Array index context: support in-place replacement with optional simple context checks
                last := e.path -> (jsonb_array_length(e.path) - 1);
                idx := (last::text)::int;
                -- zero-based index
                -- Build full and parent paths as text[]
                select array_agg(val) into full_path from jsonb_array_elements_text(e.path) t(val);
                if jsonb_array_length(e.path) > 1 then
                    select array_agg(val)
                    into parent_path
                    from jsonb_array_elements_text(e.path - (jsonb_array_length(e.path) - 1)) t(val);
                else
                    parent_path := array []::text[];
                end if;
                -- Extract current array at parent
                if array_length(parent_path, 1) is null or array_length(parent_path, 1) = 0 then
                    arr := cur;
                else
                    arr := cur #> parent_path;
                end if;
                if jsonb_typeof(arr) <> 'array' then
                    raise exception 'jd_patch_struct: expected array at %, got %', parent_path, jsonb_typeof(arr);
                end if;
                -- Optional context: last non-marker from before serves as previous element expectation
                prev_expected := null;
                if e.before is not null and array_length(e.before, 1) is not null then
                    foreach v in array e.before
                        loop
                            if v <> to_jsonb('__OPEN__'::text) then prev_expected := v; end if;
                        end loop;
                end if;
                next_expected := null;
                if e.after is not null and array_length(e.after, 1) is not null then
                    foreach v in array e.after
                        loop
                            if v <> to_jsonb('__CLOSE__'::text) then
                                if next_expected is null then next_expected := v; end if;
                            end if;
                        end loop;
                end if;
                -- Actual neighbors
                if idx > 0 then prev_actual := arr -> (idx - 1); else prev_actual := null; end if;
                if (idx + 1) < coalesce((arr ->> '#')::int, jsonb_array_length(arr)) then
                    next_actual := arr -> (idx + 1);
                else
                    next_actual := null;
                end if;
                if prev_expected is not null and prev_actual is not null and prev_actual <> prev_expected then
                    raise exception 'jd_patch_struct: context mismatch before index %: expected %, got %', idx, prev_expected, prev_actual;
                end if;
                if next_expected is not null and next_actual is not null and next_actual <> next_expected then
                    raise exception 'jd_patch_struct: context mismatch after index %: expected %, got %', idx, next_expected, next_actual;
                end if;
                -- Replacement: require remove match when provided
                if e.remove is not null and array_length(e.remove, 1) is not null then
                    if (cur #> full_path) <> e.remove[1] then
                        raise exception 'jd_patch_struct: value mismatch at index %', idx;
                    end if;
                end if;
                if e.add is not null and array_length(e.add, 1) is not null then
                    -- Use create_missing=true to ensure array element is updated
                    cur := jsonb_set(cur, full_path, e.add[1], true);
                elsif e.remove is not null and (e.add is null or array_length(e.add, 1) is null) then
                    -- pure removal at index: rebuild array without element at idx
                    declare
                        j      int   := 0;
                        newarr jsonb := '[]'::jsonb;
                        len    int;
                        elem   jsonb;
                    begin
                        len := jsonb_array_length(arr);
                        while j < len
                            loop
                                if j <> idx then
                                    elem := arr -> j;
                                    newarr := newarr || jsonb_build_array(elem);
                                end if;
                                j := j + 1;
                            end loop;
                        if array_length(parent_path, 1) is null or array_length(parent_path, 1) = 0 then
                            cur := newarr;
                        else
                            cur := jsonb_set(cur, parent_path, newarr, false);
                        end if;
                    end;
                end if;
            end if;
            i := i + 1;
        end loop;
    return cur;
end
$$;

-- Apply RFC 7386 JSON Merge Patch
create or replace function jd_apply_merge(target jsonb, patch jd_merge) returns jsonb
    language plpgsql
    stable as
$$
declare
    result jsonb := target;
    k      text;
    v      jsonb;
    cur    jsonb;
begin
    -- If patch is not an object, the result is the patch itself
    if patch is null or jsonb_typeof(patch) <> 'object' then
        return patch;
    end if;

    -- If target is not an object, treat it as an empty object
    if result is null or jsonb_typeof(result) <> 'object' then
        result := '{}'::jsonb;
    end if;

    for k, v in select key, value from jsonb_each(patch)
        loop
            if v is null or v = 'null'::jsonb then
                -- remove key if present
                result := result - k;
            elsif jsonb_typeof(v) = 'object' then
                -- recursively merge objects
                cur := result -> k;
                result := jsonb_set(result, array [k], jd_apply_merge(cur, v), true);
            else
                -- arrays and scalars replace
                result := jsonb_set(result, array [k], v, true);
            end if;
        end loop;

    return result;
end
$$;

-- Parse jd native diff text into structured elements (array form)
create or replace function _jd_read_diff_text(diff_text text) returns jd_diff_element[]
    language plpgsql
    stable as
$$
declare
    lines       text[]            := string_to_array(coalesce(diff_text, ''), E'\n');
    i           int               := 1;
    n           int               := coalesce(array_length(lines, 1), 0);
    cur         jd_diff_element;
    out         jd_diff_element[] := array []::jd_diff_element[];
    opts        jsonb             := '[]'::jsonb;
    line        text;
    trimmed     text;
    val         jsonb;
    started     boolean           := false; -- saw a header '@'
    has_changes boolean           := false; -- saw +/- line
begin
    while i <= n
        loop
            line := lines[i];
            -- skip empty lines (e.g., trailing newline)
            if line is null or line = '' then i := i + 1; continue; end if;

            if left(line, 2) = '^ ' then
                -- option line before first hunk
                val := (substr(line, 3))::jsonb;
                opts := opts || jsonb_build_array(val);
            elsif left(line, 2) = '@ ' then
                -- finalize previous element if any
                if started then
                    if cur.options is null then cur.options := opts; end if;
                    out := out || array [cur];
                end if;
                -- start new element
                started := true; has_changes := false;
                cur.metadata := row (false)::jd_metadata;
                cur.options := opts; -- capture global options into element
                cur.path := (substr(line, 3))::jsonb; -- path is compact JSON array
                cur.before := null; cur.remove := null; cur.add := null; cur.after := null;
            elsif left(line, 2) = '- ' then
                val := (substr(line, 3))::jsonb;
                if cur.remove is null then
                    cur.remove := array [val];
                else
                    cur.remove := cur.remove || array [val];
                end if;
                has_changes := true;
            elsif left(line, 2) = '+ ' then
                val := (substr(line, 3))::jsonb;
                if cur.add is null then cur.add := array [val]; else cur.add := cur.add || array [val]; end if;
                has_changes := true;
            else
                -- context lines: either '[' or ']' or '  <json>'
                trimmed := btrim(line);
                if trimmed = '[' then
                    val := to_jsonb('__OPEN__'::text);
                elsif trimmed = ']' then
                    val := to_jsonb('__CLOSE__'::text);
                else
                    -- expect two-space indent followed by compact json
                    if left(line, 2) = '  ' then
                        val := (substr(line, 3))::jsonb;
                    else
                        raise exception 'Invalid diff text line (expected context with two-space indent): %', line;
                    end if;
                end if;
                if not has_changes then
                    if cur.before is null then
                        cur.before := array [val];
                    else
                        cur.before := cur.before || array [val];
                    end if;
                else
                    if cur.after is null then
                        cur.after := array [val];
                    else
                        cur.after := cur.after || array [val];
                    end if;
                end if;
            end if;
            i := i + 1;
        end loop;
    if started then
        if cur.options is null then cur.options := opts; end if;
        out := out || array [cur];
    end if;
    return out;
end
$$;

create or replace function jd_read_diff_text(diff_text text) returns setof jd_diff_element
    language plpgsql
    stable as
$$
declare
    arr jd_diff_element[];
    e   jd_diff_element;
begin
    arr := _jd_read_diff_text(diff_text);
    if arr is null or array_length(arr, 1) is null then return; end if;
    foreach e in array arr
        loop
            return next e;
        end loop;
end
$$;

-- Helpers for translation/parsing
create or replace function _jd_jsonb_string_value(j jsonb) returns text
    language plpgsql
    immutable as
$$
declare
    t text;
begin
    if j is null then return null; end if;
    if jsonb_typeof(j) <> 'string' then raise exception 'Expected JSON string content for jd format'; end if;
    t := j::text; -- quoted JSON string
    t := substr(t, 2, greatest(0, length(t) - 2));
    return _jd_unescape_json_string(t);
end
$$;

-- Unescape JSON string escapes to raw text (handles \n, \r, \t, \", \\)
create or replace function _jd_unescape_json_string(s text) returns text
    language plpgsql
    immutable as
$$
declare
    r text := s;
begin
    if r is null then return null; end if;
    -- First collapse escaped backslashes
    r := replace(r, E'\\\\', E'\\');
    -- Then unescape quotes and control sequences
    r := replace(r, E'\\"', E'"');
    r := replace(r, E'\\n', E'\n');
    r := replace(r, E'\\r', E'\r');
    r := replace(r, E'\\t', E'\t');
    return r;
end
$$;

create or replace function _jd_pointer_to_path(pointer text) returns jd_path
    language plpgsql
    immutable as
$$
declare
    parts text[];
    i     int   := 1;
    n     int;
    seg   text;
    out   jsonb := '[]'::jsonb;
    num   numeric;
begin
    if pointer is null or pointer = '' then return '[]'::jsonb; end if;
    if left(pointer, 1) <> '/' then raise exception 'Invalid JSON Pointer: %', pointer; end if;
    parts := string_to_array(substr(pointer, 2), '/');
    n := coalesce(array_length(parts, 1), 0);
    while i <= n
        loop
            seg := replace(replace(parts[i], '~1', '/'), '~0', '~');
            begin
                num := seg::numeric;
                out := out || to_jsonb(num);
            exception
                when others then out := out || to_jsonb(seg);
            end;
            i := i + 1;
        end loop;
    return out;
end
$$;

-- Parse RFC 6902 JSON Patch into jd_diff_element[]
create or replace function jd_read_diff_patch(patch jd_patch) returns jd_diff_element[]
    language plpgsql
    stable as
$$
declare
    ops jsonb;
    op  jsonb;
    out jd_diff_element[] := array []::jd_diff_element[];
    cur jd_diff_element;
    p   text;
begin
    if patch is null or jsonb_typeof(patch) <> 'array' then return null; end if;
    ops := patch;
    for op in select e from jsonb_array_elements(ops) as z(e)
        loop
            p := op ->> 'path';
            cur.metadata := row (false)::jd_metadata;
            cur.options := '[]'::jsonb;
            cur.path := _jd_pointer_to_path(p);
            cur.before := null; cur.after := null; cur.remove := null; cur.add := null;
            if op ->> 'op' = 'add' then
                cur.add := array [op -> 'value'];
                out := out || array [cur];
            elsif op ->> 'op' = 'remove' then
                if op ? 'value' then
                    cur.remove := array [op -> 'value'];
                else
                    cur.remove := array ['null'::jsonb];
                end if;
                out := out || array [cur];
            elsif op ->> 'op' = 'replace' then
                if op ? 'value' then cur.add := array [op -> 'value']; end if;
                -- replacement without prior value: represent as add only
                out := out || array [cur];
            else
                -- ignore test/copy/move for translation into jd text
                continue;
            end if;
        end loop;
    return out;
end
$$;

-- Parse RFC 7386 Merge Patch into jd_diff_element[]
create or replace function jd_read_diff_merge(merge jd_merge) returns jd_diff_element[]
    language plpgsql
    stable as
$$
declare
    k    text;
    v    jsonb;
    cur  jd_diff_element;
    out  jd_diff_element[] := array []::jd_diff_element[];
    keys text[] := array []::text[];
    i    int := 1;
    n    int;
    sub  jd_diff_element[];
    se   jd_diff_element;
begin
    if merge is null or jsonb_typeof(merge) <> 'object' then return null; end if;
    -- Collect and sort keys for deterministic order
    select array_agg(key order by key) into keys from jsonb_each(merge);
    n := coalesce(array_length(keys, 1), 0);
    while i <= n loop
        k := keys[i];
        v := merge -> k;
        if v is null or v = 'null'::jsonb then
            cur.metadata := row (false)::jd_metadata;
            cur.options := '[]'::jsonb;
            cur.path := jsonb_build_array(to_jsonb(k));
            cur.before := null; cur.after := null; cur.remove := array ['null'::jsonb]; cur.add := null;
            out := out || array [cur];
        elsif jsonb_typeof(v) = 'object' then
            -- recurse into nested object to produce leaf hunks
            sub := jd_read_diff_merge(v);
            if sub is not null and array_length(sub, 1) is not null then
                foreach se in array sub
                    loop
                        -- prefix the path with current key
                        se.path := jsonb_build_array(to_jsonb(k)) || coalesce(se.path, '[]'::jsonb);
                        out := out || array [se];
                    end loop;
            end if;
        else
            -- scalar or array replacement at this key
            cur.metadata := row (false)::jd_metadata;
            cur.options := '[]'::jsonb;
            cur.path := jsonb_build_array(to_jsonb(k));
            cur.before := null; cur.after := null; cur.remove := null; cur.add := array [v];
            out := out || array [cur];
        end if;
        i := i + 1;
    end loop;
    return out;
end
$$;

-- Apply jd native diff text to a JSONB value via struct applier
create or replace function jd_patch_text(value jsonb, diff_text text) returns jsonb
    language plpgsql
    stable as
$$
declare
    elems jd_diff_element[];
begin
    elems := _jd_read_diff_text(diff_text);
    if elems is null or array_length(elems, 1) is null then return value; end if;
    return jd_patch_struct(value, elems);
end
$$;
