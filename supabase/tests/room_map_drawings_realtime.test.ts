// deno-lint-ignore-file no-import-prefix
import {
  createClient,
  type RealtimeChannel,
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

type DrawingRow = {
  id: string;
  geometry: { x: number; y: number };
  text_content: string;
};

type DrawingEvent = {
  event: string;
  payload: { record: DrawingRow; old_record: DrawingRow };
};

Deno.test("drawing Broadcast respects map_view on new private subscriptions", async () => {
  const admin = client(serviceRoleKey!);
  let roomId: string | undefined;
  const users: Awaited<ReturnType<typeof register>>[] = [];
  async function user(label: string) {
    const registered = await register(label);
    users.push(registered);
    return registered;
  }
  try {
    const master = await user("drawing-master");
    const outsider = await user("drawing-outsider");
    const removed = await user("drawing-removed");
    const { data: created, error } = await master.supabase.rpc("create_room", {
      room_name: "Realtime drawing test",
      room_description: null,
      room_game_system: "test",
    });
    if (error) throw error;
    const room = Array.isArray(created) ? created[0] : created;
    assert(room?.id && room?.invite_code, "room creation returned no room");

    roomId = room.id;
    const rpc = async (name: string, args: Record<string, unknown>) => {
      const { error } = await master.supabase.rpc(name, args);
      if (error) throw error;
    };
    const join = async (member: typeof master) => {
      const { error } = await member.supabase.rpc("join_room", {
        room_invite_code: room.invite_code,
      });
      if (error) throw error;
    };
    const members = [];
    for (const role of ["player", "spectator"]) {
      for (const override of [null, true, false]) {
        const member = await user(`${role}-${override}`);
        await join(member);
        if (role === "spectator") {
          await rpc("set_room_member_role", {
            target_room_id: room.id,
            target_user_id: member.userId,
            target_role: role,
          });
        }
        if (override !== null) {
          await rpc("set_room_feature_permission", {
            target_room_id: room.id,
            target_feature: "map_view",
            new_allowed: override,
            target_role: null,
            target_user_id: member.userId,
          });
        }
        members.push({ ...member, role, override });
      }
      await rpc("set_room_feature_permission", {
        target_room_id: room.id,
        target_feature: "drawing",
        new_allowed: false,
        target_role: role,
        target_user_id: null,
      });
    }
    await join(removed);
    await rpc("force_remove_room_member", {
      target_room_id: room.id,
      target_user_id: removed.userId,
    });

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

    for (const roleAllowed of [true, false]) {
      for (const role of ["player", "spectator"]) {
        await rpc("set_room_feature_permission", {
          target_room_id: room.id,
          target_feature: "map_view",
          new_allowed: roleAllowed,
          target_role: role,
          target_user_id: null,
        });
      }
      const receivers = [
        { ...master, label: "master", allowed: true },
        ...members.map((member) => ({
          ...member,
          label: `${member.role}/${member.override}/role=${roleAllowed}`,
          allowed: member.override ?? roleAllowed,
        })),
        { ...outsider, label: "outsider", allowed: false },
        { ...removed, label: "removed", allowed: false },
      ].map((receiver) => ({ ...receiver, events: [] as DrawingEvent[] }));

      for (const receiver of receivers) {
        const channel = receiver.supabase
          .channel(`room:${room.id}:drawings`, { config: { private: true } })
          .on("broadcast", { event: "*" }, (event) => {
            receiver.events.push({
              event: event.event,
              payload: event.payload,
            });
          });
        const status = await subscribe(channel);
        assert(
          receiver.allowed
            ? status === "SUBSCRIBED"
            : status.startsWith("CHANNEL_ERROR") &&
              /permission|authoriz/i.test(status),
          `${receiver.label}: unexpected subscription result ${status}`,
        );
      }
      const id = crypto.randomUUID();
      const before = { x: 12, y: 34 };
      const after = { x: 56, y: 78 };
      const checkEvents = async (event: string, count: number) => {
        await waitFor(
          () =>
            receivers.filter((r) => r.allowed).every((r) =>
              r.events.length === count
            ),
          `${event}: allowed receivers missed Broadcast`,
        );
        await new Promise((resolve) => setTimeout(resolve, 500));
        for (const receiver of receivers) {
          assert(
            receiver.events.length === (receiver.allowed ? count : 0),
            `${receiver.label}: unexpected ${event} event count ${receiver.events.length}`,
          );
          const { data: rows, error: readError } = await receiver.supabase
            .from("room_map_drawings").select("id, geometry, text_content").eq(
              "id",
              id,
            );
          if (readError) throw readError;
          assert(
            rows.length === (receiver.allowed && event !== "DELETE" ? 1 : 0),
            `${receiver.label}: unexpected drawing DB visibility after ${event}`,
          );
          if (!receiver.allowed) continue;
          const message = receiver.events[count - 1];
          assert(message.event === event, `${receiver.label}: wrong event`);
          const row = event === "DELETE"
            ? message.payload.old_record
            : message.payload.record;
          const geometry = event === "INSERT" ? before : after;
          assert(
            row.id === id && row.geometry.x === geometry.x &&
              row.geometry.y === geometry.y &&
              row.text_content ===
                (event === "INSERT" ? "private text" : "updated private text"),
            `${receiver.label}: incorrect ${event} payload`,
          );
          if (event === "UPDATE") {
            const old = message.payload.old_record;
            assert(
              old.id === id && old.geometry.x === before.x &&
                old.geometry.y === before.y &&
                old.text_content === "private text",
              `${receiver.label}: incorrect previous row`,
            );
          }
        }
      };
      const { error: insertError } = await master.supabase.from(
        "room_map_drawings",
      ).insert({
        id,
        map_id: mapId,
        drawing_type: "text",
        geometry: before,
        text_content: "private text",
        color: "#123456",
        stroke_width: 4,
      });
      if (insertError) throw insertError;
      await checkEvents("INSERT", 1);
      const { error: updateError } = await master.supabase.from(
        "room_map_drawings",
      )
        .update({ geometry: after, text_content: "updated private text" }).eq(
          "id",
          id,
        );
      if (updateError) throw updateError;
      await checkEvents("UPDATE", 2);
      const { error: deleteError } = await master.supabase.from(
        "room_map_drawings",
      ).delete().eq("id", id);
      if (deleteError) throw deleteError;
      await checkEvents("DELETE", 3);
      await Promise.all(users.map((u) => u.supabase.removeAllChannels()));
    }
  } finally {
    await Promise.all(users.map((u) => u.supabase.removeAllChannels()));
    await Promise.all(users.map((u) => u.supabase.auth.signOut()));
    if (roomId) {
      const { error } = await admin.from("rooms").delete().eq("id", roomId);
      assert(!error, `failed to clean up test room: ${error?.message}`);
    }
    for (const u of users) {
      const { error } = await admin.auth.admin.deleteUser(u.userId);
      assert(!error, `failed to clean up test user: ${error?.message}`);
    }
    await admin.removeAllChannels();
  }
});
