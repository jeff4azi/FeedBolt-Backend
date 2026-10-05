-- Drop the old 3-parameter overload so there's only one version of the function.
-- The new 4-parameter version has filter_pdf DEFAULT NULL, so calling it with
-- 3 args (as the Feed does) works identically — Postgres uses the default.
DROP FUNCTION IF EXISTS "public"."get_scored_posts"(uuid, integer, integer);
