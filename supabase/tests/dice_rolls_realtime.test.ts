// deno-lint-ignore-file no-import-prefix
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

Deno.test("private dice results reach only the master and roller", async () => {
  const master = await register("dice-master");
  const roller = await register("dice-roller");
  const otherPlayer = await register("dice-other-player");
  const clients: SupabaseClient[] = [
    master.supabase,
    roller.supabase,
    otherPlayer.supabase,
  ];

  try {
    const { data: created, error: createError } = await master.supabase.rpc(
      "create_room",
      {
        room_name: "Realtime dice test",
        room_description: null,
        room_game_system: "test",
      },
    );
    if (createError) throw createError;
    const room = Array.isArray(created) ? created[0] : created;
    assert(room?.id && room?.invite_code, "room creation returned no room");

    for (const member of [roller, otherPlayer]) {
      const { error } = await member.supabase.rpc("join_room", {
        room_invite_code: room.invite_code,
      });
      if (error) throw error;
    }

    const received = {
      master: {
        details: [] as Record<string, unknown>[],
        notifications: [] as Record<string, unknown>[],
      },
      roller: {
        details: [] as Record<string, unknown>[],
        notifications: [] as Record<string, unknown>[],
      },
      otherPlayer: {
        details: [] as Record<string, unknown>[],
        notifications: [] as Record<string, unknown>[],
      },
    };
    const members = [
      ["master", master.supabase],
      ["roller", roller.supabase],
      ["otherPlayer", otherPlayer.supabase],
    ] as const;
    const channels = members.map(([role, supabase]) =>
      supabase
        .channel(`room:${room.id}:dice`, { config: { private: true } })
        .on(
          "postgres_changes",
          {
            event: "INSERT",
            schema: "public",
            table: "dice_rolls",
            filter: `room_id=eq.${room.id}`,
          },
          ({ new: row }) => received[role].details.push(row),
        )
        .on(
          "postgres_changes",
          {
            event: "INSERT",
            schema: "public",
            table: "dice_roll_notifications",
            filter: `room_id=eq.${room.id}`,
          },
          ({ new: row }) => received[role].notifications.push(row),
        )
    );

    for (const channel of channels) {
      const status = await subscribe(channel);
      assert(
        status === "SUBSCRIBED",
        `active room member was not subscribed: ${status}`,
      );
    }
    await new Promise((resolve) => setTimeout(resolve, 3_000));

    const { error: rollError } = await roller.supabase.rpc("roll_dice", {
      target_room_id: room.id,
      dice_expression: "1d20",
      roll_visibility: "private",
    });
    if (rollError) throw rollError;

    await waitFor(
      () =>
        received.master.details.length === 1 &&
        received.roller.details.length === 1 &&
        received.master.notifications.length === 1 &&
        received.roller.notifications.length === 1 &&
        received.otherPlayer.notifications.length === 1,
      () =>
        `Realtime change was not received: ${
          JSON.stringify(
            Object.fromEntries(
              Object.entries(received).map(([role, events]) => [
                role,
                {
                  details: events.details.length,
                  notifications: events.notifications.length,
                },
              ]),
            ),
          )
        }`,
    );
    await new Promise((resolve) => setTimeout(resolve, 500));

    assert(
      received.otherPlayer.details.length === 0,
      "another player received private dice details",
    );
    const notification = received.otherPlayer.notifications[0];
    assert(
      notification.visibility === "private",
      "notification lost visibility",
    );
    assert(
      !("expression" in notification) &&
        !("individual_results" in notification) &&
        !("total" in notification),
      "notification exposed private dice values",
    );
  } finally {
    await Promise.all(clients.map((supabase) => supabase.removeAllChannels()));
    await Promise.all(clients.map((supabase) => supabase.auth.signOut()));
  }
});
