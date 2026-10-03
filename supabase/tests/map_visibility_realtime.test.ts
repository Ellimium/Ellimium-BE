// deno-lint-ignore-file no-import-prefix
import {
  createClient,
  type RealtimeChannel,
  type SupabaseClient,
} from "npm:@supabase/supabase-js@2.117.2";

const url = Deno.env.get("SUPABASE_URL") ?? "http://127.0.0.1:54321";
const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

if (!anonKey) throw new Error("SUPABASE_ANON_KEY is required");
if (!serviceRoleKey) throw new Error("SUPABASE_SERVICE_ROLE_KEY is required");

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function client(key = anonKey!) {
  return createClient(url, key, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}

async function register(label: string) {
  const supabase = client();
  const { data, error } = await supabase.auth.signUp({
    email: `${label}-${crypto.randomUUID()}@example.com`,
    password: "test-password",
    options: { data: { nickname: label } },
  });
  if (error || !data.session || !data.user) {
    throw error ?? new Error(`failed to register ${label}`);
  }
  await supabase.realtime.setAuth(data.session.access_token);
  return { supabase, userId: data.user.id };
}

async function subscribe(channel: RealtimeChannel) {
  return await new Promise<string>((resolve, reject) => {
    const timeout = setTimeout(
      () => reject(new Error("Realtime subscription timed out")),
      10_000,
    );
    channel.subscribe((status, error) => {
      if (
        !["SUBSCRIBED", "CHANNEL_ERROR", "TIMED_OUT", "CLOSED"].includes(
          status,
        )
      ) return;
      clearTimeout(timeout);
      resolve(error ? `${status}: ${error.message}` : status);
    });
  });
}

async function waitFor(condition: () => boolean, message: () => string) {
  for (let attempt = 0; attempt < 50; attempt++) {
    if (condition()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(message());
}

Deno.test("visibility changes reach only authorized room members", async () => {
  const master = await register("fog-master");
  const player = await register("fog-player");
  const otherPlayer = await register("fog-other-player");
  const outsider = await register("fog-outsider");
  const admin = client(serviceRoleKey!);
  const clients: SupabaseClient[] = [
    master.supabase,
    player.supabase,
    otherPlayer.supabase,
    outsider.supabase,
    admin,
  ];

  try {
    const { data: created, error: createError } = await master.supabase.rpc(
      "create_room",
      {
        room_name: "Realtime visibility test",
        room_description: null,
        room_game_system: "test",
      },
    );
    if (createError) throw createError;
    const room = Array.isArray(created) ? created[0] : created;
    assert(room?.id && room?.invite_code, "room creation returned no room");

    for (const member of [player, otherPlayer]) {
      const { error } = await member.supabase.rpc("join_room", {
        room_invite_code: room.invite_code,
      });
      if (error) throw error;
    }

    const assetId = crypto.randomUUID();
    const mapId = crypto.randomUUID();
    const { error: assetError } = await admin.from("assets").insert({
      id: assetId,
      owner_id: master.userId,
      category: "map",
      storage_path: `${master.userId}/realtime-map.png`,
    });
    if (assetError) throw assetError;
    const { error: mapError } = await admin.from("room_maps").insert({
      id: mapId,
      room_id: room.id,
      asset_id: assetId,
    });
    if (mapError) throw mapError;

    const visibilityChanges = {
      master: [] as Record<string, unknown>[],
      player: [] as Record<string, unknown>[],
      otherPlayer: [] as Record<string, unknown>[],
      outsider: [] as Record<string, unknown>[],
    };
    const fogChanges = {
      master: [] as Record<string, unknown>[],
      player: [] as Record<string, unknown>[],
      otherPlayer: [] as Record<string, unknown>[],
      outsider: [] as Record<string, unknown>[],
    };
    const subscribers = [
      ["master", master.supabase],
      ["player", player.supabase],
      ["otherPlayer", otherPlayer.supabase],
      ["outsider", outsider.supabase],
    ] as const;
    const channels = subscribers.map(([role, supabase]) =>
      supabase
        .channel(`map-visibility-${role}-${mapId}`)
        .on(
          "postgres_changes",
          {
            event: "*",
            schema: "public",
            table: "map_visibility",
            filter: `map_id=eq.${mapId}`,
          },
          ({ new: row }) => visibilityChanges[role].push(row),
        )
        .on(
          "postgres_changes",
          {
            event: "UPDATE",
            schema: "public",
            table: "room_maps",
            filter: `id=eq.${mapId}`,
          },
          ({ new: row }) => fogChanges[role].push(row),
        )
    );

    for (const channel of channels) {
      const status = await subscribe(channel);
      assert(status === "SUBSCRIBED", `subscription failed: ${status}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 3_000));

    const { error: commonError } = await master.supabase.from(
      "map_visibility",
    ).insert({
      map_id: mapId,
      scope: "all",
      revealed_areas: [{ x: 0, y: 0, width: 100, height: 100 }],
    });
    if (commonError) throw commonError;
    await waitFor(
      () =>
        visibilityChanges.master.length === 1 &&
        visibilityChanges.player.length === 1 &&
        visibilityChanges.otherPlayer.length === 1,
      () => `common visibility counts: ${JSON.stringify(visibilityChanges)}`,
    );

    const { error: personalError } = await master.supabase.from(
      "map_visibility",
    ).insert({
      map_id: mapId,
      room_member_id: player.userId,
      scope: "member",
      revealed_areas: [{ x: 10, y: 20, width: 30, height: 40 }],
    });
    if (personalError) throw personalError;
    await waitFor(
      () =>
        visibilityChanges.master.length === 2 &&
        visibilityChanges.player.length === 2,
      () => `personal visibility counts: ${JSON.stringify(visibilityChanges)}`,
    );

    const { error: updateError } = await master.supabase.from(
      "map_visibility",
    ).update({
      revealed_areas: [{ x: 15, y: 25, width: 35, height: 45 }],
    }).eq("map_id", mapId).eq("room_member_id", player.userId);
    if (updateError) throw updateError;
    await waitFor(
      () =>
        visibilityChanges.master.length === 3 &&
        visibilityChanges.player.length === 3,
      () => `updated visibility counts: ${JSON.stringify(visibilityChanges)}`,
    );

    const { error: inheritError } = await master.supabase.from(
      "map_visibility",
    ).update({ inherits_common: true }).eq("map_id", mapId).eq(
      "room_member_id",
      player.userId,
    );
    if (inheritError) throw inheritError;
    await waitFor(
      () =>
        visibilityChanges.master.length === 4 &&
        visibilityChanges.player.length === 4,
      () => `inherited visibility counts: ${JSON.stringify(visibilityChanges)}`,
    );

    const { error: commonUpdateError } = await master.supabase.from(
      "map_visibility",
    ).update({
      revealed_areas: [{ x: 5, y: 5, width: 50, height: 50 }],
    }).eq("map_id", mapId).eq("scope", "all");
    if (commonUpdateError) throw commonUpdateError;
    await waitFor(
      () =>
        visibilityChanges.master.length === 5 &&
        visibilityChanges.player.length === 5 &&
        visibilityChanges.otherPlayer.length === 2,
      () => `common update counts: ${JSON.stringify(visibilityChanges)}`,
    );

    const { error: fogError } = await master.supabase.rpc(
      "set_map_fog_enabled",
      { target_map_id: mapId, new_fog_enabled: true },
    );
    if (fogError) throw fogError;
    await waitFor(
      () =>
        fogChanges.master.length === 1 &&
        fogChanges.player.length === 1 &&
        fogChanges.otherPlayer.length === 1,
      () => `fog update counts: ${JSON.stringify(fogChanges)}`,
    );
    await new Promise((resolve) => setTimeout(resolve, 500));

    assert(
      visibilityChanges.otherPlayer.length === 2,
      "another player received personal visibility",
    );
    assert(
      visibilityChanges.outsider.length === 0 &&
        fogChanges.outsider.length === 0,
      "an outsider received visibility changes",
    );
  } finally {
    await Promise.all(clients.map((supabase) => supabase.removeAllChannels()));
    await Promise.all(clients.map((supabase) => supabase.auth.signOut()));
  }
});
