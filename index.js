import express from "express";
import { v2 as cloudinary } from "cloudinary";
import { createClient } from "@supabase/supabase-js";
import dotenv from "dotenv";
import cors from "cors";
import multer from "multer";
import { Readable } from "stream";

dotenv.config();

const app = express();

const allowedOrigins = [
  "http://localhost:5175",
  "https://feedbolt-beige.vercel.app",
];

app.use(
  cors({
    origin: function (origin, callback) {
      // allow requests with no origin (like mobile apps or curl requests)
      if (!origin) return callback(null, true);

      if (allowedOrigins.indexOf(origin) !== -1) {
        callback(null, true);
      } else {
        callback(new Error("Not allowed by CORS"));
      }
    },
    methods: ["GET", "POST", "DELETE", "PUT", "PATCH"],
    allowedHeaders: ["Content-Type", "Authorization"],
  }),
);

app.use(express.json({ limit: "20mb" }));

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
    const dataUri = `data:${resolvedMime};base64,${file}`;

    const uploadResult = await cloudinary.uploader.upload(dataUri, {
      public_id: fileName ? fileName.replace(/\.[^/.]+$/, "") : undefined,
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
    const { data: post, error: fetchError } = await supabase
      .from("posts")
      .select("image_public_id, is_pdf")
      .eq("id", postId)
      .single();

    if (fetchError) throw fetchError;
    if (!post?.image_public_id)
      return res.status(404).json({ error: "No image found" });

    // Always delete the preview image
    await cloudinary.uploader.destroy(post.image_public_id, {
      resource_type: "image",
    });

    // For PDF posts, also delete the raw PDF asset (same public_id, different resource_type)
    if (post.is_pdf) {
      await cloudinary.uploader
        .destroy(post.image_public_id, {
          resource_type: "raw",
        })
        .catch(() => {}); // best-effort
    }

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

app.delete("/delete-avatar-image", async (req, res) => {
  const { userId } = req.body;
  if (!userId) return res.status(400).json({ error: "userId is required" });

  try {
    const { data: profile, error: fetchError } = await supabase
      .from("profiles")
      .select("avatar_public_id")
      .eq("id", userId)
      .single();

    if (fetchError) throw fetchError;
    if (!profile?.avatar_public_id)
      return res.status(404).json({ error: "No avatar found" });

    await cloudinary.uploader.destroy(profile.avatar_public_id);

    const { error: updateError } = await supabase
      .from("profiles")
      .update({ avatar_url: null, avatar_public_id: null })
      .eq("id", userId);

    if (updateError) throw updateError;

    res.json({ message: "Avatar deleted successfully" });
  } catch (error) {
    console.error(error);
    res.status(500).json({ error: "Something went wrong" });
  }
});

app.delete("/delete-posts", async (req, res) => {
  const { postIds } = req.body;

  if (!postIds || !Array.isArray(postIds) || postIds.length === 0) {
    return res.status(400).json({ error: "postIds array is required" });
  }

  try {
    // First, get all posts with their image_public_ids to delete from Cloudinary
    const { data: posts, error: fetchError } = await supabase
      .from("posts")
      .select("id, image_public_id, is_pdf")
      .in("id", postIds);

    if (fetchError) throw fetchError;

    // Delete images from Cloudinary for posts that have them
    const imageDeletePromises = posts
      .filter((post) => post.image_public_id)
      .flatMap((post) => {
        const deleteImage = cloudinary.uploader.destroy(post.image_public_id, {
          resource_type: "image",
        });
        // For PDF posts also delete the raw asset
        if (post.is_pdf) {
          return [
            deleteImage,
            cloudinary.uploader
              .destroy(post.image_public_id, { resource_type: "raw" })
              .catch(() => {}),
          ];
        }
        return [deleteImage];
      });

    await Promise.all(imageDeletePromises);

    // Delete posts from Supabase
    const { error: deleteError } = await supabase
      .from("posts")
      .delete()
      .in("id", postIds);

    if (deleteError) throw deleteError;

    res.json({
      message: `Successfully deleted ${postIds.length} posts`,
      deletedCount: postIds.length,
    });
  } catch (error) {
    console.error("Error deleting posts:", error);
    res
      .status(500)
      .json({ error: "Something went wrong while deleting posts" });
  }
});

// ── Multer (memory storage, used for PDF uploads) ────────────────────────────
const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 50 * 1024 * 1024 }, // 50 MB
  fileFilter: (_req, file, cb) => {
    if (file.fieldname === "pdf" && file.mimetype !== "application/pdf") {
      return cb(new Error("Only PDF files are accepted for the pdf field."));
    }
    if (file.fieldname === "preview" && !file.mimetype.startsWith("image/")) {
      return cb(
        new Error("Only image files are accepted for the preview field."),
      );
    }
    cb(null, true);
  },
});

