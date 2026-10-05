


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


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."get_scored_posts"("current_user_id" "uuid", "page_size" integer, "from_offset" integer) RETURNS TABLE("id" "uuid", "user_id" "uuid", "title" "text", "content" "text", "image_url" "text", "image_public_id" "text", "is_pdf" boolean, "created_at" timestamp with time zone, "profiles" "jsonb", "comments" "jsonb", "score" double precision)
    LANGUAGE "sql" STABLE
    AS $$
  WITH engagement AS (
    SELECT
      post_id,
      COUNT(DISTINCT id) FILTER (WHERE type = 'like') AS like_count,
      COUNT(DISTINCT id) FILTER (WHERE type = 'comment') AS comment_count
    FROM (
      SELECT id, post_id, 'like' AS type FROM likes
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
      'id', pr.id,
      'fullname', pr.fullname,
      'username', pr.username,
      'avatar_url', pr.avatar_url
    ) AS profiles,
    jsonb_build_object(
      'count', COALESCE(e.comment_count, 0)
    ) AS comments,
    (
      -- Engagement signal
      COALESCE(e.like_count, 0) * 1.0
      + COALESCE(e.comment_count, 0) * 2.5
      -- Time decay
      - POWER(
          EXTRACT(EPOCH FROM (now() - p.created_at)) / 3600.0 + 1,
          0.6
        )
      -- Follow boost
      + CASE
          WHEN f.follower_id IS NOT NULL THEN 4.0
          ELSE 0.0
        END
      -- Freshness window
      + CASE
          WHEN EXTRACT(EPOCH FROM (now() - p.created_at)) < 7200
          THEN 5.0
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
  GROUP BY
    p.id,
    p.user_id,
    p.title,
    p.content,
    p.image_url,
    p.image_public_id,
    p.is_pdf,
    p.created_at,
    pr.id,
    pr.fullname,
    pr.username,
    pr.avatar_url,
    f.follower_id,
    e.like_count,
    e.comment_count,
    pi.times_seen
  ORDER BY score DESC
  LIMIT page_size OFFSET from_offset;
$$;


ALTER FUNCTION "public"."get_scored_posts"("current_user_id" "uuid", "page_size" integer, "from_offset" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_suggested_users"("p_user_id" "uuid") RETURNS TABLE("id" "uuid", "fullname" "text", "username" "text", "avatar_url" "text", "follower_count" bigint, "post_count" bigint, "score" numeric)
    LANGUAGE "sql" STABLE
    AS $$

SELECT
  p.id,
  p.fullname,
  p.username,
  p.avatar_url,

  COALESCE(follower_counts.count, 0) AS follower_count,
  COALESCE(post_counts.count, 0) AS post_count,

  (
    COALESCE(follower_counts.count, 0) * 2.0
    + COALESCE(post_counts.count, 0) * 1.2
    + CASE
        WHEN uf.following_id IS NULL THEN 3.0
        ELSE 0.0
      END
  ) AS score

FROM profiles p

LEFT JOIN (
  SELECT following_id, COUNT(*) AS count
  FROM follows
  GROUP BY following_id
) follower_counts
ON follower_counts.following_id = p.id

LEFT JOIN (
  SELECT user_id, COUNT(*) AS count
  FROM posts
  GROUP BY user_id
) post_counts
ON post_counts.user_id = p.id

LEFT JOIN (
  SELECT following_id
  FROM follows
  WHERE follower_id = p_user_id
) uf
ON uf.following_id = p.id

WHERE p.id != p_user_id

ORDER BY score DESC

LIMIT 6;

$$;


ALTER FUNCTION "public"."get_suggested_users"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_trending_hashtags"() RETURNS TABLE("hashtag" "text", "score" numeric, "usage_count" bigint)
    LANGUAGE "sql" STABLE
    AS $$WITH extracted AS (
  SELECT
    lower((regexp_matches(content, '#[a-zA-Z0-9_]+', 'g'))[1]) AS tag,
    created_at
  FROM posts
  WHERE created_at >= now() - interval '7 days'
),

weighted AS (
  SELECT
    tag,
    COUNT(*) AS usage_count,

    -- ⏱ recency weighting (exponential decay)
    SUM(
      EXP(
        -EXTRACT(EPOCH FROM (now() - created_at)) / 86400.0
      )
    ) AS recency_score

  FROM extracted
  GROUP BY tag
)

SELECT
  tag AS hashtag,
  (usage_count * 1.5 + recency_score * 10) AS score,
  usage_count

FROM weighted

ORDER BY score DESC
LIMIT 6;$$;


ALTER FUNCTION "public"."get_trending_hashtags"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  derived_username text;
begin
  -- derive username from email (everything before @)
  derived_username := split_part(new.email, '@', 1);

  insert into public.profiles (id, fullname, username, avatar_url)
  values (
    new.id,
    new.raw_user_meta_data->>'full_name',  -- keep fullname if provided
    derived_username,                       -- username from email
    new.raw_user_meta_data->>'avatar_url'   -- optional avatar
  );

  return new;
end;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."increment_post_impression"("p_user_id" "uuid", "p_post_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$BEGIN
  INSERT INTO post_impressions (user_id, post_id, times_seen)
  VALUES (p_user_id, p_post_id, 1)
  ON CONFLICT (user_id, post_id)
  DO UPDATE SET
    times_seen = LEAST(post_impressions.times_seen + 1, 100),
    last_seen_at = now();
END;$$;


ALTER FUNCTION "public"."increment_post_impression"("p_user_id" "uuid", "p_post_id" "uuid") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."comment_likes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "comment_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."comment_likes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."comment_replies" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "comment_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "content" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "replied_to_username" "text"
);


ALTER TABLE "public"."comment_replies" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."comment_reply_likes" (
    "user_id" "uuid" NOT NULL,
    "reply_id" "uuid" NOT NULL
);


ALTER TABLE "public"."comment_reply_likes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."comments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "post_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "content" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."comments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."follows" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "follower_id" "uuid" NOT NULL,
    "following_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."follows" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."likes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "post_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."likes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "type" "text" NOT NULL,
    "post_id" "uuid",
    "actor_id" "uuid",
    "actor_username" "text",
    "message" "text" NOT NULL,
    "read" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "comment_id" "uuid",
    "reply_id" "uuid"
);


ALTER TABLE "public"."notifications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."post_impressions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "post_id" "uuid" NOT NULL,
    "seen_at" timestamp with time zone DEFAULT "now"(),
    "times_seen" integer DEFAULT 1,
    "last_seen_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."post_impressions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."posts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "content" "text",
    "image_url" "text",
    "image_public_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "is_pdf" boolean DEFAULT false,
    "title" "text"
);


ALTER TABLE "public"."posts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "fullname" "text",
    "username" "text",
    "avatar_url" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "bio" "text",
    "avatar_public_id" "text"
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."push_subscriptions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "subscription" "jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."push_subscriptions" OWNER TO "postgres";


ALTER TABLE ONLY "public"."comment_likes"
    ADD CONSTRAINT "comment_likes_comment_id_user_id_key" UNIQUE ("comment_id", "user_id");



ALTER TABLE ONLY "public"."comment_likes"
    ADD CONSTRAINT "comment_likes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."comment_replies"
    ADD CONSTRAINT "comment_replies_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."comment_reply_likes"
    ADD CONSTRAINT "comment_reply_likes_pkey" PRIMARY KEY ("user_id", "reply_id");



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."follows"
    ADD CONSTRAINT "follows_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."follows"
    ADD CONSTRAINT "follows_unique" UNIQUE ("follower_id", "following_id");



ALTER TABLE ONLY "public"."likes"
    ADD CONSTRAINT "likes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."likes"
    ADD CONSTRAINT "likes_post_id_user_id_key" UNIQUE ("post_id", "user_id");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."post_impressions"
    ADD CONSTRAINT "post_impressions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."post_impressions"
    ADD CONSTRAINT "post_impressions_user_id_post_id_key" UNIQUE ("user_id", "post_id");



ALTER TABLE ONLY "public"."posts"
    ADD CONSTRAINT "posts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."push_subscriptions"
    ADD CONSTRAINT "push_subscriptions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."push_subscriptions"
    ADD CONSTRAINT "push_subscriptions_user_id_key" UNIQUE ("user_id");



ALTER TABLE ONLY "public"."push_subscriptions"
    ADD CONSTRAINT "push_subscriptions_user_id_subscription_key" UNIQUE ("user_id", "subscription");



CREATE INDEX "idx_post_impressions_post_id" ON "public"."post_impressions" USING "btree" ("post_id");



CREATE INDEX "idx_post_impressions_user_id" ON "public"."post_impressions" USING "btree" ("user_id");



CREATE INDEX "idx_post_impressions_user_post" ON "public"."post_impressions" USING "btree" ("user_id", "post_id");



CREATE INDEX "idx_posts_created_at" ON "public"."posts" USING "btree" ("created_at" DESC);



CREATE INDEX "notifications_comment_id_idx" ON "public"."notifications" USING "btree" ("comment_id");



CREATE INDEX "notifications_reply_id_idx" ON "public"."notifications" USING "btree" ("reply_id");



ALTER TABLE ONLY "public"."comment_likes"
    ADD CONSTRAINT "comment_likes_comment_id_fkey" FOREIGN KEY ("comment_id") REFERENCES "public"."comments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comment_likes"
    ADD CONSTRAINT "comment_likes_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comment_replies"
    ADD CONSTRAINT "comment_replies_comment_id_fkey" FOREIGN KEY ("comment_id") REFERENCES "public"."comments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comment_replies"
    ADD CONSTRAINT "comment_replies_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comment_reply_likes"
    ADD CONSTRAINT "comment_reply_likes_reply_id_fkey" FOREIGN KEY ("reply_id") REFERENCES "public"."comment_replies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comment_reply_likes"
    ADD CONSTRAINT "comment_reply_likes_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_post_id_fkey" FOREIGN KEY ("post_id") REFERENCES "public"."posts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."follows"
    ADD CONSTRAINT "follows_follower_id_fkey" FOREIGN KEY ("follower_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."follows"
    ADD CONSTRAINT "follows_following_id_fkey" FOREIGN KEY ("following_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."likes"
    ADD CONSTRAINT "likes_post_id_fkey" FOREIGN KEY ("post_id") REFERENCES "public"."posts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."likes"
    ADD CONSTRAINT "likes_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_actor_id_fkey" FOREIGN KEY ("actor_id") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_comment_id_fkey" FOREIGN KEY ("comment_id") REFERENCES "public"."comments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_post_id_fkey" FOREIGN KEY ("post_id") REFERENCES "public"."posts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_reply_id_fkey" FOREIGN KEY ("reply_id") REFERENCES "public"."comment_replies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."post_impressions"
    ADD CONSTRAINT "post_impressions_post_id_fkey" FOREIGN KEY ("post_id") REFERENCES "public"."posts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."post_impressions"
    ADD CONSTRAINT "post_impressions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."posts"
    ADD CONSTRAINT "posts_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."push_subscriptions"
    ADD CONSTRAINT "push_subscriptions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



CREATE POLICY "Anyone can read comment likes" ON "public"."comment_likes" FOR SELECT USING (true);



CREATE POLICY "Anyone can read replies" ON "public"."comment_replies" FOR SELECT USING (true);



CREATE POLICY "Anyone can read reply likes" ON "public"."comment_reply_likes" FOR SELECT USING (true);



CREATE POLICY "Authenticated users can read comment replies" ON "public"."comment_replies" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Service can insert notifications" ON "public"."notifications" FOR INSERT WITH CHECK (true);



CREATE POLICY "Users can delete own replies" ON "public"."comment_replies" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert own impressions" ON "public"."post_impressions" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert own replies" ON "public"."comment_replies" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can manage own comment likes" ON "public"."comment_likes" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can upsert own impressions" ON "public"."post_impressions" TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can view own impressions" ON "public"."post_impressions" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users manage own reply likes" ON "public"."comment_reply_likes" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users see own notifications" ON "public"."notifications" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users update own notifications" ON "public"."notifications" FOR UPDATE USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."comment_likes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."comment_replies" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."comment_reply_likes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."notifications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."post_impressions" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";






ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."notifications";



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";






















































































































































GRANT ALL ON FUNCTION "public"."get_scored_posts"("current_user_id" "uuid", "page_size" integer, "from_offset" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_scored_posts"("current_user_id" "uuid", "page_size" integer, "from_offset" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_scored_posts"("current_user_id" "uuid", "page_size" integer, "from_offset" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_suggested_users"("p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_suggested_users"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_suggested_users"("p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_trending_hashtags"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_trending_hashtags"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_trending_hashtags"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."increment_post_impression"("p_user_id" "uuid", "p_post_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."increment_post_impression"("p_user_id" "uuid", "p_post_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."increment_post_impression"("p_user_id" "uuid", "p_post_id" "uuid") TO "service_role";


















GRANT ALL ON TABLE "public"."comment_likes" TO "anon";
GRANT ALL ON TABLE "public"."comment_likes" TO "authenticated";
GRANT ALL ON TABLE "public"."comment_likes" TO "service_role";



GRANT ALL ON TABLE "public"."comment_replies" TO "anon";
GRANT ALL ON TABLE "public"."comment_replies" TO "authenticated";
GRANT ALL ON TABLE "public"."comment_replies" TO "service_role";



GRANT ALL ON TABLE "public"."comment_reply_likes" TO "anon";
GRANT ALL ON TABLE "public"."comment_reply_likes" TO "authenticated";
GRANT ALL ON TABLE "public"."comment_reply_likes" TO "service_role";



GRANT ALL ON TABLE "public"."comments" TO "anon";
GRANT ALL ON TABLE "public"."comments" TO "authenticated";
GRANT ALL ON TABLE "public"."comments" TO "service_role";



GRANT ALL ON TABLE "public"."follows" TO "anon";
GRANT ALL ON TABLE "public"."follows" TO "authenticated";
GRANT ALL ON TABLE "public"."follows" TO "service_role";



GRANT ALL ON TABLE "public"."likes" TO "anon";
GRANT ALL ON TABLE "public"."likes" TO "authenticated";
GRANT ALL ON TABLE "public"."likes" TO "service_role";



GRANT ALL ON TABLE "public"."notifications" TO "anon";
GRANT ALL ON TABLE "public"."notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."notifications" TO "service_role";



GRANT ALL ON TABLE "public"."post_impressions" TO "anon";
GRANT ALL ON TABLE "public"."post_impressions" TO "authenticated";
GRANT ALL ON TABLE "public"."post_impressions" TO "service_role";



GRANT ALL ON TABLE "public"."posts" TO "anon";
GRANT ALL ON TABLE "public"."posts" TO "authenticated";
GRANT ALL ON TABLE "public"."posts" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."push_subscriptions" TO "anon";
GRANT ALL ON TABLE "public"."push_subscriptions" TO "authenticated";
GRANT ALL ON TABLE "public"."push_subscriptions" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";































