import { createClient } from "npm:@supabase/supabase-js@2.117.2";

const corsHeaders = {
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Origin": "*",
  "Cache-Control": "no-store",
};
function json(body: Record<string, unknown>, status: number) {
  return Response.json(body, { status, headers: corsHeaders });
}
function environmentKey(legacyName: string, currentName: string) {
  const legacy = Deno.env.get(legacyName);
  if (legacy) return legacy;
  const value = JSON.parse(Deno.env.get(currentName) ?? "{}").default;
  if (typeof value !== "string" || !value) {
    throw new Error("missing server configuration");
  }
  return value;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method !== "POST") {
    return json({ error: "method not allowed" }, 405);
  }
  const authorization = request.headers.get("Authorization");
  if (!authorization) return json({ error: "authentication required" }, 401);
  try {
    const url = Deno.env.get("SUPABASE_URL");
    if (!url) throw new Error("missing server configuration");
    const userClient = createClient(
      url,
      environmentKey("SUPABASE_ANON_KEY", "SUPABASE_PUBLISHABLE_KEYS"),
      {
        global: { headers: { Authorization: authorization } },
        auth: { persistSession: false, autoRefreshToken: false },
      },
    );
    const { data: { user }, error: authError } = await userClient.auth
      .getUser();
    if (authError || !user) {
      return json({ error: "authentication required" }, 401);
    }
    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return json({ error: "a JSON body is required" }, 400);
    }
    const musicAssetId =
      body && typeof body === "object" && "musicAssetId" in body
        ? body.musicAssetId
        : null;
    if (
      typeof musicAssetId !== "string" ||
      !/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(musicAssetId)
    ) {
      return json({ error: "a valid musicAssetId is required" }, 400);
    }
    const adminClient = createClient(
      url,
      environmentKey("SUPABASE_SERVICE_ROLE_KEY", "SUPABASE_SECRET_KEYS"),
      {
        auth: { persistSession: false, autoRefreshToken: false },
      },
    );
    const { data: storagePath, error: prepareError } = await userClient.rpc(
      "prepare_music_asset_deletion",
      { target_music_asset_id: musicAssetId },
    );
    if (prepareError) {
      return prepareError.code === "42501"
        ? json({ error: "music owner required" }, 403)
        : json({
          error: "music deletion could not be prepared",
          code: "deletion_prepare_failed",
        }, 500);
    }
    if (storagePath === null) return json({ deleted: false }, 200);
    if (
      typeof storagePath !== "string" || !storagePath.startsWith(`${user.id}/`)
    ) {
      throw new Error("invalid music path");
    }
    const { error: storageError } = await adminClient.storage.from(
      "music-assets",
    ).remove([storagePath]);
    if (storageError) {
      return json({
        error: "music file deletion failed; retry the deletion",
        code: "storage_delete_failed",
      }, 502);
    }
    const { data: deleted, error: finishError } = await adminClient.rpc(
      "finish_music_asset_deletion",
      {
        target_music_asset_id: musicAssetId,
        target_owner_id: user.id,
      },
    );
    if (finishError) {
      return json({
        error: "music metadata deletion failed; retry the deletion",
        code: "metadata_delete_failed",
      }, 500);
    }
    return json({ deleted }, 200);
  } catch {
    return json({
      error: "music deletion failed; retry the deletion",
      code: "music_delete_failed",
    }, 500);
  }
});
