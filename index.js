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

app.post("/upload-image", async (req, res) => {
  const { file, mimeType, fileName } = req.body;

  if (!file) return res.status(400).json({ error: "No file provided" });

  // Supported image mime types — reject anything else
  const allowedMimeTypes = [
    "image/jpeg",
    "image/png",
    "image/webp",
    "image/heic",
    "image/heif",
    "image/gif",
    "image/bmp",
    "image/tiff",
    "image/avif",
  ];

  const resolvedMime = mimeType ?? "image/jpeg";

  if (!allowedMimeTypes.includes(resolvedMime)) {
    return res
      .status(400)
      .json({ error: `Unsupported file type: ${resolvedMime}` });
  }

  try {
    // Build the data URI — Cloudinary accepts this natively
    const dataUri = `data:${resolvedMime};base64,${file}`;

    const uploadResult = await cloudinary.uploader.upload(dataUri, {
      public_id: fileName ? fileName.replace(/\.[^/.]+$/, "") : undefined, // strip extension, Cloudinary adds its own
      resource_type: "image",
    });

    res.status(200).json({
      image_url: uploadResult.secure_url,
      image_public_id: uploadResult.public_id,
    });
  } catch (error) {
    console.error("Cloudinary upload error:", error);
    res.status(500).json({ error: error.message ?? "Upload failed" });
  }
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
