-- Adds an optional `filter_pdf` parameter to get_scored_posts.
-- NULL (default) → all posts, same behaviour as before (Feed is unaffected).
-- TRUE           → PDF posts only (Archives "Most Viewed").
-- FALSE          → non-PDF posts only (reserved for future use).

CREATE OR REPLACE FUNCTION "public"."get_scored_posts"(
  "current_user_id" "uuid",
  "page_size"       integer,
  "from_offset"     integer,
  "filter_pdf"      boolean DEFAULT NULL
)
RETURNS TABLE(
  "id"              "uuid",
  "user_id"         "uuid",
  "title"           "text",
  "content"         "text",
  "image_url"       "text",
  "image_public_id" "text",
  "is_pdf"          boolean,
  "created_at"      timestamp with time zone,
  "profiles"        "jsonb",
  "comments"        "jsonb",
  "score"           double precision
)
LANGUAGE "sql" STABLE
AS $$
  WITH engagement AS (
    SELECT
      post_id,
      COUNT(DISTINCT id) FILTER (WHERE type = 'like')    AS like_count,
      COUNT(DISTINCT id) FILTER (WHERE type = 'comment') AS comment_count
    FROM (
      SELECT id, post_id, 'like'    AS type FROM likes
      UNION ALL
      SELECT id, post_id, 'comment' AS type FROM comments
    ) t
    GROUP BY post_id
  ),
  impressions AS (
    SELECT
      post_id,
      user_id,
      COALESCE(times_seen, 0) AS times_seen
    FROM post_impressions
  )
  SELECT
    p.id,
    p.user_id,
    p.title,
    p.content,
    p.image_url,
    p.image_public_id,
    p.is_pdf,
    p.created_at,
    jsonb_build_object(
      'id',         pr.id,
      'fullname',   pr.fullname,
      'username',   pr.username,
      'avatar_url', pr.avatar_url
    ) AS profiles,
    jsonb_build_object(
      'count', COALESCE(e.comment_count, 0)
    ) AS comments,
    (
      -- Engagement signal
      COALESCE(e.like_count, 0)    * 1.0
      + COALESCE(e.comment_count, 0) * 2.5
      -- Time decay
      - POWER(
          EXTRACT(EPOCH FROM (now() - p.created_at)) / 3600.0 + 1,
          0.6
        )
      -- Follow boost
      + CASE WHEN f.follower_id IS NOT NULL THEN 4.0 ELSE 0.0 END
      -- Freshness window
      + CASE
          WHEN EXTRACT(EPOCH FROM (now() - p.created_at)) < 7200 THEN 5.0
          ELSE 0.0
        END
      -- Impression cap
      - LEAST(COALESCE(pi.times_seen, 0), 6) * 1.3
    ) AS score
  FROM posts p
  LEFT JOIN profiles pr
    ON pr.id = p.user_id
  LEFT JOIN engagement e
    ON e.post_id = p.id
  LEFT JOIN follows f
    ON f.follower_id = current_user_id
   AND f.following_id = p.user_id
  LEFT JOIN impressions pi
    ON pi.post_id = p.id
   AND pi.user_id = current_user_id
  -- Optional PDF filter: NULL = all, TRUE = PDFs only, FALSE = non-PDFs only
  WHERE (filter_pdf IS NULL OR p.is_pdf = filter_pdf)
  GROUP BY
    p.id, p.user_id, p.title, p.content,
    p.image_url, p.image_public_id, p.is_pdf, p.created_at,
    pr.id, pr.fullname, pr.username, pr.avatar_url,
    f.follower_id,
    e.like_count, e.comment_count,
    pi.times_seen
  ORDER BY score DESC
  LIMIT page_size OFFSET from_offset;
$$;

-- Re-grant to all roles (same as original)
GRANT ALL ON FUNCTION "public"."get_scored_posts"(uuid, integer, integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."get_scored_posts"(uuid, integer, integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_scored_posts"(uuid, integer, integer, boolean) TO "service_role";
