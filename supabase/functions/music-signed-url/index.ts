import { createClient } from "npm:@supabase/supabase-js@2.117.2";

const expiresIn = 300;
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
  const current = Deno.env.get(currentName);
  if (!current) throw new Error("missing server configuration");
  const value = JSON.parse(current).default;
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

    // The privileged client resolves one path only. It must never sign URLs.
    const adminClient = createClient(
      url,
      environmentKey("SUPABASE_SERVICE_ROLE_KEY", "SUPABASE_SECRET_KEYS"),
      {
        auth: { persistSession: false, autoRefreshToken: false },
      },
    );
    const { data: music, error: lookupError } = await adminClient
      .from("music_assets").select("storage_path").eq("id", musicAssetId)
      .maybeSingle();
    if (lookupError) return json({ error: "music lookup failed" }, 500);
    if (!music) return json({ error: "music access denied" }, 403);

    // Storage RLS checks the current membership/reference using the caller's JWT.
    const { data, error } = await userClient.storage.from("music-assets")
      .createSignedUrl(music.storage_path, expiresIn);
    if (error) {
      const status = Number("statusCode" in error ? error.statusCode : NaN);
      return status >= 500
        ? json({ error: "music URL issuance failed" }, 502)
        : json({ error: "music access denied" }, 403);
    }
    // Local Edge Runtime uses Kong internally; clients need the public API origin.
    const publicApiUrl = Deno.env.get("MUSIC_PUBLIC_API_URL") ??
      (new URL(url).hostname === "kong" ? "http://127.0.0.1:54321" : url);
    const signed = new URL(data.signedUrl);
    const signedUrl =
      new URL(signed.pathname + signed.search, publicApiUrl).href;
    return json({ signedUrl, expiresIn }, 200);
  } catch {
    return json({ error: "music URL issuance failed" }, 500);
  }
});