// Helper: upload a Buffer to Cloudinary via a stream
function uploadBufferToCloudinary(buffer, options) {
  return new Promise((resolve, reject) => {
    const stream = cloudinary.uploader.upload_stream(options, (err, result) => {
      if (err) return reject(err);
      resolve(result);
    });
    Readable.from(buffer).pipe(stream);
  });
}

/**
 * POST /upload-pdf
 * multipart/form-data fields:
 *   pdf      – the PDF file (required)
 *   preview  – a JPEG preview/cover image (required)
 *   content  – post text (required)
 *   userId   – Supabase user id (required)
 */
app.post(
  "/upload-pdf",
  upload.fields([
    { name: "pdf", maxCount: 1 },
    { name: "preview", maxCount: 1 },
  ]),
  async (req, res) => {
    const { content, userId, title } = req.body;
    const pdfFile = req.files?.pdf?.[0];
    const previewFile = req.files?.preview?.[0];

    if (!pdfFile)
      return res.status(400).json({ error: "PDF file is required." });
    if (!previewFile)
      return res.status(400).json({ error: "Preview image is required." });
    if (!content?.trim())
      return res.status(400).json({ error: "Post content is required." });
    if (!userId) return res.status(400).json({ error: "userId is required." });

    try {
      // Build a shared public_id base so preview (.jpg) and pdf (.pdf) share the same name
      const baseName = `pdf_${userId}_${Date.now()}`;

      // 1. Upload preview image as .jpg (resource_type: image)
      const previewResult = await uploadBufferToCloudinary(previewFile.buffer, {
        public_id: baseName,
        resource_type: "image",
        format: "jpg",
      });

      // 2. Upload the actual PDF with the SAME public_id but resource_type: raw
      //    Cloudinary stores it at <baseName>.pdf under raw/upload/
      const pdfResult = await uploadBufferToCloudinary(pdfFile.buffer, {
        public_id: baseName,
        resource_type: "raw",
        format: "pdf",
      });

      // 3. Insert the post into Supabase
      //    image_url  → the preview .jpg URL  (pdfUtils.getPdfUrl swaps .jpg → .pdf)
      //    image_public_id → shared base name
      //    is_pdf     → true
      const { data: postData, error: insertError } = await supabase
        .from("posts")
        .insert({
          user_id: userId,
          content: content.trim(),
          title: title?.trim() || null,
          image_url: previewResult.secure_url,
          image_public_id: baseName,
          is_pdf: true,
        })
        .select("id")
        .single();

      if (insertError) throw insertError;

      res.status(200).json({
        post_id: postData.id,
        image_url: previewResult.secure_url,
        image_public_id: baseName,
        pdf_url: pdfResult.secure_url,
      });
    } catch (err) {
      console.error("PDF upload error:", err);
      res.status(500).json({ error: err.message ?? "PDF upload failed." });
    }
  },
);

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => console.log(`Server running on port ${PORT}`));
