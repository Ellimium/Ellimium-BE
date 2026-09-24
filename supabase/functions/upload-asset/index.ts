import {
  ImageMagick,
  initializeImageMagick,
} from "npm:@imagemagick/magick-wasm@^0";
import { createClient } from "npm:@supabase/supabase-js@2";
import {
  MAX_MAP_DIMENSION,
  validateAsset,
  validateThumbnail,
} from "./validation.ts";

const corsHeaders = {
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Origin": "*",
};

const wasmBytes = await Deno.readFile(
  new URL(import.meta.resolve("npm:@imagemagick/magick-wasm@^0/magick.wasm")),
);
await initializeImageMagick(wasmBytes);

function environmentKey(legacyName: string, currentName: string) {
  const legacy = Deno.env.get(legacyName);
  if (legacy) return legacy;
  const current = Deno.env.get(currentName);
  if (!current) throw new Error(`${currentName} is required`);
  return JSON.parse(current).default;
}

function json(body: Record<string, unknown>, status: number) {
  return Response.json(body, { status, headers: corsHeaders });
}

function resizeMap(bytes: Uint8Array) {
  return ImageMagick.read(bytes, (image): Uint8Array => {
    const scale = Math.min(
      1,
      MAX_MAP_DIMENSION / image.width,
      MAX_MAP_DIMENSION / image.height,
    );
    if (scale < 1) {
      image.resize(
        Math.round(image.width * scale),
        Math.round(image.height * scale),
      );
    }
    return image.write((data) => data);
  });
}

function assertDecodableImage(bytes: Uint8Array) {
  ImageMagick.read(bytes, (image) => image.width);
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method !== "POST") {
    return json({ error: "method not allowed" }, 405);
  }

  const url = Deno.env.get("SUPABASE_URL");
  if (!url) return json({ error: "server configuration error" }, 500);

  const publishableKey = environmentKey(
    "SUPABASE_ANON_KEY",
    "SUPABASE_PUBLISHABLE_KEYS",
  );
  const authorization = request.headers.get("Authorization");
  const userClient = createClient(url, publishableKey, {
    global: { headers: { Authorization: authorization ?? "" } },
  });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "authentication required" }, 401);

  const adminClient = createClient(
    url,
    environmentKey("SUPABASE_SERVICE_ROLE_KEY", "SUPABASE_SECRET_KEYS"),
  );
  const uploadedPaths: string[] = [];

  try {
    const formData = await request.formData();
    const file = formData.get("file");
    const thumbnail = formData.get("thumbnail");
    const categoryValue = formData.get("category");
    if (!(file instanceof File) || typeof categoryValue !== "string") {
      return json({ error: "file and category are required" }, 400);
    }
    if (thumbnail !== null && !(thumbnail instanceof File)) {
      return json({ error: "thumbnail must be a file" }, 400);
    }

    const fileBytes = new Uint8Array(await file.arrayBuffer());
    const { category, type } = validateAsset(categoryValue, fileBytes);
    const storedFile = category === "map"
      ? resizeMap(fileBytes)
      : (assertDecodableImage(fileBytes), fileBytes);
    const storagePath = `${user.id}/${crypto.randomUUID()}.${type.extension}`;
    const { error: uploadError } = await adminClient.storage.from("assets")
      .upload(storagePath, storedFile, {
        contentType: type.contentType,
        upsert: false,
      });
    if (uploadError) throw uploadError;
    uploadedPaths.push(storagePath);

    let thumbnailStoragePath: string | null = null;
    if (thumbnail instanceof File) {
      const thumbnailBytes = new Uint8Array(await thumbnail.arrayBuffer());
      const thumbnailType = validateThumbnail(thumbnailBytes);
      assertDecodableImage(thumbnailBytes);
      thumbnailStoragePath =
        `${user.id}/${crypto.randomUUID()}-thumbnail.${thumbnailType.extension}`;
      const { error: thumbnailError } = await adminClient.storage.from("assets")
        .upload(thumbnailStoragePath, thumbnailBytes, {
          contentType: thumbnailType.contentType,
          upsert: false,
        });
      if (thumbnailError) throw thumbnailError;
      uploadedPaths.push(thumbnailStoragePath);
    }

    const { data: asset, error: assetError } = await adminClient
      .from("assets")
      .insert({
        owner_id: user.id,
        category,
        storage_path: storagePath,
        thumbnail_storage_path: thumbnailStoragePath,
      })
      .select()
      .single();
    if (assetError) throw assetError;

    return json({ asset }, 201);
  } catch (error) {
    if (uploadedPaths.length) {
      await adminClient.storage.from("assets").remove(uploadedPaths);
    }
    return json({
      error: error instanceof Error ? error.message : "upload failed",
    }, 400);
  }
});
