import { createClient } from "npm:@supabase/supabase-js@2";
import { validateMusicFile } from "./validation.ts";

const corsHeaders = {
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Origin": "*",
};

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
  const musicAssetId = crypto.randomUUID();
  const storagePath = `${user.id}/${musicAssetId}`;
  let objectPath: string | null = null;

  try {
    const formData = await request.formData();
    const titleValue = formData.get("title");
    const file = formData.get("file");
    if (typeof titleValue !== "string" || !titleValue.trim()) {
      return json({ error: "title is required" }, 400);
    }
    if (!(file instanceof File)) {
      return json({ error: "file is required" }, 400);
    }

    const bytes = new Uint8Array(await file.arrayBuffer());
    const { type, durationMs } = await validateMusicFile(
      file.name,
      file.type,
      bytes,
    );
    objectPath = `${storagePath}.${type.extension}`;
    const { error: uploadError } = await adminClient.storage
      .from("music-assets")
      .upload(objectPath, bytes, {
        contentType: type.contentType,
        upsert: false,
      });
    if (uploadError) throw new Error("music file could not be stored");

    const { data: musicAsset, error: metadataError } = await adminClient
      .from("music_assets")
      .insert({
        id: musicAssetId,
        owner_id: user.id,
        title: titleValue.trim(),
        storage_path: objectPath,
        mime_type: type.contentType,
        file_size_bytes: bytes.byteLength,
        duration_ms: durationMs,
      })
      .select()
      .single();
    if (metadataError) throw new Error("music metadata could not be saved");

    return json({ musicAsset }, 201);
  } catch (error) {
    const cleanupErrors: string[] = [];
    const { error: metadataCleanupError } = await adminClient
      .from("music_assets")
      .delete()
      .eq("id", musicAssetId);
    if (metadataCleanupError) cleanupErrors.push("metadata");

    if (objectPath) {
      const { error: storageCleanupError } = await adminClient.storage
        .from("music-assets")
        .remove([objectPath]);
      if (storageCleanupError) cleanupErrors.push("file");
    }

    if (cleanupErrors.length) {
      console.error("Music upload cleanup failed", cleanupErrors);
      return json(
        { error: "music upload failed and cleanup needs attention" },
        500,
      );
    }
    return json({
      error: error instanceof Error ? error.message : "music upload failed",
    }, 400);
  }
});
