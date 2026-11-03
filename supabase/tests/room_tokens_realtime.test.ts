// deno-lint-ignore-file no-import-prefix
import {
  createClient,
  type RealtimeChannel,
} from "npm:@supabase/supabase-js@2.117.2";

const url = Deno.env.get("SUPABASE_URL") ?? "http://127.0.0.1:54321";
const key = Deno.env.get("SUPABASE_ANON_KEY");
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
if (!key || !serviceKey) {
  throw new Error("local anon and service role keys are required");
}
if (new URL(url).hostname !== "127.0.0.1") {
  throw new Error("This fixture runs only on local Supabase");
}

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}
function check(result: { error: { message: string } | null }) {
  if (result.error) throw new Error(result.error.message);
}
function client(apiKey = key!) {
  return createClient(url, apiKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}
async function subscribe(channel: RealtimeChannel) {
  return await new Promise<string>((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error("subscription timed out")),
      10_000,
    );
    channel.subscribe((status) => {
      if (
        !["SUBSCRIBED", "CHANNEL_ERROR", "TIMED_OUT", "CLOSED"].includes(status)
      ) return;
      clearTimeout(timer);
      resolve(status);
    });
  });
}
async function waitFor(condition: () => boolean) {
  for (let i = 0; i < 50; i++) {
    if (condition()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error("verified Broadcast was not received");
}

type Movement = { token_id: string; x: number; y: number; sender_id: string };

Deno.test("token movement validates every RPC and rejects direct Broadcast over real WebSockets", async () => {
  const admin = client(serviceKey!);
  const users: { id: string; api: ReturnType<typeof client> }[] = [];
  const rooms: string[] = [];
  const assets: string[] = [];
  const anonymous = client();
  let anonymousId: string | undefined;
  async function user(label: string) {
    const email = `token-${label}-${crypto.randomUUID()}@example.com`;
    const password = crypto.randomUUID();
    const created = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { nickname: label },
    });
    check(created);
    assert(created.data.user, "user creation returned no user");
    const entry = { id: created.data.user.id, api: client() };
    users.push(entry);
    const signed = await entry.api.auth.signInWithPassword({ email, password });
    check(signed);
    assert(signed.data.session, "sign-in returned no session");
    await entry.api.realtime.setAuth(signed.data.session.access_token);
    return entry;
  }
  try {
    const master = await user("master");
    const player = await user("player");
    const peer = await user("peer");
    const spectator = await user("spectator");
    const removed = await user("removed");
    const outsider = await user("outsider");
    for (let i = 0; i < 2; i++) {
      const created = await master.api.rpc("create_room", {
        room_name: `Token movement ${i}`,
        room_description: null,
        room_game_system: "test",
      });
      check(created);
      const room = created.data;
      rooms.push(room.id);
      for (
        const member of i === 0 ? [player, peer, spectator, removed] : [player]
      ) {
        check(
          await member.api.rpc("join_room", {
            room_invite_code: room.invite_code,
          }),
        );
      }
    }
    const roomId = rooms[0];
    const role = async (userId: string, targetRole: string) => {
      check(
        await master.api.rpc("set_room_member_role", {
          target_room_id: roomId,
          target_user_id: userId,
          target_role: targetRole,
        }),
      );
    };
    const permission = async (allowed: boolean, userId = player.id) => {
      check(
        await master.api.rpc("set_room_feature_permission", {
          target_room_id: roomId,
          target_feature: "token_move",
          new_allowed: allowed,
          target_role: null,
          target_user_id: userId,
        }),
      );
    };
    await role(spectator.id, "spectator");
    check(
      await master.api.rpc("force_remove_room_member", {
        target_room_id: roomId,
        target_user_id: removed.id,
      }),
    );
    const signed = await anonymous.auth.signInAnonymously({
      options: { data: { nickname: "anonymous" } },
    });
    check(signed);
    assert(signed.data.session, "anonymous sign-in failed");
    anonymousId = signed.data.user?.id;
    await anonymous.realtime.setAuth(signed.data.session.access_token);

    const maps: string[] = [];
    for (const room_id of rooms) {
      const assetId = crypto.randomUUID();
      check(
        await admin.from("assets").insert({
          id: assetId,
          owner_id: master.id,
          category: "map",
          storage_path: `${master.id}/${assetId}.png`,
        }),
      );
      assets.push(assetId);
      const map = await master.api.from("room_maps").insert({
        room_id,
        asset_id: assetId,
      }).select("id").single();
      check(map);
      assert(map.data, "map creation failed");
      maps.push(map.data.id);
    }
    const [own, other, unassigned, foreign] = Array.from(
      { length: 4 },
      () => crypto.randomUUID(),
    );
    check(
      await master.api.from("room_tokens").insert([
        {
          id: own,
          map_id: maps[0],
          owner_id: player.id,
          name: "own",
          x: 1,
          y: 2,
        },
        {
          id: other,
          map_id: maps[0],
          owner_id: peer.id,
          name: "peer",
          x: 1,
          y: 2,
        },
        { id: unassigned, map_id: maps[0], name: "unassigned", x: 1, y: 2 },
        {
          id: foreign,
          map_id: maps[1],
          owner_id: player.id,
          name: "foreign",
          x: 1,
          y: 2,
        },
      ]),
    );
    const topic = `room:${roomId}:token-movements`;
    const receivers = [master, player, peer, spectator].map((u) => ({
      ...u,
      events: [] as Movement[],
    }));
    const channels = receivers.map((receiver) =>
      receiver.api.channel(topic, {
        config: { private: true, broadcast: { self: false, ack: true } },
      })
        .on(
          "broadcast",
          { event: "token-move" },
          ({ payload }) => receiver.events.push(payload),
        )
    );
    for (const channel of channels) {
      assert(
        await subscribe(channel) === "SUBSCRIBED",
        "map viewer could not subscribe",
      );
    }
    for (const api of [outsider.api, removed.api, anonymous]) {
      const channel = api.channel(topic, { config: { private: true } });
      assert(
        await subscribe(channel) === "CHANNEL_ERROR",
        "non-member subscribed",
      );
      await api.removeChannel(channel);
    }
    const wrong = master.api.channel(`${topic}:extra`, {
      config: { private: true },
    });
    assert(
      await subscribe(wrong) === "CHANNEL_ERROR",
      "inexact topic subscribed",
    );
    await master.api.removeChannel(wrong);

    let count = 0;
    const move = (
      api: ReturnType<typeof client>,
      tokenId: string = own,
      targetRoom = roomId,
      x: unknown = 10,
      y: unknown = 20,
    ) => {
      return api.rpc("broadcast_token_movement", {
        target_room_id: targetRoom,
        target_token_id: tokenId,
        position_x: x,
        position_y: y,
      });
    };
    const unchanged = async () => {
      await new Promise((resolve) => setTimeout(resolve, 250));
      assert(
        receivers.every((r) => r.events.length === count),
        "denied movement reached a receiver",
      );
      const saved = await admin.from("room_tokens").select("x,y").in("id", [
        own,
        other,
        unassigned,
        foreign,
      ]);
      check(saved);
      assert(
        saved.data?.length === 4 &&
          saved.data.every((t) => t.x === 1 && t.y === 2),
        "temporary movement changed DB coordinates",
      );
    };
    const allowed = async (who: typeof master, tokenId: string) => {
      check(await move(who.api, tokenId));
      count++;
      await waitFor(() => receivers.every((r) => r.events.length === count));
      assert(
        receivers.every((r) => {
          const m = r.events[count - 1];
          return m.token_id === tokenId && m.x === 10 && m.y === 20 &&
            m.sender_id === who.id;
        }),
        "incorrect server movement payload",
      );
      await unchanged();
    };
    const denied = async (
      api: ReturnType<typeof client>,
      tokenId: string = own,
      targetRoom = roomId,
      x: unknown = 10,
      y: unknown = 20,
    ) => {
      const result = await move(api, tokenId, targetRoom, x, y);
      assert(
        result.error?.code === "42501" || result.error?.code === "22023",
        `unauthorized movement not denied: ${result.error?.message}`,
      );
      await unchanged();
    };
    for (const tokenId of [own, other, unassigned]) {
      await allowed(master, tokenId);
    }
    await allowed(player, own);
    for (const tokenId of [other, unassigned, foreign, crypto.randomUUID()]) {
      await denied(player.api, tokenId);
    }
    await denied(master.api, foreign);
    await denied(player.api, own, rooms[1]);
    for (
      const api of [
        spectator.api,
        outsider.api,
        removed.api,
        anonymous,
        client(),
      ]
    ) await denied(api);
    for (const invalid of [null, "NaN", "Infinity", "-Infinity"]) {
      await denied(player.api, own, roomId, invalid, 1);
      await denied(player.api, own, roomId, 1, invalid);
    }

    // An established channel must not preserve RPC authorization after a change.
    await permission(false);
    await denied(player.api);
    await permission(true);
    await allowed(player, own);
    check(
      await master.api.from("room_tokens").update({ owner_id: peer.id }).eq(
        "id",
        own,
      ),
    );
    await denied(player.api);
    await allowed(peer, own);
    check(
      await master.api.from("room_tokens").update({ owner_id: null }).eq(
        "id",
        own,
      ),
    );
    await denied(peer.api);
    check(
      await master.api.from("room_tokens").update({ owner_id: player.id }).eq(
        "id",
        own,
      ),
    );
    await role(player.id, "spectator");
    await permission(true);
    await denied(player.api);
    await role(player.id, "player");
    check(
      await master.api.from("room_tokens").update({ owner_id: player.id }).eq(
        "id",
        own,
      ),
    );
    await allowed(player, own);

    // Both WebSocket and REST direct-send bypasses must be closed for every role.
    for (const channel of channels) {
      const result = await channel.send({
        type: "broadcast",
        event: "token-move",
        payload: { token_id: other, x: 999, y: 999 },
      }, { timeout: 1_000 });
      assert(result !== "ok", "direct WebSocket Broadcast was allowed");
      await unchanged();
    }
    const session = await peer.api.auth.getSession();
    const response = await fetch(`${url}/realtime/v1/api/broadcast`, {
      method: "POST",
      headers: {
        apikey: key!,
        Authorization: `Bearer ${session.data.session!.access_token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        messages: [{
          topic,
          event: "token-move",
          payload: { token_id: other, x: 999, y: 999 },
          private: true,
        }],
      }),
    });
    await response.text();
    // Batch REST can acknowledge the envelope (202) while dropping unauthorized messages.
    await new Promise((resolve) => setTimeout(resolve, 1_000));
    assert(
      [202, 401, 403].includes(response.status),
      `direct REST Broadcast returned ${response.status}`,
    );
    await unchanged();
    check(
      await master.api.rpc("force_remove_room_member", {
        target_room_id: roomId,
        target_user_id: player.id,
      }),
    );
    await denied(player.api);
    await allowed(master, unassigned);
  } finally {
    await Promise.all(
      [...users.map((u) => u.api), anonymous].map((api) =>
        api.removeAllChannels()
      ),
    );
    await Promise.all(
      [...users.map((u) => u.api), anonymous].map((api) => api.auth.signOut()),
    );
    if (rooms.length) check(await admin.from("rooms").delete().in("id", rooms));
    if (assets.length) {
      check(await admin.from("assets").delete().in("id", assets));
    }
    for (const u of users) check(await admin.auth.admin.deleteUser(u.id));
    if (anonymousId) check(await admin.auth.admin.deleteUser(anonymousId));
    await admin.removeAllChannels();
  }
});
