


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "private";


ALTER SCHEMA "private" OWNER TO "postgres";


COMMENT ON SCHEMA "private" IS 'Jenova internals: trigger functions and guards. Not exposed through the Data API.';



COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "unaccent" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE TYPE "public"."activity_verb" AS ENUM (
    'created',
    'filed',
    'status_changed',
    'committed',
    'cut',
    'consolidated',
    'sealed',
    'unsealed',
    'edited_after_seal',
    'commented',
    'assigned',
    'proposal_accepted',
    'proposal_dismissed',
    'proposal_merged',
    'source_added',
    'file_added',
    'space_created',
    'kind_changed',
    'dependency_added'
);


ALTER TYPE "public"."activity_verb" OWNER TO "postgres";


CREATE TYPE "public"."actor_via" AS ENUM (
    'app',
    'claude',
    'github'
);


ALTER TYPE "public"."actor_via" OWNER TO "postgres";


CREATE TYPE "public"."created_via" AS ENUM (
    'app',
    'claude',
    'import'
);


ALTER TYPE "public"."created_via" OWNER TO "postgres";


CREATE TYPE "public"."doc_state" AS ENUM (
    'draft',
    'sealed'
);


ALTER TYPE "public"."doc_state" OWNER TO "postgres";


CREATE TYPE "public"."file_role" AS ENUM (
    'inline',
    'attachment'
);


ALTER TYPE "public"."file_role" OWNER TO "postgres";


CREATE TYPE "public"."file_status" AS ENUM (
    'pending',
    'ready'
);


ALTER TYPE "public"."file_status" OWNER TO "postgres";


CREATE TYPE "public"."idea_status" AS ENUM (
    'to_discuss',
    'maybe',
    'committed',
    'cut',
    'consolidated'
);


ALTER TYPE "public"."idea_status" OWNER TO "postgres";


CREATE TYPE "public"."item_kind" AS ENUM (
    'idea',
    'task',
    'doc'
);


ALTER TYPE "public"."item_kind" OWNER TO "postgres";


CREATE TYPE "public"."link_type" AS ENUM (
    'depends_on',
    'relates_to'
);


ALTER TYPE "public"."link_type" OWNER TO "postgres";


CREATE TYPE "public"."proposal_confidence" AS ENUM (
    'explicit',
    'discussed',
    'inferred'
);


ALTER TYPE "public"."proposal_confidence" OWNER TO "postgres";


CREATE TYPE "public"."proposal_state" AS ENUM (
    'pending',
    'accepted',
    'dismissed',
    'merged'
);


ALTER TYPE "public"."proposal_state" OWNER TO "postgres";


CREATE TYPE "public"."source_origin" AS ENUM (
    'whatsapp',
    'discord',
    'meeting',
    'craft',
    'other'
);


ALTER TYPE "public"."source_origin" OWNER TO "postgres";


CREATE TYPE "public"."task_status" AS ENUM (
    'todo',
    'in_progress',
    'blocked',
    'done'
);


ALTER TYPE "public"."task_status" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."check_idea_rules"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
declare
  v_item public.items;
  v_doc public.items;
begin
  select * into v_item from public.items i where i.id = new.item_id;

  if new.status is not null and v_item.space_id is null then
    raise exception 'JNV-% is in the inbox: file it into a space before giving it a status.', v_item.number;
  end if;
  if new.status is null and v_item.space_id is not null then
    raise exception 'JNV-% is in a space, so it needs a status.', v_item.number;
  end if;

  if new.status = 'cut' then
    if coalesce(btrim(new.cut_reason), '') = '' then
      raise exception 'An idea can only be cut with a reason (JNV-%).', v_item.number;
    end if;
    if cardinality(new.decided_by) = 0 then
      raise exception 'Cutting an idea needs who agreed (decided_by) (JNV-%).', v_item.number;
    end if;
  elsif new.status = 'committed' then
    if cardinality(new.decided_by) = 0 then
      raise exception 'Committing an idea needs who agreed (decided_by) (JNV-%).', v_item.number;
    end if;
  elsif new.status = 'consolidated' then
    if new.consolidated_into is null then
      raise exception 'A consolidated idea must point to the doc it was folded into (JNV-%).', v_item.number;
    end if;
  end if;

  if new.consolidated_into is not null then
    if new.status is distinct from 'consolidated' then
      raise exception 'Only a consolidated idea points to a doc (JNV-%).', v_item.number;
    end if;
    select * into v_doc from public.items i where i.id = new.consolidated_into;
    if v_doc.space_id is distinct from v_item.space_id then
      raise exception 'JNV-% can only be consolidated into a doc in its own space (JNV-% is elsewhere).', v_item.number, v_doc.number;
    end if;
  end if;

  -- Only when the list is written: a decider who later leaves the studio mustn't freeze the idea.
  if (tg_op = 'INSERT' or new.decided_by is distinct from old.decided_by)
     and exists (select unnest(new.decided_by) except select m.id from public.members m) then
    raise exception 'Who agreed (decided_by) can only list studio members (JNV-%).', v_item.number;
  end if;

  if new.status in ('committed', 'cut') and new.decided_at is null then
    new.decided_at := now();
  end if;

  return new;
end;
$$;


ALTER FUNCTION "private"."check_idea_rules"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."check_item_has_one_kind_row"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
declare
  v_id uuid;
  v_item public.items;
  v_rows integer;
begin
  if tg_table_name = 'items' then
    v_id := new.id;
  else
    v_id := old.item_id;
  end if;

  select * into v_item from public.items i where i.id = v_id;
  if not found then
    return null; -- the item itself is gone
  end if;

  select (select count(*) from public.ideas where item_id = v_id)
       + (select count(*) from public.tasks where item_id = v_id)
       + (select count(*) from public.docs where item_id = v_id)
    into v_rows;

  if v_rows <> 1 then
    raise exception 'Every item needs exactly one kind row: JNV-% (%) has %.', v_item.number, v_item.kind, v_rows
      using hint = 'Create items with capture_item() and change kinds with change_kind().';
  end if;
  return null;
end;
$$;


ALTER FUNCTION "private"."check_item_has_one_kind_row"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."check_item_link"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
declare
  v_from public.items;
  v_to public.items;
begin
  select * into v_from from public.items i where i.id = new.from_item;
  select * into v_to from public.items i where i.id = new.to_item;

  if new.from_item = new.to_item then
    raise exception 'An item can''t link to itself (JNV-%).', v_from.number;
  end if;

  if new.type = 'relates_to' then
    if exists (
      select 1 from public.item_links l
      where l.type = 'relates_to'
        and ((l.from_item = new.from_item and l.to_item = new.to_item) or (l.from_item = new.to_item and l.to_item = new.from_item))
    ) then
      raise exception 'JNV-% and JNV-% are already linked.', v_from.number, v_to.number;
    end if;
    return new;
  end if;

  -- depends_on
  if v_from.kind <> 'task' or v_to.kind <> 'task' then
    raise exception 'Dependencies are only between tasks: JNV-% is %.',
      case when v_from.kind <> 'task' then v_from.number else v_to.number end,
      private.kind_label(case when v_from.kind <> 'task' then v_from.kind else v_to.kind end);
  end if;

  -- Serialise dependency writes so two concurrent inserts can't close a cycle together.
  perform pg_advisory_xact_lock(hashtext('jenova.item_links.depends_on'));

  if exists (
    with recursive downstream (item_id) as (
      select new.to_item
      union
      select l.to_item
      from public.item_links l
      join downstream d on l.from_item = d.item_id
      where l.type = 'depends_on'
    )
    select 1 from downstream where item_id = new.from_item
  ) then
    raise exception 'JNV-% can''t depend on JNV-%: JNV-% already depends on JNV-% (directly or through other tasks), which would make a cycle.',
      v_from.number, v_to.number, v_to.number, v_from.number;
  end if;

  return new;
end;
$$;


ALTER FUNCTION "private"."check_item_link"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."check_item_write"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
declare
  v_ref bigint;
begin
  if coalesce(btrim(new.title), '') = '' then
    raise exception 'An item needs a title';
  end if;

  if tg_op = 'UPDATE' and new.kind <> old.kind then
    if old.kind = 'task' then
      select i.number into v_ref
      from public.item_links l
      join public.items i on i.id = case when l.from_item = old.id then l.to_item else l.from_item end
      where l.type = 'depends_on' and (l.from_item = old.id or l.to_item = old.id)
      limit 1;
      if found then
        raise exception 'JNV-% has dependencies with JNV-%. Remove them before changing its kind.', old.number, v_ref;
      end if;
    elsif old.kind = 'idea' then
      select i.number into v_ref
      from public.tasks t join public.items i on i.id = t.item_id
      where t.origin_idea_id = old.id
      limit 1;
      if found then
        raise exception 'JNV-% was broken into tasks (e.g. JNV-%), so it has to stay an idea.', old.number, v_ref;
      end if;
    elsif old.kind = 'doc' then
      select i.number into v_ref
      from public.ideas d join public.items i on i.id = d.item_id
      where d.consolidated_into = old.id
      limit 1;
      if found then
        raise exception 'Ideas were consolidated into JNV-% (e.g. JNV-%), so it has to stay a doc.', old.number, v_ref;
      end if;
      if exists (select 1 from public.spaces s where s.pitch_item_id = old.id or s.facts_item_id = old.id) then
        raise exception 'JNV-% is a space''s pitch or the Studio facts, so it has to stay a doc.', old.number;
      end if;
    end if;
  end if;

  if tg_op = 'UPDATE' and new.space_id is distinct from old.space_id then
    -- Consolidated ideas and their doc share a space.
    if new.kind = 'idea' then
      select i.number into v_ref
      from public.ideas d join public.items i on i.id = d.consolidated_into
      where d.item_id = new.id and i.space_id is distinct from new.space_id;
      if found then
        raise exception 'JNV-% is consolidated into JNV-%, which lives in another space.', new.number, v_ref;
      end if;
      if new.space_id is null and exists (select 1 from public.ideas d where d.item_id = new.id and d.status is not null) then
        raise exception 'JNV-% has a status, so it can''t go back to the inbox.', new.number;
      end if;
    elsif new.kind = 'doc' then
      select i.number into v_ref
      from public.ideas d join public.items i on i.id = d.item_id
      where d.consolidated_into = new.id and i.space_id is distinct from new.space_id
      limit 1;
      if found then
        raise exception 'Ideas from this space (e.g. JNV-%) are consolidated into JNV-%, so it can''t move.', v_ref, new.number;
      end if;
      if exists (
        select 1 from public.spaces s
        where (s.pitch_item_id = new.id or s.facts_item_id = new.id) and s.id is distinct from new.space_id
      ) then
        raise exception 'JNV-% is a space''s pitch or the Studio facts, so it can''t leave its space.', new.number;
      end if;
    end if;
  end if;

  return new;
end;
$$;


ALTER FUNCTION "private"."check_item_write"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."check_member"("allow_connector" boolean) RETURNS "uuid"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null or not exists (select 1 from public.members m where m.id = v_uid) then
    raise exception 'Only studio members can make changes in Jenova.' using errcode = '42501';
  end if;
  if not allow_connector and public.is_connector() then
    raise exception 'Claude can only read Jenova and propose items: this change has to be made in the app.'
      using errcode = '42501';
  end if;
  return v_uid;
end;
$$;


