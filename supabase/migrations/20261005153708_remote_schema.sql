drop extension if exists "pg_net";

alter table "public"."comment_likes" drop constraint "comment_likes_comment_id_fkey";

alter table "public"."comment_likes" drop constraint "comment_likes_user_id_fkey";

alter table "public"."comment_replies" drop constraint "comment_replies_comment_id_fkey";

alter table "public"."comment_replies" drop constraint "comment_replies_user_id_fkey";

alter table "public"."comment_reply_likes" drop constraint "comment_reply_likes_reply_id_fkey";

alter table "public"."comment_reply_likes" drop constraint "comment_reply_likes_user_id_fkey";

alter table "public"."comments" drop constraint "comments_post_id_fkey";

alter table "public"."comments" drop constraint "comments_user_id_fkey";

alter table "public"."follows" drop constraint "follows_follower_id_fkey";

alter table "public"."follows" drop constraint "follows_following_id_fkey";

alter table "public"."likes" drop constraint "likes_post_id_fkey";

alter table "public"."likes" drop constraint "likes_user_id_fkey";

alter table "public"."notifications" drop constraint "notifications_actor_id_fkey";

alter table "public"."notifications" drop constraint "notifications_comment_id_fkey";

alter table "public"."notifications" drop constraint "notifications_post_id_fkey";

alter table "public"."notifications" drop constraint "notifications_reply_id_fkey";

alter table "public"."notifications" drop constraint "notifications_user_id_fkey";

alter table "public"."post_impressions" drop constraint "post_impressions_post_id_fkey";

alter table "public"."post_impressions" drop constraint "post_impressions_user_id_fkey";

alter table "public"."posts" drop constraint "posts_user_id_fkey";

alter table "public"."comment_likes" add constraint "comment_likes_comment_id_fkey" FOREIGN KEY (comment_id) REFERENCES public.comments(id) ON DELETE CASCADE not valid;

alter table "public"."comment_likes" validate constraint "comment_likes_comment_id_fkey";

alter table "public"."comment_likes" add constraint "comment_likes_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE not valid;

alter table "public"."comment_likes" validate constraint "comment_likes_user_id_fkey";

alter table "public"."comment_replies" add constraint "comment_replies_comment_id_fkey" FOREIGN KEY (comment_id) REFERENCES public.comments(id) ON DELETE CASCADE not valid;

alter table "public"."comment_replies" validate constraint "comment_replies_comment_id_fkey";

alter table "public"."comment_replies" add constraint "comment_replies_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE not valid;

alter table "public"."comment_replies" validate constraint "comment_replies_user_id_fkey";

alter table "public"."comment_reply_likes" add constraint "comment_reply_likes_reply_id_fkey" FOREIGN KEY (reply_id) REFERENCES public.comment_replies(id) ON DELETE CASCADE not valid;

alter table "public"."comment_reply_likes" validate constraint "comment_reply_likes_reply_id_fkey";

alter table "public"."comment_reply_likes" add constraint "comment_reply_likes_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE not valid;

alter table "public"."comment_reply_likes" validate constraint "comment_reply_likes_user_id_fkey";

alter table "public"."comments" add constraint "comments_post_id_fkey" FOREIGN KEY (post_id) REFERENCES public.posts(id) ON DELETE CASCADE not valid;

alter table "public"."comments" validate constraint "comments_post_id_fkey";

alter table "public"."comments" add constraint "comments_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE not valid;

alter table "public"."comments" validate constraint "comments_user_id_fkey";

alter table "public"."follows" add constraint "follows_follower_id_fkey" FOREIGN KEY (follower_id) REFERENCES public.profiles(id) ON DELETE CASCADE not valid;

alter table "public"."follows" validate constraint "follows_follower_id_fkey";

alter table "public"."follows" add constraint "follows_following_id_fkey" FOREIGN KEY (following_id) REFERENCES public.profiles(id) ON DELETE CASCADE not valid;

alter table "public"."follows" validate constraint "follows_following_id_fkey";

alter table "public"."likes" add constraint "likes_post_id_fkey" FOREIGN KEY (post_id) REFERENCES public.posts(id) ON DELETE CASCADE not valid;

alter table "public"."likes" validate constraint "likes_post_id_fkey";

alter table "public"."likes" add constraint "likes_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE not valid;

alter table "public"."likes" validate constraint "likes_user_id_fkey";

alter table "public"."notifications" add constraint "notifications_actor_id_fkey" FOREIGN KEY (actor_id) REFERENCES public.profiles(id) ON DELETE SET NULL not valid;

alter table "public"."notifications" validate constraint "notifications_actor_id_fkey";

alter table "public"."notifications" add constraint "notifications_comment_id_fkey" FOREIGN KEY (comment_id) REFERENCES public.comments(id) ON DELETE CASCADE not valid;

alter table "public"."notifications" validate constraint "notifications_comment_id_fkey";

alter table "public"."notifications" add constraint "notifications_post_id_fkey" FOREIGN KEY (post_id) REFERENCES public.posts(id) ON DELETE CASCADE not valid;

alter table "public"."notifications" validate constraint "notifications_post_id_fkey";

alter table "public"."notifications" add constraint "notifications_reply_id_fkey" FOREIGN KEY (reply_id) REFERENCES public.comment_replies(id) ON DELETE CASCADE not valid;

alter table "public"."notifications" validate constraint "notifications_reply_id_fkey";

alter table "public"."notifications" add constraint "notifications_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE not valid;

alter table "public"."notifications" validate constraint "notifications_user_id_fkey";

alter table "public"."post_impressions" add constraint "post_impressions_post_id_fkey" FOREIGN KEY (post_id) REFERENCES public.posts(id) ON DELETE CASCADE not valid;

alter table "public"."post_impressions" validate constraint "post_impressions_post_id_fkey";

alter table "public"."post_impressions" add constraint "post_impressions_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE not valid;

alter table "public"."post_impressions" validate constraint "post_impressions_user_id_fkey";

alter table "public"."posts" add constraint "posts_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE not valid;

alter table "public"."posts" validate constraint "posts_user_id_fkey";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.get_suggested_users(p_user_id uuid)
 RETURNS TABLE(id uuid, fullname text, username text, avatar_url text, follower_count bigint, post_count bigint, score numeric)
 LANGUAGE sql
 STABLE
AS $function$

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

-- follower count
LEFT JOIN (
  SELECT following_id, COUNT(*) AS count
  FROM follows
  GROUP BY following_id
) follower_counts
ON follower_counts.following_id = p.id

-- post count
LEFT JOIN (
  SELECT user_id, COUNT(*) AS count
  FROM posts
  GROUP BY user_id
) post_counts
ON post_counts.user_id = p.id

-- already following list
LEFT JOIN (
  SELECT following_id
  FROM follows
  WHERE follower_id = p_user_id
) uf
ON uf.following_id = p.id

WHERE p.id != p_user_id

ORDER BY score DESC

LIMIT 6;

$function$
;

CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();


