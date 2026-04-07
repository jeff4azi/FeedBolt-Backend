import express from "express";
import { v2 as cloudinary } from "cloudinary";
import { createClient } from "@supabase/supabase-js";
import dotenv from "dotenv";

dotenv.config();

const app = express();
app.use(express.json());

// Cloudinary config
cloudinary.config({
  cloud_name: process.env.CLOUDINARY_CLOUD_NAME,
  api_key: process.env.CLOUDINARY_API_KEY,
  api_secret: process.env.CLOUDINARY_API_SECRET,
});

// Supabase client
const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_KEY,
);

// Test route
app.get("/", (req, res) => {
  res.send("Server is running!");
});

app.delete("/delete-post-image", async (req, res) => {
  const { postId } = req.body;

  if (!postId) return res.status(400).json({ error: "postId is required" });

  try {
    // 1️⃣ Fetch post from Supabase
    const { data: post, error: fetchError } = await supabase
      .from("posts")
      .select("image_public_id")
      .eq("id", postId)
      .single();

    if (fetchError) throw fetchError;
    if (!post?.image_public_id)
      return res.status(404).json({ error: "No image found" });

    // 2️⃣ Delete from Cloudinary
    await cloudinary.uploader.destroy(post.image_public_id);

    // 3️⃣ Update Supabase
    const { error: updateError } = await supabase
      .from("posts")
      .update({ image_url: null, image_public_id: null })
      .eq("id", postId);

    if (updateError) throw updateError;

    res.json({ message: "Image deleted successfully" });
  } catch (error) {
    console.error(error);
    res.status(500).json({ error: "Something went wrong" });
  }
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => console.log(`Server running on port ${PORT}`));
