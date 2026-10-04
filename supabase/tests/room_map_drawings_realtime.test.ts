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

async function waitFor(condition: () => boolean, message: string) {
  for (let attempt = 0; attempt < 50; attempt++) {
    if (condition()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(message);
}

Deno.test("drawing CRUD reaches another active member over private Broadcast", async () => {
  const master = await register("drawing-master");
  const player = await register("drawing-player");
  const outsider = await register("drawing-outsider");
  const admin = client(serviceRoleKey!);
  const clients: SupabaseClient[] = [
    master.supabase,
    player.supabase,
    outsider.supabase,
    admin,
  ];

  try {
    const { data: created, error: createError } = await master.supabase.rpc(
      "create_room",
      {
        room_name: "Realtime drawing test",
        room_description: null,
        room_game_system: "test",
      },
    );
    if (createError) throw createError;
    const room = Array.isArray(created) ? created[0] : created;
    assert(room?.id && room?.invite_code, "room creation returned no room");

    const { error: joinError } = await player.supabase.rpc("join_room", {
      room_invite_code: room.invite_code,
    });
    if (joinError) throw joinError;

    const { error: permissionError } = await master.supabase.rpc(
      "set_room_feature_permission",
      {
        target_room_id: room.id,
        target_feature: "drawing",
        new_allowed: true,
        target_role: "player",
        target_user_id: null,
      },
    );
    if (permissionError) throw permissionError;

    const assetId = crypto.randomUUID();
    const mapId = crypto.randomUUID();
    const { error: assetError } = await admin.from("assets").insert({
      id: assetId,
      owner_id: master.userId,
      category: "map",
      storage_path: `${master.userId}/drawing-realtime-map.png`,
    });
    if (assetError) throw assetError;
    const { error: mapError } = await admin.from("room_maps").insert({
      id: mapId,
      room_id: room.id,
      asset_id: assetId,
    });
    if (mapError) throw mapError;

    const received: string[] = [];
    const topic = `room:${room.id}:drawings`;
    const playerChannel = player.supabase
      .channel(topic, { config: { private: true } })
      .on("broadcast", { event: "INSERT" }, () => received.push("INSERT"))
      .on("broadcast", { event: "UPDATE" }, () => received.push("UPDATE"))
      .on("broadcast", { event: "DELETE" }, () => received.push("DELETE"));

    const playerStatus = await subscribe(playerChannel);
    assert(
      playerStatus === "SUBSCRIBED",
      `active player was not subscribed: ${playerStatus}`,
    );

    const outsiderChannel = outsider.supabase.channel(topic, {
      config: { private: true },
    });
    const outsiderStatus = await subscribe(outsiderChannel);
    assert(
      outsiderStatus.startsWith("CHANNEL_ERROR"),
      `outsider subscribed to drawing channel: ${outsiderStatus}`,
    );

    const { data: drawing, error: insertError } = await master.supabase
      .from("room_map_drawings")
      .insert({
        map_id: mapId,
        drawing_type: "freehand",
        geometry: { points: [{ x: 1, y: 1 }, { x: 10, y: 10 }] },
        color: "#123456",
        stroke_width: 4,
      })
      .select("id")
      .single();
    if (insertError) throw insertError;
    await waitFor(
      () => received.length === 1,
      `INSERT Broadcast was not received: ${JSON.stringify(received)}`,
    );
    const { data: inserted, error: readError } = await player.supabase
      .from("room_map_drawings")
      .select("color, stroke_width")
      .eq("id", drawing.id)
      .single();
    if (readError) throw readError;
    assert(
      inserted.color === "#123456",
      "player did not read inserted drawing",
    );

    const { error: updateError } = await master.supabase
      .from("room_map_drawings")
      .update({ color: "#ABCDEF", stroke_width: 7 })
      .eq("id", drawing.id);
    if (updateError) throw updateError;
    await waitFor(
      () => received.length === 2,
      `UPDATE Broadcast was not received: ${JSON.stringify(received)}`,
    );
    const { data: updated, error: updatedReadError } = await player.supabase
      .from("room_map_drawings")
      .select("color, stroke_width")
      .eq("id", drawing.id)
      .single();
    if (updatedReadError) throw updatedReadError;
    assert(
      updated.color === "#ABCDEF" && updated.stroke_width === 7,
      "player did not read updated drawing",
    );

    const { error: deleteError } = await master.supabase
      .from("room_map_drawings")
      .delete()
      .eq("id", drawing.id);
    if (deleteError) throw deleteError;
    await waitFor(
      () => received.length === 3,
      `DELETE Broadcast was not received: ${JSON.stringify(received)}`,
    );
    const { data: deleted, error: deletedReadError } = await player.supabase
      .from("room_map_drawings")
      .select("id")
      .eq("id", drawing.id);
    if (deletedReadError) throw deletedReadError;
    assert(deleted.length === 0, "player still read deleted drawing");
    assert(
      received.join(",") === "INSERT,UPDATE,DELETE",
      `unexpected Broadcast order: ${JSON.stringify(received)}`,
    );
  } finally {
    await Promise.all(clients.map((supabase) => supabase.removeAllChannels()));
    await Promise.all(clients.map((supabase) => supabase.auth.signOut()));
  }
});