ALTER FUNCTION "private"."check_member"("allow_connector" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."digest_text"("p_item" "jsonb", "p_key" "text", "p_n" integer, "p_required" boolean, "p_max" integer) RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
declare
  v_value jsonb := p_item -> p_key;
  v_text text;
begin
  if v_value is null or jsonb_typeof(v_value) = 'null' then
    if p_required then
      raise exception 'Item %: "%" is required.', p_n, p_key;
    end if;
    return null;
  end if;
  if jsonb_typeof(v_value) <> 'string' then
    raise exception 'Item %: "%" must be text.', p_n, p_key;
  end if;
  v_text := btrim(v_value #>> '{}');
  if v_text = '' then
    if p_required then
      raise exception 'Item %: "%" can''t be empty.', p_n, p_key;
    end if;
    return null;
  end if;
  if length(v_text) > p_max then
    raise exception 'Item %: "%" is too long (at most % characters).', p_n, p_key, p_max;
  end if;
  return v_text;
end;
$$;


ALTER FUNCTION "private"."digest_text"("p_item" "jsonb", "p_key" "text", "p_n" integer, "p_required" boolean, "p_max" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."search_vector"("title" "text", "body" "text") RETURNS "tsvector"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select setweight(to_tsvector('simple'::regconfig, public.unaccent_text(coalesce(title, ''))), 'A')
      || setweight(to_tsvector('simple'::regconfig, public.unaccent_text(coalesce(body, ''))), 'B');
$$;


ALTER FUNCTION "public"."search_vector"("title" "text", "body" "text") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "number" bigint NOT NULL,
    "kind" "public"."item_kind" NOT NULL,
    "title" "text" NOT NULL,
    "space_id" "uuid",
    "content_json" "jsonb",
    "content_md" "text" DEFAULT ''::"text" NOT NULL,
    "version" integer DEFAULT 1 NOT NULL,
    "created_by" "uuid",
    "created_via" "public"."created_via" DEFAULT 'app'::"public"."created_via" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_by" "uuid",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "archived_at" timestamp with time zone,
    "search" "tsvector" GENERATED ALWAYS AS ("public"."search_vector"("title", "content_md")) STORED,
    CONSTRAINT "items_version_check" CHECK (("version" > 0))
);


ALTER TABLE "public"."items" OWNER TO "postgres";


COMMENT ON TABLE "public"."items" IS 'Every idea, task and doc. space_id null = in the inbox. Writes go through the write functions.';



COMMENT ON COLUMN "public"."items"."number" IS 'Shown as JNV-{number}. Never reused, never changes.';



CREATE OR REPLACE FUNCTION "private"."get_item"("p_item_id" "uuid", "p_kind" "public"."item_kind" DEFAULT NULL::"public"."item_kind") RETURNS "public"."items"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_item public.items;
begin
  select * into v_item from public.items i where i.id = p_item_id for update;
  if not found then
    raise exception 'There is no item with id %.', p_item_id using errcode = 'P0002';
  end if;
  if p_kind is not null and v_item.kind <> p_kind then
    raise exception 'JNV-% is %, not %.', v_item.number, private.kind_label(v_item.kind), private.kind_label(p_kind);
  end if;
  return v_item;
end;
$$;


ALTER FUNCTION "private"."get_item"("p_item_id" "uuid", "p_kind" "public"."item_kind") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."proposals" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "source_id" "uuid" NOT NULL,
    "batch_index" integer NOT NULL,
    "kind" "public"."item_kind" NOT NULL,
    "title" "text" NOT NULL,
    "summary_md" "text" DEFAULT ''::"text" NOT NULL,
    "quote" "text",
    "confidence" "public"."proposal_confidence" NOT NULL,
    "suggested_space_id" "uuid",
    "suggested_assignee_id" "uuid",
    "suggested_due_date" "date",
    "possible_duplicate_of" "uuid",
    "state" "public"."proposal_state" DEFAULT 'pending'::"public"."proposal_state" NOT NULL,
    "resulting_item_id" "uuid",
    "proposed_by" "uuid",
    "created_via" "public"."created_via" DEFAULT 'claude'::"public"."created_via" NOT NULL,
    "triaged_by" "uuid",
    "triaged_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "quote_translation" "text",
    CONSTRAINT "proposals_batch_index_check" CHECK (("batch_index" >= 0)),
    CONSTRAINT "proposals_created_via_check" CHECK (("created_via" = ANY (ARRAY['claude'::"public"."created_via", 'import'::"public"."created_via"]))),
    CONSTRAINT "proposals_result_consistent" CHECK ((("state" = ANY (ARRAY['accepted'::"public"."proposal_state", 'merged'::"public"."proposal_state"])) = ("resulting_item_id" IS NOT NULL))),
    CONSTRAINT "proposals_title_not_blank" CHECK (("length"("btrim"("title")) > 0)),
    CONSTRAINT "proposals_triage_consistent" CHECK ((("state" = 'pending'::"public"."proposal_state") = ("triaged_at" IS NULL)))
);


ALTER TABLE "public"."proposals" OWNER TO "postgres";


COMMENT ON COLUMN "public"."proposals"."quote_translation" IS 'English translation of quote, when the quote is not in English. Shown on the triage card.';



CREATE OR REPLACE FUNCTION "private"."get_pending_proposal"("p_proposal_id" "uuid") RETURNS "public"."proposals"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_p public.proposals;
begin
  select * into v_p from public.proposals p where p.id = p_proposal_id for update;
  if not found then
    raise exception 'There is no proposal with id %.', p_proposal_id using errcode = 'P0002';
  end if;
  if v_p.state <> 'pending' then
    raise exception 'This proposal was already %.', v_p.state;
  end if;
  return v_p;
end;
$$;


ALTER FUNCTION "private"."get_pending_proposal"("p_proposal_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."guard_file_status"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  if new.status is distinct from old.status and not (old.status = 'pending' and new.status = 'ready') then
    raise exception 'A file''s status can only change from pending to ready (it is %).', old.status;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "private"."guard_file_status"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."guard_key_doc_archive"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  if exists (select 1 from public.spaces s where s.facts_item_id = new.id) then
    raise exception 'JNV-% is the Studio facts doc, so it can''t be archived.', new.number;
  end if;
  if exists (select 1 from public.spaces s where s.pitch_item_id = new.id) then
    raise exception 'JNV-% is the pitch of %, so it can''t be archived. Pick another pitch first.',
      new.number, (select string_agg(s.name, ', ' order by s.name) from public.spaces s where s.pitch_item_id = new.id);
  end if;
  return new;
end;
$$;


ALTER FUNCTION "private"."guard_key_doc_archive"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."guard_member_role"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  if tg_op = 'UPDATE' and new.role is distinct from old.role
     and current_user in ('authenticated', 'anon') and not public.is_admin() then
    raise exception 'Only an admin can change a member''s role.';
  end if;

  if old.role = 'admin' and (tg_op = 'DELETE' or new.role <> 'admin')
     and not exists (select 1 from public.members m where m.role = 'admin' and m.id <> old.id) then
    raise exception 'Jenova needs at least one admin: make someone else admin first.';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "private"."guard_member_role"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."guard_source"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  if new.raw_text is distinct from old.raw_text then
    raise exception 'A source''s raw text is never modified.';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "private"."guard_source"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."guard_space"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
declare
  v_doc public.items;
begin
  if tg_op = 'DELETE' then
    if old.is_studio then
      raise exception 'The Studio space can''t be deleted.';
    end if;
    return old;
  end if;

  if tg_op = 'UPDATE' and old.is_studio then
    if not new.is_studio then
      raise exception 'The Studio space must stay the Studio space.';
    end if;
    if new.archived_at is not null then
      raise exception 'The Studio space can''t be archived.';
    end if;
  end if;

  if new.is_studio and exists (select 1 from public.spaces s where s.is_studio and s.id <> new.id) then
    raise exception 'There is already a Studio space, and there can only be one.';
  end if;

  if new.pitch_item_id is not null then
    select * into v_doc from public.items i where i.id = new.pitch_item_id;
    if v_doc.space_id is distinct from new.id then
      raise exception 'A space''s pitch must be a doc in that space (JNV-% isn''t).', v_doc.number;
    end if;
  end if;
  if new.facts_item_id is not null then
    select * into v_doc from public.items i where i.id = new.facts_item_id;
    if v_doc.space_id is distinct from new.id then
      raise exception 'The Studio facts must be a doc in the Studio space (JNV-% isn''t).', v_doc.number;
    end if;
  end if;

  return new;
end;
$$;


ALTER FUNCTION "private"."guard_space"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."insert_kind_row"("p_item" "public"."items") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if p_item.kind = 'idea' then
    insert into public.ideas (item_id, status)
    values (p_item.id, case when p_item.space_id is null then null else 'to_discuss'::public.idea_status end);
  elsif p_item.kind = 'task' then
    insert into public.tasks (item_id) values (p_item.id);
  else
    insert into public.docs (item_id) values (p_item.id);
  end if;
end;
$$;


ALTER FUNCTION "private"."insert_kind_row"("p_item" "public"."items") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."kind_label"("kind" "public"."item_kind") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  select case kind when 'idea' then 'an idea' when 'task' then 'a task' else 'a doc' end;
$$;


ALTER FUNCTION "private"."kind_label"("kind" "public"."item_kind") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."kind_row_matches_item"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
declare
  v_kind public.item_kind;
  v_number bigint;
begin
  select i.kind, i.number into v_kind, v_number from public.items i where i.id = new.item_id;
  if not found then
    raise exception 'There is no item with id %', new.item_id;
  end if;
  if v_kind <> new.kind then
    raise exception 'JNV-% is %, so it can''t have % row. Use change_kind() to change what it is.',
      v_number, private.kind_label(v_kind), private.kind_label(new.kind);
  end if;
  return new;
end;
$$;


ALTER FUNCTION "private"."kind_row_matches_item"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."log_activity"("p_verb" "public"."activity_verb", "p_item_id" "uuid" DEFAULT NULL::"uuid", "p_space_id" "uuid" DEFAULT NULL::"uuid", "p_source_id" "uuid" DEFAULT NULL::"uuid", "p_data" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  insert into public.activity (actor_id, actor_via, verb, item_id, space_id, source_id, data)
  select m.id,
         -- Connector tokens carry the OAuth client_id claim (execution notes, ticket 01 #2).
         case when (select auth.jwt()) ->> 'client_id' is not null then 'claude' else 'app' end::public.actor_via,
         p_verb,
         p_item_id,
         coalesce(p_space_id, (select i.space_id from public.items i where i.id = p_item_id)),
         p_source_id,
         coalesce(p_data, '{}')
  from (select (select auth.uid()) as uid) caller
  left join public.members m on m.id = caller.uid;
$$;


ALTER FUNCTION "private"."log_activity"("p_verb" "public"."activity_verb", "p_item_id" "uuid", "p_space_id" "uuid", "p_source_id" "uuid", "p_data" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."log_direct_write"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if tg_table_name = 'comments' then
    perform private.log_activity('commented', new.item_id, null, null, jsonb_build_object('comment_id', new.id));
  elsif tg_table_name = 'tasks' then
    perform private.log_activity('assigned', new.item_id, null, null,
      jsonb_build_object('from', old.assignee_id, 'to', new.assignee_id));
  elsif tg_table_name = 'spaces' then
    perform private.log_activity('space_created', null, new.id, null, '{}');
  end if;
  return null;
end;
$$;


ALTER FUNCTION "private"."log_direct_write"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."maintain_task_completion"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  if new.status = 'done' then
    if tg_op = 'INSERT' or old.status <> 'done' then
      new.completed_at := now();
    end if;
  else
    new.completed_at := null;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "private"."maintain_task_completion"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."require_member"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select private.check_member(false);
$$;


ALTER FUNCTION "private"."require_member"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."require_member_id"("p_member_id" "uuid", "p_what" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if p_member_id is not null and not exists (select 1 from public.members m where m.id = p_member_id) then
    raise exception '% must be a studio member.', p_what;
  end if;
end;
$$;


ALTER FUNCTION "private"."require_member_id"("p_member_id" "uuid", "p_what" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."require_member_or_connector"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select private.check_member(true);
$$;


ALTER FUNCTION "private"."require_member_or_connector"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."require_open_space"("p_space_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if p_space_id is not null
     and not exists (select 1 from public.spaces s where s.id = p_space_id and s.archived_at is null) then
    raise exception 'That space doesn''t exist or is archived.';
  end if;
end;
$$;


ALTER FUNCTION "private"."require_open_space"("p_space_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."stamp_comment_edit"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  if new.body_md is distinct from old.body_md then
    new.edited_at := now();
  end if;
  return new;
end;
$$;


ALTER FUNCTION "private"."stamp_comment_edit"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."accept_proposal"("proposal_id" "uuid", "overrides" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "public"."items"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_uid uuid := private.require_member();
  v_p public.proposals;
  o jsonb := coalesce(accept_proposal.overrides, '{}');
  v_kind public.item_kind;
  v_space uuid;
  v_item public.items;
  v_idea_status public.idea_status;
  v_decided_by uuid[];
  v_assignee uuid;
begin
  v_p := private.get_pending_proposal(accept_proposal.proposal_id);

  v_kind := coalesce(o ->> 'kind', v_p.kind::text)::public.item_kind;
  v_space := case when o ? 'space_id' then (o ->> 'space_id')::uuid else v_p.suggested_space_id end;
  perform private.require_open_space(v_space);

  insert into public.items (kind, title, space_id, content_md, created_by, updated_by, created_via)
  values (
    v_kind,
    coalesce(nullif(btrim(o ->> 'title'), ''), v_p.title),
    v_space,
    coalesce(o ->> 'content_md', v_p.summary_md),
    coalesce(v_p.proposed_by, v_uid),
    v_uid,
    v_p.created_via
  )
  returning * into v_item;

  if v_kind = 'idea' then
    -- A null status override in a space still starts at To discuss; deciders only count for a decision.
    v_idea_status := coalesce(
      (o ->> 'status')::public.idea_status,
      case when v_space is not null then 'to_discuss'::public.idea_status end
    );
    v_decided_by := case when v_idea_status in ('committed', 'cut')
      then coalesce(array(select jsonb_array_elements_text(o -> 'decided_by'))::uuid[], '{}')
      else '{}' end;
    insert into public.ideas (item_id, status, decided_by, cut_reason)
    values (v_item.id, v_idea_status, v_decided_by, case when v_idea_status = 'cut' then btrim(o ->> 'cut_reason') end);
  elsif v_kind = 'task' then
    v_assignee := case when o ? 'assignee_id' then (o ->> 'assignee_id')::uuid else v_p.suggested_assignee_id end;
    perform private.require_member_id(v_assignee, 'The assignee');
    insert into public.tasks (item_id, status, assignee_id, due_date)
    values (
      v_item.id,
      coalesce((o ->> 'status')::public.task_status, 'todo'),
      v_assignee,
      case when o ? 'due_date' then (o ->> 'due_date')::date else v_p.suggested_due_date end
    );
  else
    insert into public.docs (item_id) values (v_item.id);
  end if;

  insert into public.item_sources (item_id, source_id, quote, quote_translation, created_by)
  values (v_item.id, v_p.source_id, v_p.quote, v_p.quote_translation, v_uid);

  update public.proposals p
  set state = 'accepted', resulting_item_id = v_item.id, triaged_by = v_uid, triaged_at = now()
  where p.id = v_p.id;

  perform private.log_activity('proposal_accepted', v_item.id, null, v_p.source_id, jsonb_build_object('proposal_id', v_p.id));
  if v_idea_status in ('committed', 'cut') then
    perform private.log_activity(v_idea_status::text::public.activity_verb, v_item.id, null, null,
      jsonb_build_object('to', v_idea_status, 'decided_by', to_jsonb(v_decided_by)));
  end if;
  return v_item;
end;
$$;


ALTER FUNCTION "public"."accept_proposal"("proposal_id" "uuid", "overrides" "jsonb") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."item_links" (
    "from_item" "uuid" NOT NULL,
    "to_item" "uuid" NOT NULL,
    "type" "public"."link_type" NOT NULL,
    "created_by" "uuid" DEFAULT "auth"."uid"(),
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "item_links_not_self" CHECK (("from_item" <> "to_item"))
);


ALTER TABLE "public"."item_links" OWNER TO "postgres";


COMMENT ON TABLE "public"."item_links" IS 'depends_on: from_item waits on to_item (tasks only, no cycles). relates_to: stored once, read both ways.';



CREATE OR REPLACE FUNCTION "public"."add_dependency"("task_id" "uuid", "depends_on" "uuid") RETURNS "public"."item_links"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_uid uuid := private.require_member();
  v_task public.items;
  v_target public.items;
  v_link public.item_links;
begin
  -- Lock both tasks in id order, so add_dependency(A, B) and (B, A) running at once queue up and
  -- the second gets the readable cycle error instead of a deadlock.
  perform 1 from public.items i
  where i.id in (add_dependency.task_id, add_dependency.depends_on)
  order by i.id
  for update;
  v_task := private.get_item(add_dependency.task_id);
  v_target := private.get_item(add_dependency.depends_on);

  select * into v_link from public.item_links l
  where l.from_item = v_task.id and l.to_item = v_target.id and l.type = 'depends_on';
  if found then
    return v_link;
  end if;

  insert into public.item_links (from_item, to_item, type, created_by)
  values (v_task.id, v_target.id, 'depends_on', v_uid)
  returning * into v_link;

  perform private.log_activity('dependency_added', v_task.id, null, null, jsonb_build_object('depends_on', v_target.id));
  return v_link;
end;
$$;


ALTER FUNCTION "public"."add_dependency"("task_id" "uuid", "depends_on" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."break_into_tasks"("idea_id" "uuid", "tasks" "jsonb") RETURNS SETOF "public"."items"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_uid uuid := private.require_member();
  v_idea public.items;
  v_status public.idea_status;
  v_task jsonb;
  v_item public.items;
  v_assignee uuid;
begin
  v_idea := private.get_item(break_into_tasks.idea_id, 'idea');
  select d.status into v_status from public.ideas d where d.item_id = v_idea.id;
  if v_status is distinct from 'committed' then
    raise exception 'Only committed ideas can be broken into tasks (JNV-% is %).',
      v_idea.number, coalesce(replace(v_status::text, '_', ' '), 'in the inbox');
  end if;
  perform private.require_open_space(v_idea.space_id);
  if jsonb_typeof(break_into_tasks.tasks) is distinct from 'array' or jsonb_array_length(break_into_tasks.tasks) = 0 then
    raise exception 'Add at least one task.';
  end if;

  for v_task in select * from jsonb_array_elements(break_into_tasks.tasks) loop
    v_assignee := (v_task ->> 'assignee_id')::uuid;
    perform private.require_member_id(v_assignee, 'The assignee');

    insert into public.items (kind, title, space_id, content_md, created_by, updated_by, created_via)
    values ('task', btrim(v_task ->> 'title'), v_idea.space_id, coalesce(v_task ->> 'content_md', ''), v_uid, v_uid, 'app')
    returning * into v_item;

    insert into public.tasks (item_id, assignee_id, due_date, origin_idea_id)
    values (v_item.id, v_assignee, (v_task ->> 'due_date')::date, v_idea.id);

    perform private.log_activity('created', v_item.id, null, null, jsonb_build_object('origin_idea_id', v_idea.id));
    return next v_item;
  end loop;
end;
$$;


ALTER FUNCTION "public"."break_into_tasks"("idea_id" "uuid", "tasks" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."capture_item"("kind" "public"."item_kind", "title" "text", "space_id" "uuid" DEFAULT NULL::"uuid", "content_md" "text" DEFAULT NULL::"text", "content_json" "jsonb" DEFAULT NULL::"jsonb") RETURNS "public"."items"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_uid uuid := private.require_member();
  v_item public.items;
begin
  perform private.require_open_space(capture_item.space_id);

  insert into public.items (kind, title, space_id, content_md, content_json, created_by, updated_by, created_via)
  values (
    capture_item.kind, btrim(capture_item.title), capture_item.space_id,
    coalesce(capture_item.content_md, ''), capture_item.content_json, v_uid, v_uid, 'app'
  )
  returning * into v_item;

  perform private.insert_kind_row(v_item);
  perform private.log_activity('created', v_item.id);
  return v_item;
end;
$$;


ALTER FUNCTION "public"."capture_item"("kind" "public"."item_kind", "title" "text", "space_id" "uuid", "content_md" "text", "content_json" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."capture_item"("kind" "public"."item_kind", "title" "text", "space_id" "uuid", "content_md" "text", "content_json" "jsonb") IS 'Flow 1. No space = the inbox. Ideas start without a status in the inbox, To discuss in a space.';



CREATE OR REPLACE FUNCTION "public"."change_kind"("item_id" "uuid", "kind" "public"."item_kind") RETURNS "public"."items"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_uid uuid := private.require_member();
  v_item public.items;
  v_from public.item_kind;
begin
  v_item := private.get_item(change_kind.item_id);
  if v_item.kind = change_kind.kind then
    return v_item;
  end if;
  v_from := v_item.kind;

  if v_from = 'idea' then
    delete from public.ideas d where d.item_id = v_item.id;
  elsif v_from = 'task' then
    delete from public.tasks t where t.item_id = v_item.id;
  else
    delete from public.docs d where d.item_id = v_item.id;
  end if;

  update public.items i set kind = change_kind.kind, updated_at = now()
  where i.id = v_item.id
  returning * into v_item;

  perform private.insert_kind_row(v_item);
  perform private.log_activity('kind_changed', v_item.id, null, null, jsonb_build_object('from', v_from, 'to', v_item.kind));
  return v_item;
end;
$$;


ALTER FUNCTION "public"."change_kind"("item_id" "uuid", "kind" "public"."item_kind") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."consolidate_into_doc"("idea_ids" "uuid"[], "title" "text") RETURNS "public"."items"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_uid uuid := private.require_member();
  v_ids uuid[] := array(select distinct unnest(consolidate_into_doc.idea_ids));
  v_found integer;
  v_bad record;
  v_spaces uuid[];
  v_body text;
  v_doc public.items;
begin
  if cardinality(v_ids) = 0 then
    raise exception 'Pick at least one idea to consolidate.';
  end if;

  perform 1 from public.items i where i.id = any (v_ids) order by i.id for update;
  select count(*) into v_found from public.items i where i.id = any (v_ids);
  if v_found <> cardinality(v_ids) then
    raise exception 'Some of those ideas don''t exist.';
  end if;

  select i.number, i.kind into v_bad from public.items i where i.id = any (v_ids) and i.kind <> 'idea' limit 1;
  if found then
    raise exception 'Only ideas can be consolidated: JNV-% is %.', v_bad.number, private.kind_label(v_bad.kind);
  end if;

  select i.number into v_bad from public.items i where i.id = any (v_ids) and i.space_id is null limit 1;
  if found then
    raise exception 'JNV-% is in the inbox: file it into a space before consolidating it.', v_bad.number;
  end if;

  v_spaces := array(select distinct i.space_id from public.items i where i.id = any (v_ids));
  if cardinality(v_spaces) > 1 then
    raise exception 'Consolidating ideas from different spaces isn''t possible: file them into the same space first (they are in %).',
      (select string_agg(s.name, ', ' order by s.name) from public.spaces s where s.id = any (v_spaces));
  end if;
  perform private.require_open_space(v_spaces[1]);

  select i.number as idea, c.number as doc into v_bad
  from public.ideas d
  join public.items i on i.id = d.item_id
  join public.items c on c.id = d.consolidated_into
  where d.item_id = any (v_ids) and d.status = 'consolidated'
  limit 1;
  if found then
    raise exception 'JNV-% is already consolidated into JNV-%.', v_bad.idea, v_bad.doc;
  end if;

  select string_agg(section, E'\n\n' order by number)
  into v_body
  from (
    select i.number,
           concat_ws(E'\n\n',
             format('## %s (JNV-%s)', i.title, i.number),
             nullif(btrim(i.content_md), ''),
             (select string_agg(
                       '> ' || replace(btrim(s.quote), E'\n', E'\n> ') || E'\n>\n> — ' || src.title,
                       E'\n\n' order by s.created_at)
              from public.item_sources s join public.sources src on src.id = s.source_id
              where s.item_id = i.id and coalesce(btrim(s.quote), '') <> '')
           ) as section
    from public.items i
    where i.id = any (v_ids)
  ) sections;

  insert into public.items (kind, title, space_id, content_md, created_by, updated_by, created_via)
  values ('doc', btrim(consolidate_into_doc.title), v_spaces[1], coalesce(v_body, ''), v_uid, v_uid, 'app')
  returning * into v_doc;
  insert into public.docs (item_id) values (v_doc.id);

  insert into public.item_sources (item_id, source_id, quote, quote_translation, created_by)
  select distinct v_doc.id, s.source_id, s.quote, s.quote_translation, v_uid
  from public.item_sources s where s.item_id = any (v_ids)
  on conflict do nothing;

  update public.ideas d
  set status = 'consolidated', consolidated_into = v_doc.id, cut_reason = null
  where d.item_id = any (v_ids);

  perform private.log_activity('created', v_doc.id, null, null, jsonb_build_object('from_ideas', to_jsonb(v_ids)));
  perform private.log_activity('consolidated', x.id, null, null, jsonb_build_object('doc_id', v_doc.id))
  from unnest(v_ids) as x (id);
  return v_doc;
end;
$$;


ALTER FUNCTION "public"."consolidate_into_doc"("idea_ids" "uuid"[], "title" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_source"("title" "text", "origin" "public"."source_origin", "raw_text" "text", "cleaned_md" "text" DEFAULT NULL::"text", "processing_notes" "text" DEFAULT NULL::"text", "external_ref" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_uid uuid := private.require_member_or_connector();
  v_title text := btrim(create_source.title);
  v_ref text := nullif(btrim(create_source.external_ref), '');
  v_cleaned text := nullif(btrim(create_source.cleaned_md), '');
  v_notes text := nullif(btrim(create_source.processing_notes), '');
  v_src public.sources;
  v_existed boolean := false;
  v_recent integer;
begin
  if v_title is null or v_title = '' then
    raise exception 'A source needs a title.';
  end if;
  if length(v_title) > 200 then
    raise exception 'A source title can be at most 200 characters.';
  end if;
  if create_source.raw_text is null or btrim(create_source.raw_text) = '' then
    raise exception 'A source needs its text.';
  end if;
  if length(create_source.raw_text) > 1000000 or length(coalesce(v_cleaned, '')) > 1000000
     or length(coalesce(v_notes, '')) > 200000 or length(coalesce(v_ref, '')) > 500 then
    raise exception 'That source is too large (text up to 1,000,000 characters, notes up to 200,000, reference up to 500).';
  end if;

  -- Without an external_ref the same member sending the same text again gets the same source back
  -- (a retry after a lost response must not start a second copy of the dump). The key is per
  -- member, so two people pasting the same text each keep their own source.
  if v_ref is null then
    v_ref := 'auto:' || v_uid::text || ':' || md5(create_source.raw_text);
  end if;

  select * into v_src from public.sources s where s.external_ref = v_ref;
  if v_src.id is not null then
    return jsonb_build_object(
      'id', v_src.id, 'existed', true, 'title', v_src.title, 'origin', v_src.origin,
      'created_via', v_src.created_via, 'created_at', v_src.created_at
    );
  end if;

  -- A looping or prompt-injected Claude must not fill the free-tier database: Claude may create
  -- at most 50 new sources per member per 24 hours. (People using the app are not limited.)
  if public.is_connector() then
    select count(*) into v_recent from public.sources s
    where s.created_by = v_uid and s.created_via = 'claude' and s.created_at > now() - interval '24 hours';
    if v_recent >= 50 then
      raise exception 'Too many new sources: Claude already created % in the last 24 hours (the limit is 50). Try again tomorrow, or import the file in the app.', v_recent
        using errcode = '54000';
    end if;
  end if;

  insert into public.sources (title, origin, raw_text, cleaned_md, processing_notes, external_ref, created_by, created_via)
  values (
    v_title, create_source.origin, create_source.raw_text, v_cleaned, v_notes, v_ref, v_uid,
    case when public.is_connector() then 'claude' else 'import' end::public.created_via
  )
  on conflict on constraint sources_external_ref_key do nothing
  returning * into v_src;

  -- Lost a race with an identical call: it created the source, return that one.
  if v_src.id is null then
    select * into v_src from public.sources s where s.external_ref = v_ref;
    v_existed := true;
  end if;

  return jsonb_build_object(
    'id', v_src.id, 'existed', v_existed, 'title', v_src.title, 'origin', v_src.origin,
    'created_via', v_src.created_via, 'created_at', v_src.created_at
  );
end;
$$;


ALTER FUNCTION "public"."create_source"("title" "text", "origin" "public"."source_origin", "raw_text" "text", "cleaned_md" "text", "processing_notes" "text", "external_ref" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."create_source"("title" "text", "origin" "public"."source_origin", "raw_text" "text", "cleaned_md" "text", "processing_notes" "text", "external_ref" "text") IS 'Connector tool and Import digest: stores a source. A repeated external_ref (or, without one, the same member sending the same text) returns the existing source.';



CREATE OR REPLACE FUNCTION "public"."dismiss_proposal"("proposal_id" "uuid") RETURNS "public"."proposals"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_uid uuid := private.require_member();
  v_p public.proposals;
begin
  v_p := private.get_pending_proposal(dismiss_proposal.proposal_id);

  update public.proposals p
  set state = 'dismissed', triaged_by = v_uid, triaged_at = now()
  where p.id = v_p.id
  returning * into v_p;

  perform private.log_activity('proposal_dismissed', null, v_p.suggested_space_id, v_p.source_id,
    jsonb_build_object('proposal_id', v_p.id, 'title', v_p.title));
  return v_p;
end;
$$;


ALTER FUNCTION "public"."dismiss_proposal"("proposal_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."file_item"("item_id" "uuid", "space_id" "uuid", "status" "public"."idea_status" DEFAULT NULL::"public"."idea_status") RETURNS "public"."items"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_uid uuid := private.require_member();
  v_item public.items;
  v_from uuid;
  v_old_status public.idea_status;
  v_new_status public.idea_status;
begin
  v_item := private.get_item(file_item.item_id);
  if file_item.space_id is null then
    raise exception 'Pick a space to file JNV-% into.', v_item.number;
  end if;
  perform private.require_open_space(file_item.space_id);
  if file_item.status is not null and v_item.kind <> 'idea' then
    raise exception 'Only ideas have a triage status (JNV-% is %).', v_item.number, private.kind_label(v_item.kind);
  end if;
  if file_item.status not in ('to_discuss', 'maybe') then
    raise exception 'Filing only sets To discuss or Maybe. Use set_idea_status() to commit or cut JNV-%.', v_item.number;
  end if;
  select d.status into v_old_status from public.ideas d where d.item_id = v_item.id;
  if file_item.status is not null and v_old_status in ('committed', 'cut', 'consolidated') then
    raise exception 'JNV-% is %: change its status with set_idea_status(), not while filing it.',
      v_item.number, replace(v_old_status::text, '_', ' ');
  end if;

  v_from := v_item.space_id;
  update public.items i set space_id = file_item.space_id, updated_at = now()
  where i.id = v_item.id
  returning * into v_item;

  if v_item.kind = 'idea' then
    update public.ideas d
    set status = coalesce(file_item.status, d.status, 'to_discuss')
    where d.item_id = v_item.id
    returning d.status into v_new_status;
  end if;

  perform private.log_activity('filed', v_item.id, null, null, jsonb_build_object(
    'from_space', v_from, 'to_space', file_item.space_id, 'from_status', v_old_status, 'to_status', v_new_status));
  return v_item;
end;
$$;


ALTER FUNCTION "public"."file_item"("item_id" "uuid", "space_id" "uuid", "status" "public"."idea_status") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."home_blocked"("p_limit" integer DEFAULT 5) RETURNS TABLE("number" bigint, "title" "text", "space_id" "uuid")
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  select i.number, i.title, i.space_id
  from public.tasks t
  join public.items i on i.id = t.item_id
  where t.status = 'blocked' and i.archived_at is null
  order by i.updated_at desc, i.number desc
  limit greatest(least(p_limit, 20), 1);
$$;


ALTER FUNCTION "public"."home_blocked"("p_limit" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."home_blocked"("p_limit" integer) IS 'Home card: the blocked tasks. SECURITY INVOKER.';



CREATE OR REPLACE FUNCTION "public"."home_decisions"("p_days" integer DEFAULT 14, "p_tz" "text" DEFAULT 'UTC'::"text") RETURNS TABLE("day" "date", "committed" integer, "cut" integer)
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  with tz as (
    select coalesce((select n.name from pg_catalog.pg_timezone_names n where n.name = p_tz limit 1), 'UTC') as name
  ),
  days as (
    select d::date as day
    from tz, generate_series(
      (now() at time zone tz.name)::date - (greatest(least(p_days, 90), 1) - 1),
      (now() at time zone tz.name)::date,
      interval '1 day'
    ) d
  ),
  decided as (
    select (x.decided_at at time zone tz.name)::date as day, x.status
    from tz, public.ideas x
    join public.items i on i.id = x.item_id
    where i.archived_at is null
      and x.status in ('committed', 'cut')
      and x.decided_at >= now() - make_interval(days => 91)
  )
  select
    days.day,
    (count(decided.status) filter (where decided.status = 'committed'))::integer,
    (count(decided.status) filter (where decided.status = 'cut'))::integer
  from days
  left join decided on decided.day = days.day
  group by days.day
  order by days.day;
$$;


ALTER FUNCTION "public"."home_decisions"("p_days" integer, "p_tz" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."home_decisions"("p_days" integer, "p_tz" "text") IS 'Home metric: ideas committed or cut per day, last p_days days in the viewer''s time zone. SECURITY INVOKER.';



CREATE OR REPLACE FUNCTION "public"."home_inbox_age"() RETURNS TABLE("under_1d" integer, "d1_3" integer, "d4_6" integer, "over_7d" integer)
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  with waiting as (
    select i.created_at from public.items i where i.space_id is null and i.archived_at is null
    union all
    select p.created_at from public.proposals p where p.state = 'pending'
  )
  select
    (count(*) filter (where w.created_at > now() - interval '1 day'))::integer,
    (count(*) filter (where w.created_at <= now() - interval '1 day' and w.created_at > now() - interval '4 days'))::integer,
    (count(*) filter (where w.created_at <= now() - interval '4 days' and w.created_at > now() - interval '7 days'))::integer,
    (count(*) filter (where w.created_at <= now() - interval '7 days'))::integer
  from waiting w;
$$;


ALTER FUNCTION "public"."home_inbox_age"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."home_inbox_age"() IS 'Home metric: inbox items and pending proposals by age. SECURITY INVOKER, RLS decides what is counted.';



CREATE OR REPLACE FUNCTION "public"."home_space_stats"() RETURNS TABLE("space_id" "uuid", "items" integer, "tasks_total" integer, "tasks_done" integer)
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  select
    s.id,
    (count(i.id))::integer,
    (count(t.item_id))::integer,
    (count(t.item_id) filter (where t.status = 'done'))::integer
  from public.spaces s
  left join public.items i on i.space_id = s.id and i.archived_at is null
  left join public.tasks t on t.item_id = i.id
  where s.archived_at is null
  group by s.id;
$$;


ALTER FUNCTION "public"."home_space_stats"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."home_space_stats"() IS 'Home gallery: items and task progress per open space. SECURITY INVOKER.';



CREATE OR REPLACE FUNCTION "public"."home_task_counts"() RETURNS TABLE("todo" integer, "in_progress" integer, "blocked" integer)
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  select
    (count(*) filter (where t.status = 'todo'))::integer,
    (count(*) filter (where t.status = 'in_progress'))::integer,
    (count(*) filter (where t.status = 'blocked'))::integer
  from public.tasks t
  join public.items i on i.id = t.item_id
  where i.archived_at is null;
$$;


ALTER FUNCTION "public"."home_task_counts"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."home_task_counts"() IS 'Home metric: open tasks by status. SECURITY INVOKER.';



CREATE OR REPLACE FUNCTION "public"."is_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select exists (
    select 1 from public.members m where m.id = (select auth.uid()) and m.role = 'admin'
  );
$$;


ALTER FUNCTION "public"."is_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_connector"() RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  select coalesce(jsonb_exists((select auth.jwt()), 'client_id'), false);
$$;


ALTER FUNCTION "public"."is_connector"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."is_connector"() IS 'True for tokens issued to an OAuth client (Claude). Those may read, create sources and propose items, nothing else.';



CREATE OR REPLACE FUNCTION "public"."is_member"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select exists (
    select 1 from public.members m where m.id = (select auth.uid())
  );
$$;


ALTER FUNCTION "public"."is_member"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mark_home_seen"("seen_until" timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS timestamp with time zone
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_uid uuid := private.require_member();
  v_seen timestamptz;
begin
  update public.members m
  set last_seen_at = greatest(
    coalesce(m.last_seen_at, '-infinity'::timestamptz),
    least(coalesce(mark_home_seen.seen_until, now()), now())
  )
  where m.id = v_uid
  returning m.last_seen_at into v_seen;
  return v_seen;
end;
$$;


ALTER FUNCTION "public"."mark_home_seen"("seen_until" timestamp with time zone) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."mark_home_seen"("seen_until" timestamp with time zone) IS 'Moves members.last_seen_at forward (never back). Called when Home has shown "Since you last looked".';



CREATE OR REPLACE FUNCTION "public"."merge_item"("item_id" "uuid", "into_item" "uuid") RETURNS "public"."items"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_uid uuid := private.require_member();
  v_item public.items;
  v_target public.items;
begin
  if merge_item.item_id = merge_item.into_item then
    raise exception 'An item can''t be merged into itself.';
  end if;
  -- Lock both in id order so two merges running at once can't deadlock.
  perform 1 from public.items i where i.id in (merge_item.item_id, merge_item.into_item) order by i.id for update;
  v_item := private.get_item(merge_item.item_id);
  v_target := private.get_item(merge_item.into_item);

  if v_item.space_id is not null then
    raise exception 'JNV-% is already in a space: only inbox items are merged this way.', v_item.number;
  end if;
  if v_item.archived_at is not null then
    raise exception 'JNV-% is archived.', v_item.number;
  end if;
  if v_target.archived_at is not null then
    raise exception 'JNV-% is archived: pick an item that is still in use.', v_target.number;
  end if;

  insert into public.item_sources (item_id, source_id, quote, quote_translation, created_by)
  select v_target.id, s.source_id, s.quote, s.quote_translation, v_uid
  from public.item_sources s
  where s.item_id = v_item.id
  on conflict do nothing;
  delete from public.item_sources s where s.item_id = v_item.id;

  insert into public.item_links (from_item, to_item, type, created_by)
  values (v_item.id, v_target.id, 'relates_to', v_uid)
  on conflict do nothing;

  update public.items i set archived_at = now(), updated_at = now(), updated_by = v_uid
  where i.id = v_item.id
  returning * into v_item;

  perform private.log_activity('source_added', v_target.id, null, null,
    jsonb_build_object('merged_item', v_item.id, 'merged_number', v_item.number));
  return v_item;
end;
$$;


ALTER FUNCTION "public"."merge_item"("item_id" "uuid", "into_item" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."merge_item"("item_id" "uuid", "into_item" "uuid") IS 'Flow 3: merges a human-captured inbox item into an existing item (archives it, keeps a relates_to link).';



CREATE OR REPLACE FUNCTION "public"."merge_proposal"("proposal_id" "uuid", "into_item" "uuid") RETURNS "public"."proposals"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_uid uuid := private.require_member();
  v_p public.proposals;
  v_item public.items;
begin
  v_p := private.get_pending_proposal(merge_proposal.proposal_id);
  v_item := private.get_item(merge_proposal.into_item);

  insert into public.item_sources (item_id, source_id, quote, quote_translation, created_by)
  values (v_item.id, v_p.source_id, v_p.quote, v_p.quote_translation, v_uid)
  on conflict do nothing;

  update public.proposals p
  set state = 'merged', resulting_item_id = v_item.id, triaged_by = v_uid, triaged_at = now()
  where p.id = v_p.id
  returning * into v_p;

  perform private.log_activity('proposal_merged', v_item.id, null, v_p.source_id, jsonb_build_object('proposal_id', v_p.id));
  return v_p;
end;
$$;


ALTER FUNCTION "public"."merge_proposal"("proposal_id" "uuid", "into_item" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."propose_items"("source_id" "uuid", "items" "jsonb", "start_index" integer DEFAULT 0) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_uid uuid := private.require_member_or_connector();
  v_via public.created_via := case when public.is_connector() then 'claude' else 'import' end;
  v_start integer := coalesce(propose_items.start_index, 0);
  v_count integer;
  v_item jsonb;
  v_n integer;
  v_key text;
  v_allowed text[] := array[
    'title', 'kind', 'summary', 'quote', 'quote_translation', 'confidence', 'suggested_space',
    'possible_duplicate_of', 'suggested_assignee', 'suggested_due_date'
  ];
  v_kind public.item_kind;
  v_confidence public.proposal_confidence;
  v_space uuid;
  v_assignee uuid;
  v_duplicate uuid;
  v_due date;
  v_raw text;
  v_id uuid;
  v_created integer := 0;
  v_existing integer := 0;
  v_rows jsonb;
  v_pass integer;
  v_pending integer;
begin
  if not exists (select 1 from public.sources s where s.id = propose_items.source_id) then
    raise exception 'There is no source with id %: create the source first.', propose_items.source_id using errcode = 'P0002';
  end if;
  if propose_items.items is null or jsonb_typeof(propose_items.items) <> 'array' then
    raise exception 'items must be a list.';
  end if;
  v_count := jsonb_array_length(propose_items.items);
  if v_count = 0 then
    raise exception 'items is empty: nothing to propose.';
  end if;
  if v_count > 100 then
    raise exception 'At most 100 items per call (got %): send the rest in another call with start_index.', v_count;
  end if;
  if v_start < 0 then
    raise exception 'start_index can''t be negative.';
  end if;
  -- One source holds at most 500 proposals (the size of a jenova-digest/v1 file): batch_index is
  -- unique per source, so capping it here caps the source.
  if v_start + v_count > 500 then
    raise exception 'A source holds at most 500 proposals: start_index % plus % items goes past 500.', v_start, v_count
      using errcode = '54000';
  end if;

  -- Pass 1 validates every item (nothing is written); pass 2 inserts.
  for v_pass in 1..2 loop
    for v_n in 1..v_count loop
      v_item := propose_items.items -> (v_n - 1);
      if jsonb_typeof(v_item) <> 'object' then
        raise exception 'Item %: must be an object.', v_n;
      end if;
      select k into v_key from jsonb_object_keys(v_item) k where k <> all (v_allowed) limit 1;
      if v_key is not null then
        raise exception 'Item %: unknown field "%". Allowed: %.', v_n, v_key, array_to_string(v_allowed, ', ');
      end if;

      declare
        v_title text := private.digest_text(v_item, 'title', v_n, true, 200);
        v_summary text := private.digest_text(v_item, 'summary', v_n, true, 4000);
        v_quote text := private.digest_text(v_item, 'quote', v_n, true, 4000);
        v_translation text := private.digest_text(v_item, 'quote_translation', v_n, false, 4000);
      begin
        v_raw := private.digest_text(v_item, 'kind', v_n, true, 20);
        if v_raw not in ('idea', 'task', 'doc') then
          raise exception 'Item %: kind must be idea, task or doc (got "%").', v_n, v_raw;
        end if;
        v_kind := v_raw::public.item_kind;

        v_raw := private.digest_text(v_item, 'confidence', v_n, true, 20);
        if v_raw not in ('explicit', 'discussed', 'inferred') then
          raise exception 'Item %: confidence must be explicit, discussed or inferred (got "%").', v_n, v_raw;
        end if;
        v_confidence := v_raw::public.proposal_confidence;

        v_space := null;
        v_raw := private.digest_text(v_item, 'suggested_space', v_n, false, 40);
        if v_raw is not null then
          if v_raw !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
            raise exception 'Item %: suggested_space must be a space id.', v_n;
          end if;
          v_space := v_raw::uuid;
          if not exists (select 1 from public.spaces s where s.id = v_space and s.archived_at is null) then
            raise exception 'Item %: suggested_space is not an open space (use list_spaces).', v_n;
          end if;
        end if;

        v_duplicate := null;
        v_raw := private.digest_text(v_item, 'possible_duplicate_of', v_n, false, 40);
        if v_raw is not null then
          if v_raw !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
            raise exception 'Item %: possible_duplicate_of must be an item id.', v_n;
          end if;
          v_duplicate := v_raw::uuid;
          if not exists (select 1 from public.items i where i.id = v_duplicate) then
            raise exception 'Item %: possible_duplicate_of is not an existing item.', v_n;
          end if;
        end if;

        v_assignee := null;
        v_due := null;
        v_raw := private.digest_text(v_item, 'suggested_assignee', v_n, false, 40);
        if v_raw is not null then
          if v_kind <> 'task' then
            raise exception 'Item %: suggested_assignee is only for tasks.', v_n;
          end if;
          if v_raw !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
            raise exception 'Item %: suggested_assignee must be a member id.', v_n;
          end if;
          v_assignee := v_raw::uuid;
          if not exists (select 1 from public.members m where m.id = v_assignee) then
            raise exception 'Item %: suggested_assignee is not a studio member.', v_n;
          end if;
        end if;
        v_raw := private.digest_text(v_item, 'suggested_due_date', v_n, false, 10);
        if v_raw is not null then
          if v_kind <> 'task' then
            raise exception 'Item %: suggested_due_date is only for tasks.', v_n;
          end if;
          if v_raw !~ '^\d{4}-\d{2}-\d{2}$' then
            raise exception 'Item %: suggested_due_date must look like 2026-11-30.', v_n;
          end if;
          begin
            v_due := v_raw::date;
          exception when others then
            raise exception 'Item %: suggested_due_date is not a real date.', v_n;
          end;
        end if;

        if v_pass = 2 then
          v_id := null;
          insert into public.proposals (
            source_id, batch_index, kind, title, summary_md, quote, quote_translation, confidence,
            suggested_space_id, suggested_assignee_id, suggested_due_date, possible_duplicate_of,
            proposed_by, created_via
          )
          values (
            propose_items.source_id, v_start + v_n - 1, v_kind, v_title, v_summary, v_quote, v_translation,
            v_confidence, v_space, v_assignee, v_due, v_duplicate, v_uid, v_via
          )
          on conflict on constraint proposals_source_batch_key do nothing
          returning id into v_id;
          if v_id is null then
            v_existing := v_existing + 1;
          else
            v_created := v_created + 1;
          end if;
        end if;
      end;
    end loop;
  end loop;

  -- At most 1000 proposals waiting per member. Counted after the inserts: raising here rolls the
  -- whole call back, and a pure retry (nothing new) never changes the count.
  select count(*) into v_pending from public.proposals p where p.proposed_by = v_uid and p.state = 'pending';
  if v_pending > 1000 then
    raise exception 'Too many proposals are waiting: % pending from you (the limit is 1000). Triage the inbox before proposing more.', v_pending
      using errcode = '54000';
  end if;

  select coalesce(jsonb_agg(to_jsonb(p) order by p.batch_index), '[]')
  into v_rows
  from public.proposals p
  where p.source_id = propose_items.source_id
    and p.batch_index between v_start and v_start + v_count - 1;

  return jsonb_build_object('created', v_created, 'existing', v_existing, 'proposals', v_rows);
end;
$_$;


ALTER FUNCTION "public"."propose_items"("source_id" "uuid", "items" "jsonb", "start_index" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."propose_items"("source_id" "uuid", "items" "jsonb", "start_index" integer) IS 'Connector tool and Import digest: adds pending proposals from a jenova-digest/v1 batch. Retries return the existing rows. At most 500 per source, 1000 pending per member.';



CREATE OR REPLACE FUNCTION "public"."restore_proposal"("proposal_id" "uuid") RETURNS "public"."proposals"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_uid uuid := private.require_member();
  v_p public.proposals;
begin
  select * into v_p from public.proposals p where p.id = restore_proposal.proposal_id for update;
  if not found then
    raise exception 'There is no proposal with id %.', restore_proposal.proposal_id using errcode = 'P0002';
  end if;
  if v_p.state <> 'dismissed' then
    raise exception 'Only a dismissed proposal can be restored (this one is %).', v_p.state;
  end if;

  update public.proposals p
  set state = 'pending', triaged_by = null, triaged_at = null
  where p.id = v_p.id
  returning * into v_p;

  perform private.log_activity('status_changed', null, v_p.suggested_space_id, v_p.source_id,
    jsonb_build_object('proposal_id', v_p.id, 'title', v_p.title, 'from', 'dismissed', 'to', 'pending'));
  return v_p;
end;
$$;


ALTER FUNCTION "public"."restore_proposal"("proposal_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."restore_proposal"("proposal_id" "uuid") IS 'Flow 3: puts a dismissed proposal back in the inbox.';



CREATE OR REPLACE FUNCTION "public"."save_document"("item_id" "uuid", "expected_version" integer, "title" "text", "content_json" "jsonb", "content_md" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_uid uuid := private.require_member();
  v_old public.items;
  v_new public.items;
  v_last_snapshot timestamptz;
  v_snapshot boolean := false;
  v_file_ids uuid[];
  v_unknown uuid[];
  v_sealed_at timestamptz;
begin
  if save_document.expected_version is null then
    raise exception 'save_document needs the version you started from (expected_version).' using errcode = '22004';
  end if;

  v_old := private.get_item(save_document.item_id);

  if v_old.version <> save_document.expected_version then
    return jsonb_build_object(
      'status', 'conflict',
      'version', v_old.version,
      'updated_by', v_old.updated_by,
      'updated_at', v_old.updated_at
    );
  end if;

  select max(v.created_at) into v_last_snapshot from public.item_versions v where v.item_id = v_old.id;
  if (v_last_snapshot is null or v_last_snapshot <= now() - interval '1 hour')
     and (v_old.content_md <> '' or v_old.content_json is not null) then
    insert into public.item_versions (item_id, version, title, content_json, content_md, created_by)
    values (v_old.id, v_old.version, v_old.title, v_old.content_json, v_old.content_md, v_old.updated_by);
    v_snapshot := true;
  end if;

  update public.items i
  set title = btrim(save_document.title),
      content_json = save_document.content_json,
      content_md = coalesce(save_document.content_md, ''),
      version = i.version + 1,
      updated_by = v_uid,
      updated_at = now()
  where i.id = v_old.id
  returning * into v_new;

  -- Inline image sync.
  select coalesce(array_agg(distinct x.file_id::uuid), '{}')
  into v_file_ids
  from (
    select n #>> '{}' as file_id
    from jsonb_path_query(coalesce(save_document.content_json, 'null'::jsonb), 'lax $.**.attrs.fileId') n
  ) x
  where x.file_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';

  delete from public.item_files f
  where f.item_id = v_new.id and f.role = 'inline' and not (f.file_id = any (v_file_ids));

  insert into public.item_files (item_id, file_id, role)
  select v_new.id, f.id, 'inline' from public.files f where f.id = any (v_file_ids)
  on conflict do nothing;

  v_unknown := array(select unnest(v_file_ids) except select f.id from public.files f);

  -- Edits to a sealed doc show up in "Since you last looked": one entry per editor per hour.
  select d.sealed_at into v_sealed_at from public.docs d where d.item_id = v_new.id and d.state = 'sealed';
  if v_sealed_at is not null and not exists (
    select 1 from public.activity a
    where a.item_id = v_new.id and a.verb = 'edited_after_seal' and a.actor_id = v_uid
      and a.at >= greatest(v_sealed_at, now() - interval '1 hour')
  ) then
    perform private.log_activity('edited_after_seal', v_new.id, null, null, jsonb_build_object('version', v_new.version));
  end if;

  return jsonb_build_object(
    'status', 'saved',
    'version', v_new.version,
    'snapshot', v_snapshot,
    'unknown_file_ids', to_jsonb(v_unknown)
  );
end;
$_$;


ALTER FUNCTION "public"."save_document"("item_id" "uuid", "expected_version" integer, "title" "text", "content_json" "jsonb", "content_md" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."docs" (
    "item_id" "uuid" NOT NULL,
    "kind" "public"."item_kind" DEFAULT 'doc'::"public"."item_kind" NOT NULL,
    "state" "public"."doc_state" DEFAULT 'draft'::"public"."doc_state" NOT NULL,
    "sealed_by" "uuid",
    "sealed_at" timestamp with time zone,
    CONSTRAINT "docs_kind_check" CHECK (("kind" = 'doc'::"public"."item_kind")),
    CONSTRAINT "docs_seal_consistent" CHECK ((("state" = 'sealed'::"public"."doc_state") = ("sealed_at" IS NOT NULL)))
);


ALTER TABLE "public"."docs" OWNER TO "postgres";


COMMENT ON COLUMN "public"."docs"."state" IS 'Sealed is a "this is settled" flag, not a lock: sealed docs stay editable.';



CREATE OR REPLACE FUNCTION "public"."seal_doc"("item_id" "uuid") RETURNS "public"."docs"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_uid uuid := private.require_member();
  v_item public.items;
  v_doc public.docs;
begin
  v_item := private.get_item(seal_doc.item_id, 'doc');
  select * into v_doc from public.docs d where d.item_id = v_item.id;
  if v_doc.state = 'sealed' then
    return v_doc;
  end if;

  update public.docs d set state = 'sealed', sealed_by = v_uid, sealed_at = now()
  where d.item_id = v_item.id
  returning * into v_doc;

  perform private.log_activity('sealed', v_item.id);
  return v_doc;
end;
$$;


ALTER FUNCTION "public"."seal_doc"("item_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."search_all"("q" "text", "filters" "jsonb" DEFAULT '{}'::"jsonb") RETURNS TABLE("result_type" "text", "id" "uuid", "item_id" "uuid", "number" bigint, "kind" "public"."item_kind", "title" "text", "snippet" "text", "space_id" "uuid", "status" "text", "created_by" "uuid", "created_via" "public"."created_via", "created_at" timestamp with time zone, "rank" real)
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  with
  params as (
    select
      public.search_query(q) as tsq,
      (f ->> 'space_id')::uuid as space_id,
      (f ->> 'kind')::public.item_kind as kind,
      f ->> 'status' as status,
      (f ->> 'created_by')::uuid as created_by,
      coalesce((f ->> 'from_claude')::boolean, false) as from_claude,
      case when jsonb_typeof(f -> 'types') = 'array' then array(select jsonb_array_elements_text(f -> 'types'))
           else array['item', 'source', 'comment'] end as types,
      coalesce((f ->> 'include_archived')::boolean, false) as include_archived,
      least(greatest(coalesce((f ->> 'limit')::integer, 50), 1), 200) as max_rows
    from (select coalesce(filters, '{}'::jsonb) as f) as input
  ),
  item_rows as (
    select i.*, coalesce(d.status::text, t.status::text, c.state::text) as item_status
    from public.items i
    left join public.ideas d on d.item_id = i.id
    left join public.tasks t on t.item_id = i.id
    left join public.docs c on c.item_id = i.id
  ),
  results as (
    select 'item'::text as result_type, i.id as id, i.id as item_id, i.number as number, i.kind as kind,
           i.title as title,
           left(regexp_replace(i.content_md, '\s+', ' ', 'g'), 240) as snippet,
           i.space_id as space_id, i.item_status as status, i.created_by as created_by,
           i.created_via as created_via, i.created_at as created_at,
           ts_rank(i.search, p.tsq) as score
    from item_rows i, params p
    where 'item' = any (p.types)
      and i.search @@ p.tsq
      and (p.include_archived or i.archived_at is null)
      and (p.space_id is null or i.space_id = p.space_id)
      and (p.kind is null or i.kind = p.kind)
      and (p.status is null or i.item_status = p.status)
      and (p.created_by is null or i.created_by = p.created_by)
      and (not p.from_claude or i.created_via = 'claude')

    union all

    select 'source', s.id, null, null, null, s.title,
           left(regexp_replace(coalesce(s.cleaned_md, s.raw_text), '\s+', ' ', 'g'), 240),
           s.space_id, null, s.created_by, s.created_via, s.created_at,
           ts_rank(s.search, p.tsq)
    from public.sources s, params p
    where 'source' = any (p.types)
      and s.search @@ p.tsq
      and p.kind is null
      and p.status is null
      and (p.space_id is null or s.space_id = p.space_id)
      and (p.created_by is null or s.created_by = p.created_by)
      and (not p.from_claude or s.created_via = 'claude')

    union all

    select 'comment', c.id, i.id, i.number, i.kind, i.title,
           left(regexp_replace(c.body_md, '\s+', ' ', 'g'), 240),
           i.space_id, null, c.author_id, 'app'::public.created_via, c.created_at,
           ts_rank(c.search, p.tsq)
    from public.comments c
    join public.items i on i.id = c.item_id
    cross join params p
    where 'comment' = any (p.types)
      and c.search @@ p.tsq
      and c.deleted_at is null
      and (p.include_archived or i.archived_at is null)
      and p.status is null
      and not p.from_claude
      and (p.space_id is null or i.space_id = p.space_id)
      and (p.kind is null or i.kind = p.kind)
      and (p.created_by is null or c.author_id = p.created_by)
  )
  select * from results r
  order by r.score desc, r.created_at desc
  limit (select max_rows from params);
$$;


ALTER FUNCTION "public"."search_all"("q" "text", "filters" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."search_query"("q" "text") RETURNS "tsquery"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select to_tsquery('simple'::regconfig, string_agg(quote_literal(w) || ':*', ' & '))
  from regexp_split_to_table(lower(public.unaccent_text(coalesce(q, ''))), '[^[:alnum:]]+') as w
  where w <> '';
$$;


ALTER FUNCTION "public"."search_query"("q" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ideas" (
    "item_id" "uuid" NOT NULL,
    "kind" "public"."item_kind" DEFAULT 'idea'::"public"."item_kind" NOT NULL,
    "status" "public"."idea_status",
    "decided_by" "uuid"[] DEFAULT '{}'::"uuid"[] NOT NULL,
    "decided_at" timestamp with time zone,
    "cut_reason" "text",
    "consolidated_into" "uuid",
    "consolidated_kind" "public"."item_kind" DEFAULT 'doc'::"public"."item_kind" NOT NULL,
    CONSTRAINT "ideas_consolidated_kind_check" CHECK (("consolidated_kind" = 'doc'::"public"."item_kind")),
    CONSTRAINT "ideas_kind_check" CHECK (("kind" = 'idea'::"public"."item_kind"))
);


ALTER TABLE "public"."ideas" OWNER TO "postgres";


COMMENT ON COLUMN "public"."ideas"."status" IS 'null while the idea is in the inbox.';



COMMENT ON COLUMN "public"."ideas"."decided_by" IS 'Members who agreed to commit or cut (D6).';



CREATE OR REPLACE FUNCTION "public"."set_idea_status"("item_id" "uuid", "status" "public"."idea_status", "decided_by" "uuid"[] DEFAULT NULL::"uuid"[], "cut_reason" "text" DEFAULT NULL::"text") RETURNS "public"."ideas"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_uid uuid := private.require_member();
  v_item public.items;
  v_old public.ideas;
  v_new public.ideas;
  v_decision boolean := set_idea_status.status in ('committed', 'cut');
begin
  v_item := private.get_item(set_idea_status.item_id, 'idea');
  if set_idea_status.status is null then
    raise exception 'Pick a status for JNV-%.', v_item.number;
  end if;
  if set_idea_status.status = 'consolidated' then
    raise exception 'Use consolidate_into_doc() to consolidate JNV-%.', v_item.number;
  end if;

  select * into v_old from public.ideas d where d.item_id = v_item.id;

  update public.ideas d
  set status = set_idea_status.status,
      decided_by = case when v_decision then coalesce(set_idea_status.decided_by, '{}') else '{}' end,
      decided_at = case when v_decision then now() end,
      cut_reason = case when set_idea_status.status = 'cut' then btrim(set_idea_status.cut_reason) end,
      consolidated_into = null
  where d.item_id = v_item.id
  returning * into v_new;

  perform private.log_activity(
    case set_idea_status.status
      when 'committed' then 'committed'::public.activity_verb
      when 'cut' then 'cut'::public.activity_verb
      else 'status_changed'::public.activity_verb
    end,
    v_item.id, null, null,
    jsonb_build_object('from', v_old.status, 'to', v_new.status, 'decided_by', to_jsonb(v_new.decided_by), 'cut_reason', v_new.cut_reason)
  );
  return v_new;
end;
$$;


ALTER FUNCTION "public"."set_idea_status"("item_id" "uuid", "status" "public"."idea_status", "decided_by" "uuid"[], "cut_reason" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tasks" (
    "item_id" "uuid" NOT NULL,
    "kind" "public"."item_kind" DEFAULT 'task'::"public"."item_kind" NOT NULL,
    "status" "public"."task_status" DEFAULT 'todo'::"public"."task_status" NOT NULL,
    "assignee_id" "uuid",
    "due_date" "date",
    "origin_idea_id" "uuid",
    "origin_kind" "public"."item_kind" DEFAULT 'idea'::"public"."item_kind" NOT NULL,
    "completed_at" timestamp with time zone,
    CONSTRAINT "tasks_kind_check" CHECK (("kind" = 'task'::"public"."item_kind")),
    CONSTRAINT "tasks_origin_kind_check" CHECK (("origin_kind" = 'idea'::"public"."item_kind"))
);


ALTER TABLE "public"."tasks" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_task_status"("item_id" "uuid", "status" "public"."task_status") RETURNS "public"."tasks"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_uid uuid := private.require_member();
  v_item public.items;
  v_old public.tasks;
  v_new public.tasks;
begin
  v_item := private.get_item(set_task_status.item_id, 'task');
  select * into v_old from public.tasks t where t.item_id = v_item.id;
  if v_old.status = set_task_status.status then
    return v_old;
  end if;

  update public.tasks t set status = set_task_status.status
  where t.item_id = v_item.id
  returning * into v_new;

  perform private.log_activity('status_changed', v_item.id, null, null, jsonb_build_object('from', v_old.status, 'to', v_new.status));
  return v_new;
end;
$$;


ALTER FUNCTION "public"."set_task_status"("item_id" "uuid", "status" "public"."task_status") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_tour_progress"("p_step" integer DEFAULT NULL::integer, "p_done" boolean DEFAULT false) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_uid uuid := private.require_member();
begin
  update public.members m
  set tour_step = case when p_done then null else p_step end,
      tour_done_at = case when p_done then now() else m.tour_done_at end
  where m.id = v_uid;
end;
$$;


ALTER FUNCTION "public"."set_tour_progress"("p_step" integer, "p_done" boolean) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."set_tour_progress"("p_step" integer, "p_done" boolean) IS 'Saves the caller''s own guided-tour progress: a step to resume at, or done (sets tour_done_at, clears the step).';



CREATE OR REPLACE FUNCTION "public"."unaccent_text"("value" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE STRICT PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select extensions.unaccent('extensions.unaccent'::regdictionary, value);
$$;


ALTER FUNCTION "public"."unaccent_text"("value" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."unseal_doc"("item_id" "uuid") RETURNS "public"."docs"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_uid uuid := private.require_member();
  v_item public.items;
  v_doc public.docs;
  v_was_sealed_by uuid;
begin
  v_item := private.get_item(unseal_doc.item_id, 'doc');
  select * into v_doc from public.docs d where d.item_id = v_item.id;
  if v_doc.state = 'draft' then
    return v_doc;
  end if;
  v_was_sealed_by := v_doc.sealed_by;

  update public.docs d set state = 'draft', sealed_by = null, sealed_at = null
  where d.item_id = v_item.id
  returning * into v_doc;

  perform private.log_activity('unsealed', v_item.id, null, null, jsonb_build_object('was_sealed_by', v_was_sealed_by));
  return v_doc;
end;
$$;


ALTER FUNCTION "public"."unseal_doc"("item_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."usage_stats"() RETURNS TABLE("db_bytes" bigint, "file_count" bigint, "file_bytes" bigint, "unreferenced_count" bigint, "unreferenced_bytes" bigint)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if public.is_connector() then
    raise exception 'Claude can only read Jenova and propose items: this change has to be made in the app.'
      using errcode = '42501';
  end if;
  if not (select public.is_admin()) then
    raise exception 'Only an admin can see the usage panel.' using errcode = '42501';
  end if;
  return query
  select
    pg_database_size(current_database())::bigint,
    count(*) filter (where f.status = 'ready'),
    coalesce(sum(f.bytes) filter (where f.status = 'ready'), 0)::bigint,
    count(*) filter (where u.id is not null),
    coalesce(sum(f.bytes) filter (where u.id is not null), 0)::bigint
  from public.files f
  left join public.files u
    on u.id = f.id
   and u.space_id is null
   and u.created_at < now() - interval '1 hour'
   and not exists (select 1 from public.item_files i where i.file_id = u.id)
   and not exists (select 1 from public.spaces s where s.cover_file_id = u.id);
end;
$$;


ALTER FUNCTION "public"."usage_stats"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."usage_stats"() IS 'Admin only: database size and file totals for the usage panel.';



CREATE TABLE IF NOT EXISTS "public"."activity" (
    "id" bigint NOT NULL,
    "at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "actor_id" "uuid",
    "actor_via" "public"."actor_via" DEFAULT 'app'::"public"."actor_via" NOT NULL,
    "verb" "public"."activity_verb" NOT NULL,
    "item_id" "uuid",
    "space_id" "uuid",
    "source_id" "uuid",
    "data" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL
);


ALTER TABLE "public"."activity" OWNER TO "postgres";


COMMENT ON TABLE "public"."activity" IS 'Append-only log. Feeds "Since you last looked" (at > last_seen_at, actor <> me) and decision history.';



ALTER TABLE "public"."activity" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."activity_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."comments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "item_id" "uuid" NOT NULL,
    "author_id" "uuid" DEFAULT "auth"."uid"(),
    "body_md" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "edited_at" timestamp with time zone,
    "deleted_at" timestamp with time zone,
    "search" "tsvector" GENERATED ALWAYS AS ("public"."search_vector"(NULL::"text", "body_md")) STORED,
    CONSTRAINT "comments_body_not_blank" CHECK (("length"("btrim"("body_md")) > 0))
);


ALTER TABLE "public"."comments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."files" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "status" "public"."file_status" DEFAULT 'pending'::"public"."file_status" NOT NULL,
    "mime" "text" NOT NULL,
    "bytes" bigint,
    "width" integer,
    "height" integer,
    "name" "text",
    "space_id" "uuid",
    "uploaded_by" "uuid" DEFAULT "auth"."uid"(),
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "files_bytes_check" CHECK (("bytes" >= 0)),
    CONSTRAINT "files_height_check" CHECK (("height" > 0)),
    CONSTRAINT "files_width_check" CHECK (("width" > 0))
);


ALTER TABLE "public"."files" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."item_files" (
    "item_id" "uuid" NOT NULL,
    "file_id" "uuid" NOT NULL,
    "role" "public"."file_role" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."item_files" OWNER TO "postgres";


COMMENT ON TABLE "public"."item_files" IS 'inline rows are kept in sync with the image nodes in content_json by save_document().';



CREATE TABLE IF NOT EXISTS "public"."item_sources" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "item_id" "uuid" NOT NULL,
    "source_id" "uuid" NOT NULL,
    "quote" "text",
    "created_by" "uuid" DEFAULT "auth"."uid"(),
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "quote_translation" "text"
);


ALTER TABLE "public"."item_sources" OWNER TO "postgres";


COMMENT ON COLUMN "public"."item_sources"."quote_translation" IS 'English translation of quote, carried from the proposal when it was accepted or merged.';



CREATE TABLE IF NOT EXISTS "public"."item_versions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "item_id" "uuid" NOT NULL,
    "version" integer NOT NULL,
    "title" "text" NOT NULL,
    "content_json" "jsonb",
    "content_md" "text" NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."item_versions" OWNER TO "postgres";


COMMENT ON TABLE "public"."item_versions" IS 'History snapshots. save_document() writes at most one per item per hour.';



ALTER TABLE "public"."items" ALTER COLUMN "number" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."items_number_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."members" (
    "id" "uuid" NOT NULL,
    "github_login" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "role" "text" DEFAULT 'member'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "avatar_url" "text",
    "last_seen_at" timestamp with time zone,
    "tour_step" integer,
    "tour_done_at" timestamp with time zone,
    CONSTRAINT "members_role_check" CHECK (("role" = ANY (ARRAY['admin'::"text", 'member'::"text"]))),
    CONSTRAINT "members_tour_step_check" CHECK ((("tour_step" IS NULL) OR ("tour_step" >= 0)))
);


ALTER TABLE "public"."members" OWNER TO "postgres";


COMMENT ON TABLE "public"."members" IS 'Studio members. RLS on every table checks public.is_member().';



COMMENT ON COLUMN "public"."members"."last_seen_at" IS 'The "Since you last looked" bookmark. Updated when Home is viewed.';



COMMENT ON COLUMN "public"."members"."tour_step" IS 'Guided tour: the step to resume at. Null when not started or finished.';



COMMENT ON COLUMN "public"."members"."tour_done_at" IS 'Guided tour: when the member finished or skipped it. Null means it has not been completed.';



CREATE TABLE IF NOT EXISTS "public"."sources" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "origin" "public"."source_origin" NOT NULL,
    "raw_text" "text" NOT NULL,
    "cleaned_md" "text",
    "processing_notes" "text",
    "external_ref" "text",
    "space_id" "uuid",
    "created_by" "uuid" DEFAULT "auth"."uid"(),
    "created_via" "public"."created_via" DEFAULT 'app'::"public"."created_via" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "search" "tsvector" GENERATED ALWAYS AS ("public"."search_vector"("title", COALESCE("cleaned_md", "raw_text"))) STORED,
    CONSTRAINT "sources_title_not_blank" CHECK (("length"("btrim"("title")) > 0))
);


ALTER TABLE "public"."sources" OWNER TO "postgres";


COMMENT ON COLUMN "public"."sources"."raw_text" IS 'Exactly what was pasted or imported. Never modified.';



COMMENT ON COLUMN "public"."sources"."cleaned_md" IS 'Transcripts: corrected text with visible corrections. Proposal quotes come from here.';



COMMENT ON COLUMN "public"."sources"."external_ref" IS 'E.g. a Drive file id. Unique, so a file is never digested twice.';



CREATE TABLE IF NOT EXISTS "public"."spaces" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "slug" "text" NOT NULL,
    "pitch_item_id" "uuid",
    "pitch_kind" "public"."item_kind" DEFAULT 'doc'::"public"."item_kind" NOT NULL,
    "cover_file_id" "uuid",
    "is_studio" boolean DEFAULT false NOT NULL,
    "facts_item_id" "uuid",
    "facts_kind" "public"."item_kind" DEFAULT 'doc'::"public"."item_kind" NOT NULL,
    "archived_at" timestamp with time zone,
    "created_by" "uuid" DEFAULT "auth"."uid"(),
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "spaces_facts_kind_check" CHECK (("facts_kind" = 'doc'::"public"."item_kind")),
    CONSTRAINT "spaces_facts_only_on_studio" CHECK ((("facts_item_id" IS NULL) OR "is_studio")),
    CONSTRAINT "spaces_name_not_blank" CHECK (("length"("btrim"("name")) > 0)),
    CONSTRAINT "spaces_pitch_kind_check" CHECK (("pitch_kind" = 'doc'::"public"."item_kind")),
    CONSTRAINT "spaces_slug_format" CHECK (("slug" ~ '^[a-z0-9]+(-[a-z0-9]+)*$'::"text"))
);


ALTER TABLE "public"."spaces" OWNER TO "postgres";


COMMENT ON TABLE "public"."spaces" IS 'A game, prototype or the Studio. The inbox is not a space: it is items with space_id null.';



COMMENT ON COLUMN "public"."spaces"."is_studio" IS 'Exactly one space is the Studio. It can''t be archived or deleted.';



COMMENT ON COLUMN "public"."spaces"."facts_item_id" IS 'Studio only: the Studio facts doc Claude reads before every digest.';



ALTER TABLE ONLY "public"."activity"
    ADD CONSTRAINT "activity_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."docs"
    ADD CONSTRAINT "docs_pkey" PRIMARY KEY ("item_id");



ALTER TABLE ONLY "public"."files"
    ADD CONSTRAINT "files_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ideas"
    ADD CONSTRAINT "ideas_pkey" PRIMARY KEY ("item_id");



ALTER TABLE ONLY "public"."item_files"
    ADD CONSTRAINT "item_files_pkey" PRIMARY KEY ("item_id", "file_id", "role");



ALTER TABLE ONLY "public"."item_links"
    ADD CONSTRAINT "item_links_pkey" PRIMARY KEY ("from_item", "to_item", "type");



ALTER TABLE ONLY "public"."item_sources"
    ADD CONSTRAINT "item_sources_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."item_versions"
    ADD CONSTRAINT "item_versions_item_version_key" UNIQUE ("item_id", "version");



ALTER TABLE ONLY "public"."item_versions"
    ADD CONSTRAINT "item_versions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."items"
    ADD CONSTRAINT "items_id_kind_key" UNIQUE ("id", "kind");



ALTER TABLE ONLY "public"."items"
    ADD CONSTRAINT "items_number_key" UNIQUE ("number");



ALTER TABLE ONLY "public"."items"
    ADD CONSTRAINT "items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."members"
    ADD CONSTRAINT "members_github_login_key" UNIQUE ("github_login");



ALTER TABLE ONLY "public"."members"
    ADD CONSTRAINT "members_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."proposals"
    ADD CONSTRAINT "proposals_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."proposals"
    ADD CONSTRAINT "proposals_source_batch_key" UNIQUE ("source_id", "batch_index");



ALTER TABLE ONLY "public"."sources"
    ADD CONSTRAINT "sources_external_ref_key" UNIQUE ("external_ref");



ALTER TABLE ONLY "public"."sources"
    ADD CONSTRAINT "sources_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."spaces"
    ADD CONSTRAINT "spaces_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."spaces"
    ADD CONSTRAINT "spaces_slug_key" UNIQUE ("slug");



ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_pkey" PRIMARY KEY ("item_id");



CREATE INDEX "activity_at_idx" ON "public"."activity" USING "btree" ("at" DESC);



CREATE INDEX "activity_item_idx" ON "public"."activity" USING "btree" ("item_id", "at" DESC);



CREATE INDEX "activity_space_idx" ON "public"."activity" USING "btree" ("space_id", "at" DESC);



CREATE INDEX "comments_item_idx" ON "public"."comments" USING "btree" ("item_id", "created_at");



CREATE INDEX "comments_search_idx" ON "public"."comments" USING "gin" ("search");



CREATE INDEX "files_space_idx" ON "public"."files" USING "btree" ("space_id") WHERE ("space_id" IS NOT NULL);



CREATE INDEX "ideas_consolidated_into_idx" ON "public"."ideas" USING "btree" ("consolidated_into") WHERE ("consolidated_into" IS NOT NULL);



CREATE INDEX "ideas_status_idx" ON "public"."ideas" USING "btree" ("status");



CREATE INDEX "item_files_file_idx" ON "public"."item_files" USING "btree" ("file_id");



CREATE UNIQUE INDEX "item_links_relates_once" ON "public"."item_links" USING "btree" (LEAST("from_item", "to_item"), GREATEST("from_item", "to_item")) WHERE ("type" = 'relates_to'::"public"."link_type");



CREATE INDEX "item_links_to_item_idx" ON "public"."item_links" USING "btree" ("to_item");



CREATE INDEX "item_sources_source_idx" ON "public"."item_sources" USING "btree" ("source_id");



CREATE UNIQUE INDEX "item_sources_unique_quote" ON "public"."item_sources" USING "btree" ("item_id", "source_id", "md5"(COALESCE("quote", ''::"text")));



CREATE INDEX "item_versions_item_idx" ON "public"."item_versions" USING "btree" ("item_id", "created_at" DESC);



CREATE INDEX "items_search_idx" ON "public"."items" USING "gin" ("search");



CREATE INDEX "items_space_idx" ON "public"."items" USING "btree" ("space_id", "kind") WHERE ("archived_at" IS NULL);



CREATE INDEX "proposals_pending_idx" ON "public"."proposals" USING "btree" ("created_at") WHERE ("state" = 'pending'::"public"."proposal_state");



CREATE INDEX "sources_search_idx" ON "public"."sources" USING "gin" ("search");



CREATE INDEX "sources_space_idx" ON "public"."sources" USING "btree" ("space_id");



CREATE UNIQUE INDEX "spaces_single_studio" ON "public"."spaces" USING "btree" ("is_studio") WHERE "is_studio";



CREATE INDEX "tasks_assignee_idx" ON "public"."tasks" USING "btree" ("assignee_id", "status");



CREATE INDEX "tasks_origin_idea_idx" ON "public"."tasks" USING "btree" ("origin_idea_id") WHERE ("origin_idea_id" IS NOT NULL);



CREATE OR REPLACE TRIGGER "comments_log" AFTER INSERT ON "public"."comments" FOR EACH ROW EXECUTE FUNCTION "private"."log_direct_write"();



CREATE OR REPLACE TRIGGER "comments_stamp_edit" BEFORE UPDATE ON "public"."comments" FOR EACH ROW EXECUTE FUNCTION "private"."stamp_comment_edit"();



CREATE CONSTRAINT TRIGGER "docs_keep_kind_row" AFTER DELETE OR UPDATE OF "item_id" ON "public"."docs" DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION "private"."check_item_has_one_kind_row"();



CREATE OR REPLACE TRIGGER "docs_match_item" BEFORE INSERT OR UPDATE OF "item_id", "kind" ON "public"."docs" FOR EACH ROW EXECUTE FUNCTION "private"."kind_row_matches_item"();



CREATE OR REPLACE TRIGGER "files_guard_status" BEFORE UPDATE OF "status" ON "public"."files" FOR EACH ROW EXECUTE FUNCTION "private"."guard_file_status"();



CREATE OR REPLACE TRIGGER "ideas_check_rules" BEFORE INSERT OR UPDATE ON "public"."ideas" FOR EACH ROW EXECUTE FUNCTION "private"."check_idea_rules"();



CREATE CONSTRAINT TRIGGER "ideas_keep_kind_row" AFTER DELETE OR UPDATE OF "item_id" ON "public"."ideas" DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION "private"."check_item_has_one_kind_row"();



CREATE OR REPLACE TRIGGER "ideas_match_item" BEFORE INSERT OR UPDATE OF "item_id", "kind" ON "public"."ideas" FOR EACH ROW EXECUTE FUNCTION "private"."kind_row_matches_item"();



CREATE OR REPLACE TRIGGER "item_links_check" BEFORE INSERT OR UPDATE ON "public"."item_links" FOR EACH ROW EXECUTE FUNCTION "private"."check_item_link"();



CREATE OR REPLACE TRIGGER "items_check_write" BEFORE INSERT OR UPDATE ON "public"."items" FOR EACH ROW EXECUTE FUNCTION "private"."check_item_write"();



CREATE CONSTRAINT TRIGGER "items_exactly_one_kind_row" AFTER INSERT OR UPDATE OF "kind" ON "public"."items" DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION "private"."check_item_has_one_kind_row"();



CREATE OR REPLACE TRIGGER "items_guard_key_doc_archive" BEFORE UPDATE OF "archived_at" ON "public"."items" FOR EACH ROW WHEN ((("old"."archived_at" IS NULL) AND ("new"."archived_at" IS NOT NULL))) EXECUTE FUNCTION "private"."guard_key_doc_archive"();



CREATE OR REPLACE TRIGGER "members_guard_role" BEFORE DELETE OR UPDATE OF "role" ON "public"."members" FOR EACH ROW EXECUTE FUNCTION "private"."guard_member_role"();



CREATE OR REPLACE TRIGGER "sources_guard" BEFORE UPDATE ON "public"."sources" FOR EACH ROW EXECUTE FUNCTION "private"."guard_source"();



CREATE OR REPLACE TRIGGER "spaces_guard" BEFORE INSERT OR DELETE OR UPDATE ON "public"."spaces" FOR EACH ROW EXECUTE FUNCTION "private"."guard_space"();



CREATE OR REPLACE TRIGGER "spaces_log_created" AFTER INSERT ON "public"."spaces" FOR EACH ROW EXECUTE FUNCTION "private"."log_direct_write"();



CREATE OR REPLACE TRIGGER "tasks_completion" BEFORE INSERT OR UPDATE OF "status" ON "public"."tasks" FOR EACH ROW EXECUTE FUNCTION "private"."maintain_task_completion"();



CREATE CONSTRAINT TRIGGER "tasks_keep_kind_row" AFTER DELETE OR UPDATE OF "item_id" ON "public"."tasks" DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION "private"."check_item_has_one_kind_row"();



CREATE OR REPLACE TRIGGER "tasks_log_assigned" AFTER UPDATE OF "assignee_id" ON "public"."tasks" FOR EACH ROW WHEN (("old"."assignee_id" IS DISTINCT FROM "new"."assignee_id")) EXECUTE FUNCTION "private"."log_direct_write"();



CREATE OR REPLACE TRIGGER "tasks_match_item" BEFORE INSERT OR UPDATE OF "item_id", "kind" ON "public"."tasks" FOR EACH ROW EXECUTE FUNCTION "private"."kind_row_matches_item"();



ALTER TABLE ONLY "public"."activity"
    ADD CONSTRAINT "activity_actor_id_fkey" FOREIGN KEY ("actor_id") REFERENCES "public"."members"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."activity"
    ADD CONSTRAINT "activity_item_id_fkey" FOREIGN KEY ("item_id") REFERENCES "public"."items"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."activity"
    ADD CONSTRAINT "activity_source_id_fkey" FOREIGN KEY ("source_id") REFERENCES "public"."sources"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."activity"
    ADD CONSTRAINT "activity_space_id_fkey" FOREIGN KEY ("space_id") REFERENCES "public"."spaces"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "public"."members"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_item_id_fkey" FOREIGN KEY ("item_id") REFERENCES "public"."items"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."docs"
    ADD CONSTRAINT "docs_item_fkey" FOREIGN KEY ("item_id", "kind") REFERENCES "public"."items"("id", "kind") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."docs"
    ADD CONSTRAINT "docs_sealed_by_fkey" FOREIGN KEY ("sealed_by") REFERENCES "public"."members"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."files"
    ADD CONSTRAINT "files_space_id_fkey" FOREIGN KEY ("space_id") REFERENCES "public"."spaces"("id");



ALTER TABLE ONLY "public"."files"
    ADD CONSTRAINT "files_uploaded_by_fkey" FOREIGN KEY ("uploaded_by") REFERENCES "public"."members"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."ideas"
    ADD CONSTRAINT "ideas_consolidated_into_doc" FOREIGN KEY ("consolidated_into", "consolidated_kind") REFERENCES "public"."items"("id", "kind");



ALTER TABLE ONLY "public"."ideas"
    ADD CONSTRAINT "ideas_item_fkey" FOREIGN KEY ("item_id", "kind") REFERENCES "public"."items"("id", "kind") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."item_files"
    ADD CONSTRAINT "item_files_file_id_fkey" FOREIGN KEY ("file_id") REFERENCES "public"."files"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."item_files"
    ADD CONSTRAINT "item_files_item_id_fkey" FOREIGN KEY ("item_id") REFERENCES "public"."items"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."item_links"
    ADD CONSTRAINT "item_links_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."members"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."item_links"
    ADD CONSTRAINT "item_links_from_item_fkey" FOREIGN KEY ("from_item") REFERENCES "public"."items"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."item_links"
    ADD CONSTRAINT "item_links_to_item_fkey" FOREIGN KEY ("to_item") REFERENCES "public"."items"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."item_sources"
    ADD CONSTRAINT "item_sources_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."members"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."item_sources"
    ADD CONSTRAINT "item_sources_item_id_fkey" FOREIGN KEY ("item_id") REFERENCES "public"."items"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."item_sources"
    ADD CONSTRAINT "item_sources_source_id_fkey" FOREIGN KEY ("source_id") REFERENCES "public"."sources"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."item_versions"
    ADD CONSTRAINT "item_versions_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."members"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."item_versions"
    ADD CONSTRAINT "item_versions_item_id_fkey" FOREIGN KEY ("item_id") REFERENCES "public"."items"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."items"
    ADD CONSTRAINT "items_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."members"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."items"
    ADD CONSTRAINT "items_space_id_fkey" FOREIGN KEY ("space_id") REFERENCES "public"."spaces"("id");



ALTER TABLE ONLY "public"."items"
    ADD CONSTRAINT "items_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "public"."members"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."members"
    ADD CONSTRAINT "members_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."proposals"
    ADD CONSTRAINT "proposals_possible_duplicate_of_fkey" FOREIGN KEY ("possible_duplicate_of") REFERENCES "public"."items"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."proposals"
    ADD CONSTRAINT "proposals_proposed_by_fkey" FOREIGN KEY ("proposed_by") REFERENCES "public"."members"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."proposals"
    ADD CONSTRAINT "proposals_resulting_item_id_fkey" FOREIGN KEY ("resulting_item_id") REFERENCES "public"."items"("id");



ALTER TABLE ONLY "public"."proposals"
    ADD CONSTRAINT "proposals_source_id_fkey" FOREIGN KEY ("source_id") REFERENCES "public"."sources"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."proposals"
    ADD CONSTRAINT "proposals_suggested_assignee_id_fkey" FOREIGN KEY ("suggested_assignee_id") REFERENCES "public"."members"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."proposals"
    ADD CONSTRAINT "proposals_suggested_space_id_fkey" FOREIGN KEY ("suggested_space_id") REFERENCES "public"."spaces"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."proposals"
    ADD CONSTRAINT "proposals_triaged_by_fkey" FOREIGN KEY ("triaged_by") REFERENCES "public"."members"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."sources"
    ADD CONSTRAINT "sources_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."members"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."sources"
    ADD CONSTRAINT "sources_space_id_fkey" FOREIGN KEY ("space_id") REFERENCES "public"."spaces"("id");



ALTER TABLE ONLY "public"."spaces"
    ADD CONSTRAINT "spaces_cover_file_fkey" FOREIGN KEY ("cover_file_id") REFERENCES "public"."files"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."spaces"
    ADD CONSTRAINT "spaces_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."members"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."spaces"
    ADD CONSTRAINT "spaces_facts_is_doc" FOREIGN KEY ("facts_item_id", "facts_kind") REFERENCES "public"."items"("id", "kind");



ALTER TABLE ONLY "public"."spaces"
    ADD CONSTRAINT "spaces_pitch_is_doc" FOREIGN KEY ("pitch_item_id", "pitch_kind") REFERENCES "public"."items"("id", "kind");



ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_assignee_id_fkey" FOREIGN KEY ("assignee_id") REFERENCES "public"."members"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_item_fkey" FOREIGN KEY ("item_id", "kind") REFERENCES "public"."items"("id", "kind") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_origin_is_idea" FOREIGN KEY ("origin_idea_id", "origin_kind") REFERENCES "public"."items"("id", "kind");



CREATE POLICY "Admins add members" ON "public"."members" FOR INSERT TO "authenticated" WITH CHECK (( SELECT "public"."is_admin"() AS "is_admin"));



CREATE POLICY "Admins remove members" ON "public"."members" FOR DELETE TO "authenticated" USING (( SELECT "public"."is_admin"() AS "is_admin"));



CREATE POLICY "Authors edit their comments" ON "public"."comments" FOR UPDATE TO "authenticated" USING ((( SELECT "public"."is_member"() AS "is_member") AND ("author_id" = ( SELECT "auth"."uid"() AS "uid")))) WITH CHECK ((( SELECT "public"."is_member"() AS "is_member") AND ("author_id" = ( SELECT "auth"."uid"() AS "uid"))));



CREATE POLICY "Connector tokens cannot delete from activity" ON "public"."activity" AS RESTRICTIVE FOR DELETE TO "authenticated" USING ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot delete from comments" ON "public"."comments" AS RESTRICTIVE FOR DELETE TO "authenticated" USING ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot delete from docs" ON "public"."docs" AS RESTRICTIVE FOR DELETE TO "authenticated" USING ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot delete from files" ON "public"."files" AS RESTRICTIVE FOR DELETE TO "authenticated" USING ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot delete from ideas" ON "public"."ideas" AS RESTRICTIVE FOR DELETE TO "authenticated" USING ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot delete from item_files" ON "public"."item_files" AS RESTRICTIVE FOR DELETE TO "authenticated" USING ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot delete from item_links" ON "public"."item_links" AS RESTRICTIVE FOR DELETE TO "authenticated" USING ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot delete from item_sources" ON "public"."item_sources" AS RESTRICTIVE FOR DELETE TO "authenticated" USING ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot delete from item_versions" ON "public"."item_versions" AS RESTRICTIVE FOR DELETE TO "authenticated" USING ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot delete from items" ON "public"."items" AS RESTRICTIVE FOR DELETE TO "authenticated" USING ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot delete from members" ON "public"."members" AS RESTRICTIVE FOR DELETE TO "authenticated" USING ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot delete from proposals" ON "public"."proposals" AS RESTRICTIVE FOR DELETE TO "authenticated" USING ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot delete from sources" ON "public"."sources" AS RESTRICTIVE FOR DELETE TO "authenticated" USING ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot delete from spaces" ON "public"."spaces" AS RESTRICTIVE FOR DELETE TO "authenticated" USING ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot delete from tasks" ON "public"."tasks" AS RESTRICTIVE FOR DELETE TO "authenticated" USING ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot insert into activity" ON "public"."activity" AS RESTRICTIVE FOR INSERT TO "authenticated" WITH CHECK ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot insert into comments" ON "public"."comments" AS RESTRICTIVE FOR INSERT TO "authenticated" WITH CHECK ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot insert into docs" ON "public"."docs" AS RESTRICTIVE FOR INSERT TO "authenticated" WITH CHECK ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot insert into files" ON "public"."files" AS RESTRICTIVE FOR INSERT TO "authenticated" WITH CHECK ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot insert into ideas" ON "public"."ideas" AS RESTRICTIVE FOR INSERT TO "authenticated" WITH CHECK ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot insert into item_files" ON "public"."item_files" AS RESTRICTIVE FOR INSERT TO "authenticated" WITH CHECK ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot insert into item_links" ON "public"."item_links" AS RESTRICTIVE FOR INSERT TO "authenticated" WITH CHECK ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot insert into item_sources" ON "public"."item_sources" AS RESTRICTIVE FOR INSERT TO "authenticated" WITH CHECK ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot insert into item_versions" ON "public"."item_versions" AS RESTRICTIVE FOR INSERT TO "authenticated" WITH CHECK ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot insert into items" ON "public"."items" AS RESTRICTIVE FOR INSERT TO "authenticated" WITH CHECK ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot insert into members" ON "public"."members" AS RESTRICTIVE FOR INSERT TO "authenticated" WITH CHECK ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot insert into proposals" ON "public"."proposals" AS RESTRICTIVE FOR INSERT TO "authenticated" WITH CHECK ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot insert into sources" ON "public"."sources" AS RESTRICTIVE FOR INSERT TO "authenticated" WITH CHECK ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot insert into spaces" ON "public"."spaces" AS RESTRICTIVE FOR INSERT TO "authenticated" WITH CHECK ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot insert into tasks" ON "public"."tasks" AS RESTRICTIVE FOR INSERT TO "authenticated" WITH CHECK ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot update activity" ON "public"."activity" AS RESTRICTIVE FOR UPDATE TO "authenticated" USING ((NOT ( SELECT "public"."is_connector"() AS "is_connector"))) WITH CHECK ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot update comments" ON "public"."comments" AS RESTRICTIVE FOR UPDATE TO "authenticated" USING ((NOT ( SELECT "public"."is_connector"() AS "is_connector"))) WITH CHECK ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot update docs" ON "public"."docs" AS RESTRICTIVE FOR UPDATE TO "authenticated" USING ((NOT ( SELECT "public"."is_connector"() AS "is_connector"))) WITH CHECK ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot update files" ON "public"."files" AS RESTRICTIVE FOR UPDATE TO "authenticated" USING ((NOT ( SELECT "public"."is_connector"() AS "is_connector"))) WITH CHECK ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot update ideas" ON "public"."ideas" AS RESTRICTIVE FOR UPDATE TO "authenticated" USING ((NOT ( SELECT "public"."is_connector"() AS "is_connector"))) WITH CHECK ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot update item_files" ON "public"."item_files" AS RESTRICTIVE FOR UPDATE TO "authenticated" USING ((NOT ( SELECT "public"."is_connector"() AS "is_connector"))) WITH CHECK ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot update item_links" ON "public"."item_links" AS RESTRICTIVE FOR UPDATE TO "authenticated" USING ((NOT ( SELECT "public"."is_connector"() AS "is_connector"))) WITH CHECK ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot update item_sources" ON "public"."item_sources" AS RESTRICTIVE FOR UPDATE TO "authenticated" USING ((NOT ( SELECT "public"."is_connector"() AS "is_connector"))) WITH CHECK ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot update item_versions" ON "public"."item_versions" AS RESTRICTIVE FOR UPDATE TO "authenticated" USING ((NOT ( SELECT "public"."is_connector"() AS "is_connector"))) WITH CHECK ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot update items" ON "public"."items" AS RESTRICTIVE FOR UPDATE TO "authenticated" USING ((NOT ( SELECT "public"."is_connector"() AS "is_connector"))) WITH CHECK ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot update members" ON "public"."members" AS RESTRICTIVE FOR UPDATE TO "authenticated" USING ((NOT ( SELECT "public"."is_connector"() AS "is_connector"))) WITH CHECK ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot update proposals" ON "public"."proposals" AS RESTRICTIVE FOR UPDATE TO "authenticated" USING ((NOT ( SELECT "public"."is_connector"() AS "is_connector"))) WITH CHECK ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot update sources" ON "public"."sources" AS RESTRICTIVE FOR UPDATE TO "authenticated" USING ((NOT ( SELECT "public"."is_connector"() AS "is_connector"))) WITH CHECK ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot update spaces" ON "public"."spaces" AS RESTRICTIVE FOR UPDATE TO "authenticated" USING ((NOT ( SELECT "public"."is_connector"() AS "is_connector"))) WITH CHECK ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Connector tokens cannot update tasks" ON "public"."tasks" AS RESTRICTIVE FOR UPDATE TO "authenticated" USING ((NOT ( SELECT "public"."is_connector"() AS "is_connector"))) WITH CHECK ((NOT ( SELECT "public"."is_connector"() AS "is_connector")));



CREATE POLICY "Members archive items" ON "public"."items" FOR UPDATE TO "authenticated" USING (( SELECT "public"."is_member"() AS "is_member")) WITH CHECK (( SELECT "public"."is_member"() AS "is_member"));



CREATE POLICY "Members assign tasks" ON "public"."tasks" FOR UPDATE TO "authenticated" USING (( SELECT "public"."is_member"() AS "is_member")) WITH CHECK (( SELECT "public"."is_member"() AS "is_member"));



CREATE POLICY "Members attach files" ON "public"."item_files" FOR INSERT TO "authenticated" WITH CHECK ((( SELECT "public"."is_member"() AS "is_member") AND ("role" = 'attachment'::"public"."file_role")));



CREATE POLICY "Members can read activity" ON "public"."activity" FOR SELECT TO "authenticated" USING (( SELECT "public"."is_member"() AS "is_member"));



CREATE POLICY "Members can read comments" ON "public"."comments" FOR SELECT TO "authenticated" USING (( SELECT "public"."is_member"() AS "is_member"));



CREATE POLICY "Members can read docs" ON "public"."docs" FOR SELECT TO "authenticated" USING (( SELECT "public"."is_member"() AS "is_member"));



CREATE POLICY "Members can read files" ON "public"."files" FOR SELECT TO "authenticated" USING (( SELECT "public"."is_member"() AS "is_member"));



CREATE POLICY "Members can read ideas" ON "public"."ideas" FOR SELECT TO "authenticated" USING (( SELECT "public"."is_member"() AS "is_member"));



CREATE POLICY "Members can read item_files" ON "public"."item_files" FOR SELECT TO "authenticated" USING (( SELECT "public"."is_member"() AS "is_member"));



CREATE POLICY "Members can read item_links" ON "public"."item_links" FOR SELECT TO "authenticated" USING (( SELECT "public"."is_member"() AS "is_member"));



CREATE POLICY "Members can read item_sources" ON "public"."item_sources" FOR SELECT TO "authenticated" USING (( SELECT "public"."is_member"() AS "is_member"));



CREATE POLICY "Members can read item_versions" ON "public"."item_versions" FOR SELECT TO "authenticated" USING (( SELECT "public"."is_member"() AS "is_member"));



CREATE POLICY "Members can read items" ON "public"."items" FOR SELECT TO "authenticated" USING (( SELECT "public"."is_member"() AS "is_member"));



CREATE POLICY "Members can read members" ON "public"."members" FOR SELECT TO "authenticated" USING (( SELECT "public"."is_member"() AS "is_member"));



CREATE POLICY "Members can read proposals" ON "public"."proposals" FOR SELECT TO "authenticated" USING (( SELECT "public"."is_member"() AS "is_member"));



CREATE POLICY "Members can read sources" ON "public"."sources" FOR SELECT TO "authenticated" USING (( SELECT "public"."is_member"() AS "is_member"));



CREATE POLICY "Members can read spaces" ON "public"."spaces" FOR SELECT TO "authenticated" USING (( SELECT "public"."is_member"() AS "is_member"));



CREATE POLICY "Members can read tasks" ON "public"."tasks" FOR SELECT TO "authenticated" USING (( SELECT "public"."is_member"() AS "is_member"));



CREATE POLICY "Members comment as themselves" ON "public"."comments" FOR INSERT TO "authenticated" WITH CHECK ((( SELECT "public"."is_member"() AS "is_member") AND ("author_id" = ( SELECT "auth"."uid"() AS "uid"))));



CREATE POLICY "Members create spaces" ON "public"."spaces" FOR INSERT TO "authenticated" WITH CHECK (( SELECT "public"."is_member"() AS "is_member"));



CREATE POLICY "Members detach files" ON "public"."item_files" FOR DELETE TO "authenticated" USING ((( SELECT "public"."is_member"() AS "is_member") AND ("role" = 'attachment'::"public"."file_role")));



CREATE POLICY "Members edit spaces" ON "public"."spaces" FOR UPDATE TO "authenticated" USING (( SELECT "public"."is_member"() AS "is_member")) WITH CHECK (( SELECT "public"."is_member"() AS "is_member"));



CREATE POLICY "Members edit themselves, admins edit anyone" ON "public"."members" FOR UPDATE TO "authenticated" USING ((("id" = ( SELECT "auth"."uid"() AS "uid")) OR ( SELECT "public"."is_admin"() AS "is_admin"))) WITH CHECK ((("id" = ( SELECT "auth"."uid"() AS "uid")) OR ( SELECT "public"."is_admin"() AS "is_admin")));



CREATE POLICY "Members file sources" ON "public"."sources" FOR UPDATE TO "authenticated" USING (( SELECT "public"."is_member"() AS "is_member")) WITH CHECK (( SELECT "public"."is_member"() AS "is_member"));



CREATE POLICY "Members relate items" ON "public"."item_links" FOR INSERT TO "authenticated" WITH CHECK ((( SELECT "public"."is_member"() AS "is_member") AND ("type" = 'relates_to'::"public"."link_type")));



CREATE POLICY "Members remove links" ON "public"."item_links" FOR DELETE TO "authenticated" USING (( SELECT "public"."is_member"() AS "is_member"));



CREATE POLICY "Members upload files" ON "public"."files" FOR INSERT TO "authenticated" WITH CHECK ((( SELECT "public"."is_member"() AS "is_member") AND ("uploaded_by" = ( SELECT "auth"."uid"() AS "uid"))));



CREATE POLICY "Uploaders finish their files" ON "public"."files" FOR UPDATE TO "authenticated" USING ((( SELECT "public"."is_member"() AS "is_member") AND ("uploaded_by" = ( SELECT "auth"."uid"() AS "uid")))) WITH CHECK ((( SELECT "public"."is_member"() AS "is_member") AND ("uploaded_by" = ( SELECT "auth"."uid"() AS "uid"))));



ALTER TABLE "public"."activity" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."comments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."docs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."files" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ideas" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."item_files" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."item_links" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."item_sources" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."item_versions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."members" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."proposals" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sources" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."spaces" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tasks" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";






ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."activity";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."comments";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."docs";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."ideas";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."item_links";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."items";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."proposals";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."tasks";



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";


































































































































































REVOKE ALL ON FUNCTION "private"."check_member"("allow_connector" boolean) FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."search_vector"("title" "text", "body" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."search_vector"("title" "text", "body" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."search_vector"("title" "text", "body" "text") TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."items" TO "service_role";
GRANT SELECT ON TABLE "public"."items" TO "authenticated";



GRANT UPDATE("archived_at") ON TABLE "public"."items" TO "authenticated";



REVOKE ALL ON FUNCTION "private"."get_item"("p_item_id" "uuid", "p_kind" "public"."item_kind") FROM PUBLIC;



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."proposals" TO "service_role";
GRANT SELECT ON TABLE "public"."proposals" TO "authenticated";



REVOKE ALL ON FUNCTION "private"."get_pending_proposal"("p_proposal_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."insert_kind_row"("p_item" "public"."items") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."log_activity"("p_verb" "public"."activity_verb", "p_item_id" "uuid", "p_space_id" "uuid", "p_source_id" "uuid", "p_data" "jsonb") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."log_direct_write"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."require_member"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."require_member_id"("p_member_id" "uuid", "p_what" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."require_member_or_connector"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."require_open_space"("p_space_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."accept_proposal"("proposal_id" "uuid", "overrides" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."accept_proposal"("proposal_id" "uuid", "overrides" "jsonb") TO "authenticated";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."item_links" TO "service_role";
GRANT SELECT,DELETE ON TABLE "public"."item_links" TO "authenticated";



GRANT INSERT("from_item") ON TABLE "public"."item_links" TO "authenticated";



GRANT INSERT("to_item") ON TABLE "public"."item_links" TO "authenticated";



GRANT INSERT("type") ON TABLE "public"."item_links" TO "authenticated";



REVOKE ALL ON FUNCTION "public"."add_dependency"("task_id" "uuid", "depends_on" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."add_dependency"("task_id" "uuid", "depends_on" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."break_into_tasks"("idea_id" "uuid", "tasks" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."break_into_tasks"("idea_id" "uuid", "tasks" "jsonb") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."capture_item"("kind" "public"."item_kind", "title" "text", "space_id" "uuid", "content_md" "text", "content_json" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."capture_item"("kind" "public"."item_kind", "title" "text", "space_id" "uuid", "content_md" "text", "content_json" "jsonb") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."change_kind"("item_id" "uuid", "kind" "public"."item_kind") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."change_kind"("item_id" "uuid", "kind" "public"."item_kind") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."consolidate_into_doc"("idea_ids" "uuid"[], "title" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."consolidate_into_doc"("idea_ids" "uuid"[], "title" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."create_source"("title" "text", "origin" "public"."source_origin", "raw_text" "text", "cleaned_md" "text", "processing_notes" "text", "external_ref" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_source"("title" "text", "origin" "public"."source_origin", "raw_text" "text", "cleaned_md" "text", "processing_notes" "text", "external_ref" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."dismiss_proposal"("proposal_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."dismiss_proposal"("proposal_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."file_item"("item_id" "uuid", "space_id" "uuid", "status" "public"."idea_status") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."file_item"("item_id" "uuid", "space_id" "uuid", "status" "public"."idea_status") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."home_blocked"("p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."home_blocked"("p_limit" integer) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."home_decisions"("p_days" integer, "p_tz" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."home_decisions"("p_days" integer, "p_tz" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."home_inbox_age"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."home_inbox_age"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."home_space_stats"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."home_space_stats"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."home_task_counts"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."home_task_counts"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."is_admin"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_admin"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."is_connector"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_connector"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."is_member"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_member"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."mark_home_seen"("seen_until" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."mark_home_seen"("seen_until" timestamp with time zone) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."merge_item"("item_id" "uuid", "into_item" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."merge_item"("item_id" "uuid", "into_item" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."merge_proposal"("proposal_id" "uuid", "into_item" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."merge_proposal"("proposal_id" "uuid", "into_item" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."propose_items"("source_id" "uuid", "items" "jsonb", "start_index" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."propose_items"("source_id" "uuid", "items" "jsonb", "start_index" integer) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."restore_proposal"("proposal_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."restore_proposal"("proposal_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."save_document"("item_id" "uuid", "expected_version" integer, "title" "text", "content_json" "jsonb", "content_md" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."save_document"("item_id" "uuid", "expected_version" integer, "title" "text", "content_json" "jsonb", "content_md" "text") TO "authenticated";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."docs" TO "service_role";
GRANT SELECT ON TABLE "public"."docs" TO "authenticated";



REVOKE ALL ON FUNCTION "public"."seal_doc"("item_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."seal_doc"("item_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."search_all"("q" "text", "filters" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."search_all"("q" "text", "filters" "jsonb") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."search_query"("q" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."search_query"("q" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."search_query"("q" "text") TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."ideas" TO "service_role";
GRANT SELECT ON TABLE "public"."ideas" TO "authenticated";



REVOKE ALL ON FUNCTION "public"."set_idea_status"("item_id" "uuid", "status" "public"."idea_status", "decided_by" "uuid"[], "cut_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_idea_status"("item_id" "uuid", "status" "public"."idea_status", "decided_by" "uuid"[], "cut_reason" "text") TO "authenticated";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."tasks" TO "service_role";
GRANT SELECT ON TABLE "public"."tasks" TO "authenticated";



GRANT UPDATE("assignee_id") ON TABLE "public"."tasks" TO "authenticated";



GRANT UPDATE("due_date") ON TABLE "public"."tasks" TO "authenticated";



REVOKE ALL ON FUNCTION "public"."set_task_status"("item_id" "uuid", "status" "public"."task_status") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_task_status"("item_id" "uuid", "status" "public"."task_status") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."set_tour_progress"("p_step" integer, "p_done" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_tour_progress"("p_step" integer, "p_done" boolean) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."unaccent_text"("value" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."unaccent_text"("value" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."unaccent_text"("value" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."unseal_doc"("item_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."unseal_doc"("item_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."usage_stats"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."usage_stats"() TO "authenticated";


















GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."activity" TO "service_role";
GRANT SELECT ON TABLE "public"."activity" TO "authenticated";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."comments" TO "service_role";
GRANT SELECT ON TABLE "public"."comments" TO "authenticated";



GRANT INSERT("item_id") ON TABLE "public"."comments" TO "authenticated";



GRANT INSERT("body_md"),UPDATE("body_md") ON TABLE "public"."comments" TO "authenticated";



GRANT UPDATE("deleted_at") ON TABLE "public"."comments" TO "authenticated";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."files" TO "service_role";
GRANT SELECT ON TABLE "public"."files" TO "authenticated";



GRANT INSERT("status"),UPDATE("status") ON TABLE "public"."files" TO "authenticated";



GRANT INSERT("mime") ON TABLE "public"."files" TO "authenticated";



GRANT INSERT("bytes"),UPDATE("bytes") ON TABLE "public"."files" TO "authenticated";



GRANT INSERT("width"),UPDATE("width") ON TABLE "public"."files" TO "authenticated";



GRANT INSERT("height"),UPDATE("height") ON TABLE "public"."files" TO "authenticated";



GRANT INSERT("name") ON TABLE "public"."files" TO "authenticated";



GRANT INSERT("space_id") ON TABLE "public"."files" TO "authenticated";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."item_files" TO "service_role";
GRANT SELECT,DELETE ON TABLE "public"."item_files" TO "authenticated";



GRANT INSERT("item_id") ON TABLE "public"."item_files" TO "authenticated";



GRANT INSERT("file_id") ON TABLE "public"."item_files" TO "authenticated";



GRANT INSERT("role") ON TABLE "public"."item_files" TO "authenticated";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."item_sources" TO "service_role";
GRANT SELECT ON TABLE "public"."item_sources" TO "authenticated";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."item_versions" TO "service_role";
GRANT SELECT ON TABLE "public"."item_versions" TO "authenticated";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."members" TO "service_role";
GRANT SELECT,DELETE ON TABLE "public"."members" TO "authenticated";



GRANT INSERT("id") ON TABLE "public"."members" TO "authenticated";



GRANT INSERT("github_login") ON TABLE "public"."members" TO "authenticated";



GRANT INSERT("display_name"),UPDATE("display_name") ON TABLE "public"."members" TO "authenticated";



GRANT INSERT("role"),UPDATE("role") ON TABLE "public"."members" TO "authenticated";



GRANT INSERT("avatar_url"),UPDATE("avatar_url") ON TABLE "public"."members" TO "authenticated";



GRANT UPDATE("last_seen_at") ON TABLE "public"."members" TO "authenticated";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."sources" TO "service_role";
GRANT SELECT ON TABLE "public"."sources" TO "authenticated";



GRANT UPDATE("title") ON TABLE "public"."sources" TO "authenticated";



GRANT UPDATE("space_id") ON TABLE "public"."sources" TO "authenticated";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."spaces" TO "service_role";
GRANT SELECT ON TABLE "public"."spaces" TO "authenticated";



GRANT INSERT("name"),UPDATE("name") ON TABLE "public"."spaces" TO "authenticated";



GRANT INSERT("slug"),UPDATE("slug") ON TABLE "public"."spaces" TO "authenticated";



GRANT UPDATE("pitch_item_id") ON TABLE "public"."spaces" TO "authenticated";



GRANT INSERT("cover_file_id"),UPDATE("cover_file_id") ON TABLE "public"."spaces" TO "authenticated";



GRANT UPDATE("archived_at") ON TABLE "public"."spaces" TO "authenticated";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLES TO "service_role";































