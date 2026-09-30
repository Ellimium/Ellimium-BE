import {
  createClient,
  type RealtimeChannel,
  type SupabaseClient,
} from "npm:@supabase/supabase-js@2.117.2";

const url = Deno.env.get("SUPABASE_URL") ?? "http://127.0.0.1:54321";
const key = Deno.env.get("SUPABASE_ANON_KEY");

if (!key) throw new Error("SUPABASE_ANON_KEY is required");

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function client() {
  return createClient(url, key!, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}

async function register(label: string) {
  const supabase = client();
  const email = `${label}-${crypto.randomUUID()}@example.com`;
  const { data, error } = await supabase.auth.signUp({
    email,
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
    channel.subscribe((status) => {
      if (
        !["SUBSCRIBED", "CHANNEL_ERROR", "TIMED_OUT", "CLOSED"].includes(status)
      ) return;
      clearTimeout(timeout);
      resolve(status);
    });
  });
}

async function waitFor(condition: () => boolean) {
  for (let attempt = 0; attempt < 50; attempt++) {
    if (condition()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error("Broadcast was not received");
}

Deno.test("token private channel enforces room roles over real WebSockets", async () => {
  const master = await register("token-master");
  const player = await register("token-player");
  const spectator = await register("token-spectator");
  const removed = await register("token-removed");
  const other = await register("token-other");
  const anonymous = client();
  const clients: SupabaseClient[] = [
    master.supabase,
    player.supabase,
    spectator.supabase,
    removed.supabase,
    other.supabase,
    anonymous,
  ];

  try {
    const { data: created, error: createError } = await master.supabase.rpc(
      "create_room",
      {
        room_name: "Realtime token test",
        room_description: null,
        room_game_system: "test",
      },
    );
    if (createError) throw createError;
    const room = Array.isArray(created) ? created[0] : created;
    assert(room?.id && room?.invite_code, "room creation returned no room");

    for (const member of [player, spectator, removed]) {
      const { error } = await member.supabase.rpc("join_room", {
        room_invite_code: room.invite_code,
      });
      if (error) throw error;
    }

    const { error: roleError } = await master.supabase.rpc(
      "set_room_member_role",
      {
        target_room_id: room.id,
        target_user_id: spectator.userId,
        target_role: "spectator",
      },
    );
    if (roleError) throw roleError;

    const { error: removeError } = await master.supabase.rpc(
      "force_remove_room_member",
      {
        target_room_id: room.id,
        target_user_id: removed.userId,
      },
    );
    if (removeError) throw removeError;

    const { error: otherRoomError } = await other.supabase.rpc("create_room", {
      room_name: "Other room",
      room_description: null,
      room_game_system: "test",
    });
    if (otherRoomError) throw otherRoomError;

    const { data: anonymousAuth, error: anonymousError } = await anonymous.auth
      .signInAnonymously({ options: { data: { nickname: "anonymous" } } });
    if (anonymousError || !anonymousAuth.session) {
      throw anonymousError ??
        new Error("anonymous sign-in returned no session");
    }
    await anonymous.realtime.setAuth(anonymousAuth.session.access_token);

    const topic = `room:${room.id}:tokens`;
    const received = {
      master: [] as unknown[],
      player: [] as unknown[],
      spectator: [] as unknown[],
    };
    const allowed = [
      ["master", master.supabase],
      ["player", player.supabase],
      ["spectator", spectator.supabase],
    ] as const;
    const channels = allowed.map(([role, supabase]) =>
      supabase
        .channel(topic, {
          config: { private: true, broadcast: { self: false, ack: true } },
        })
        .on(
          "broadcast",
          { event: "token-move" },
          ({ payload }) => received[role].push(payload),
        )
    );

    for (const channel of channels) {
      assert(
        await subscribe(channel) === "SUBSCRIBED",
        "active room member was not subscribed",
      );
    }

    assert(
      await channels[0].send({
        type: "broadcast",
        event: "token-move",
        payload: { token_id: crypto.randomUUID(), x: 1, y: 2 },
      }) === "ok",
      "master broadcast was rejected",
    );
    await waitFor(() =>
      received.player.length === 1 && received.spectator.length === 1
    );

    assert(
      await channels[1].send({
        type: "broadcast",
        event: "token-move",
        payload: { token_id: crypto.randomUUID(), x: 3, y: 4 },
      }) === "ok",
      "player broadcast was rejected",
    );
    await waitFor(() =>
      received.master.length === 1 && received.spectator.length === 2
    );

    assert(
      await channels[2].send({
        type: "broadcast",
        event: "token-move",
        payload: { token_id: crypto.randomUUID(), x: 5, y: 6 },
      }, { timeout: 1_000 }) !== "ok",
      "spectator broadcast was allowed",
    );

    for (
      const [label, supabase] of [
        ["other room member", other.supabase],
        ["removed member", removed.supabase],
        ["anonymous user", anonymous],
      ] as const
    ) {
      const channel = supabase.channel(topic, { config: { private: true } });
      assert(
        await subscribe(channel) === "CHANNEL_ERROR",
        `${label} subscribed to the token channel`,
      );
      await supabase.removeChannel(channel);
    }

    const wrongTopic = master.supabase.channel(`${topic}:extra`, {
      config: { private: true },
    });
    assert(
      await subscribe(wrongTopic) === "CHANNEL_ERROR",
      "an inexact token topic was allowed",
    );
    await master.supabase.removeChannel(wrongTopic);
  } finally {
    await Promise.all(clients.map((supabase) => supabase.removeAllChannels()));
    await Promise.all(clients.map((supabase) => supabase.auth.signOut()));
  }
});
