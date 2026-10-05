// deno-lint-ignore-file no-import-prefix
import {
  createClient,
  type RealtimeChannel,
} from "npm:@supabase/supabase-js@2.117.2";

const url = Deno.env.get("SUPABASE_URL");
const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
if (url !== "http://127.0.0.1:54321" || !anonKey || !serviceKey) {
  throw new Error("local Supabase URL and test keys are required");
}
function assert(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}
function client(key: string) {
  return createClient(url!, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

Deno.test("jukebox RPC, Realtime and signed URL authorization, revocation and expiration", async (test) => {
  const admin = client(serviceKey!);
  const users: { id: string; token: string; api: ReturnType<typeof client> }[] =
    [];
  const paths: string[] = [];
  const events = new Map<
    string,
    { eventType: string; new: Record<string, unknown> }[]
  >();
  async function subscribe(channel: RealtimeChannel) {
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error("Realtime subscription timed out")),
        10_000,
      );
      channel.subscribe((status) => {
        if (status === "SUBSCRIBED") {
          clearTimeout(timer);
          resolve();
        } else if (["CHANNEL_ERROR", "TIMED_OUT", "CLOSED"].includes(status)) {
          clearTimeout(timer);
          reject(new Error(`Realtime subscription failed: ${status}`));
        }
      });
    });
  }
  async function expectEvent(
    state: Record<string, unknown>,
    allowed: typeof users,
    denied: typeof users,
    eventType = "UPDATE",
  ) {
    for (let attempt = 0; attempt < 100; attempt++) {
      if (
        allowed.every((user) =>
          events.get(user.id)!.some((event) =>
            event.eventType === eventType &&
            event.new.state_changed_at === state.state_changed_at &&
            event.new.music_asset_id === state.music_asset_id &&
            event.new.status === state.status &&
            event.new.position_ms === state.position_ms &&
            event.new.loop_enabled === state.loop_enabled
          )
        )
      ) break;
      if (attempt === 99) {
        throw new Error(
          `authorized member did not receive ${eventType}: ${
            JSON.stringify(allowed.map((user) =>
              events.get(user.id)!.map((event) => ({
                eventType: event.eventType,
                state: event.new,
              }))
            ))
          }`,
        );
      }
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    // Wait after positive delivery to detect unauthorized asynchronous delivery.
    await new Promise((resolve) => setTimeout(resolve, 700));
    for (const user of denied) {
      assert(
        !events.get(user.id)!.some((event) =>
          event.new.state_changed_at === state.state_changed_at
        ),
        "unauthorized member received jukebox change",
      );
    }
  }
  let roomId: string | undefined;
  let failure: unknown;
  const cleanupErrors: unknown[] = [];
  async function issue(token: string | null, body: unknown, expected: number) {
    const response = await fetch(`${url}/functions/v1/music-signed-url`, {
      method: "POST",
      headers: {
        apikey: anonKey!,
        "Content-Type": "application/json",
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: JSON.stringify(body),
    });
    const data = await response.json();
    assert(
      response.status === expected,
      `expected HTTP ${expected}, got ${response.status}`,
    );
    assert(
      response.headers.get("Cache-Control") === "no-store",
      "URL responses must not be cached",
    );
    return data;
  }
  async function download(signedUrl: string, expected: boolean) {
    const response = await fetch(signedUrl);
    const bytes = new Uint8Array(await response.arrayBuffer());
    assert(
      response.ok === expected,
      `unexpected signed download HTTP ${response.status}`,
    );
    if (expected) {
      assert(bytes.length === 4170, "unexpected downloaded file size");
    }
  }
  try {
    for (
      const label of [
        "owner",
        "player",
        "spectator",
        "left",
        "removed",
        "outsider",
      ]
    ) {
      const email = `music-${label}-${crypto.randomUUID()}@example.com`;
      const password = crypto.randomUUID();
      const { data, error } = await admin.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
        user_metadata: { nickname: label },
      });
      if (error) throw error;
      assert(data.user, "test user creation failed");
      const api = client(anonKey!);
      users.push({ id: data.user.id, token: "", api });
      const login = await api.auth.signInWithPassword({ email, password });
      if (login.error) throw login.error;
      assert(login.data.session, "test login failed");
      users[users.length - 1].token = login.data.session.access_token;
      await api.realtime.setAuth(login.data.session.access_token);
    }
    const [owner, player, spectator, left, removed, outsider] = users;
    const created = await owner.api.rpc("create_room", {
      room_name: "Music URL test",
      room_description: null,
      room_game_system: "Test",
    });
    if (created.error) throw created.error;
    const room = Array.isArray(created.data) ? created.data[0] : created.data;
    roomId = room.id;
    for (const member of [player, spectator, left, removed]) {
      const joined = await member.api.rpc("join_room", {
        room_invite_code: room.invite_code,
      });
      if (joined.error) throw joined.error;
    }
    const role = await owner.api.rpc("set_room_member_role", {
      target_room_id: roomId,
      target_user_id: spectator.id,
      target_role: "spectator",
    });
    if (role.error) throw role.error;

    const bytes = await Deno.readFile(
      new URL("../upload-music/testdata/silence.mp3", import.meta.url),
    );
    const assets: string[] = [];
    for (const title of ["Current", "Unreferenced"]) {
      const form = new FormData();
      form.set("title", title);
      form.set("file", new File([bytes], "test.mp3", { type: "audio/mpeg" }));
      const response = await fetch(`${url}/functions/v1/upload-music`, {
        method: "POST",
        headers: { apikey: anonKey!, Authorization: `Bearer ${owner.token}` },
        body: form,
      });
      const uploaded = await response.json();
      assert(
        response.status === 201 && uploaded.musicAsset,
        "fixture music upload failed",
      );
      paths.push(uploaded.musicAsset.storage_path);
      assets.push(uploaded.musicAsset.id);
    }
    for (const user of users) {
      events.set(user.id, []);
      const channel = user.api.channel(`jukebox-${user.id}-${roomId}`).on(
        "postgres_changes",
        {
          event: "*",
          schema: "public",
          table: "room_jukebox_states",
          filter: `room_id=eq.${roomId}`,
        },
        (payload) =>
          events.get(user.id)!.push({
            eventType: payload.eventType,
            new: payload.new,
          }),
      );
      await subscribe(channel);
    }
    const control = async (
      action: string,
      extra: Record<string, unknown> = {},
    ) => {
      const result = await owner.api.rpc("control_room_jukebox", {
        target_room_id: roomId,
        action,
        ...extra,
      });
      if (result.error) throw result.error;
      const state = Array.isArray(result.data) ? result.data[0] : result.data;
      assert(state?.room_id === roomId, "control returned no state");
      return state as Record<string, unknown>;
    };
    await test.step("master initializes state and only active members receive INSERT", async () => {
      const state = await control("play", { target_music_asset_id: assets[0] });
      await expectEvent(state, [owner, player, spectator, left, removed], [
        outsider,
      ], "INSERT");
    });
    await test.step("role-based DB access, RPC control and state UPDATE over WebSockets", async () => {
      for (const user of users) {
        const read = await user.api.from("room_jukebox_states").select("*").eq(
          "room_id",
          roomId!,
        );
        assert(
          !read.error && read.data.length === (user === outsider ? 0 : 1),
          "unexpected role-based state visibility",
        );
        if (user !== owner) {
          const denied = await user.api.rpc("control_room_jukebox", {
            target_room_id: roomId,
            action: "stop",
          });
          assert(
            denied.error?.code === "42501",
            "non-master control was not denied",
          );
        }
      }
      const direct = await owner.api.from("room_jukebox_states").update({
        status: "paused",
      }).eq("room_id", roomId!);
      assert(direct.error?.code === "42501", "master bypassed checked RPC");
      for (const action of ["pause", "resume"]) {
        const state = await control(action);
        await expectEvent(state, [owner, player, spectator, left, removed], [
          outsider,
        ]);
      }
    });

    await test.step("CORS, method, authentication and input validation", async () => {
      const preflight = await fetch(`${url}/functions/v1/music-signed-url`, {
        method: "OPTIONS",
      });
      await preflight.text();
      assert(
        preflight.ok &&
          preflight.headers.get("Access-Control-Allow-Methods") ===
            "POST, OPTIONS",
        "CORS preflight failed",
      );
      const get = await fetch(`${url}/functions/v1/music-signed-url`, {
        headers: { Authorization: `Bearer ${owner.token}` },
      });
      await get.text();
      assert(get.status === 405, "GET must be rejected");
      await issue(null, { musicAssetId: assets[0] }, 401);
      await issue("invalid-token", { musicAssetId: assets[0] }, 401);
      await issue(owner.token, { musicAssetId: "not-a-uuid" }, 400);
    });
    await test.step("owner, player and spectator get usable five-minute URLs", async () => {
      for (const member of [owner, player, spectator]) {
        const signed = await issue(member.token, {
          musicAssetId: assets[0],
          expiresIn: 999999,
        }, 200);
        assert(signed.expiresIn === 300, "client cannot override endpoint TTL");
        const token = new URL(signed.signedUrl).searchParams.get("token")!;
        const claims = JSON.parse(
          atob(token.split(".")[1].replaceAll("-", "+").replaceAll("_", "/")),
        );
        assert(
          claims.exp - claims.iat === 300,
          "actual signed token lifetime must be 300s",
        );
        await download(signed.signedUrl, true);
      }
      await issue(owner.token, { musicAssetId: assets[1] }, 200);
      const library = await player.api.from("music_assets").select("id");
      assert(
        !library.error && library.data.length === 0,
        "room access must not expose owner library",
      );
    });
    await test.step("outsider, unreferenced music and fake room claims are denied", async () => {
      await issue(outsider.token, {
        musicAssetId: assets[0],
        roomId,
        storagePath: paths[0],
      }, 403);
      await issue(player.token, { musicAssetId: assets[1], roomId }, 403);
      await issue(player.token, { musicAssetId: crypto.randomUUID() }, 403);
      const forged = await player.api.from("room_jukebox_states").update({
        music_asset_id: assets[1],
      }).eq("room_id", roomId!);
      assert(
        forged.error,
        "player must not be able to create its own authorization",
      );
    });
    await test.step("leaving and forced removal deny new URLs with the same JWT", async () => {
      const issuedLeft = await issue(
        left.token,
        { musicAssetId: assets[0] },
        200,
      );
      const issuedRemoved = await issue(removed.token, {
        musicAssetId: assets[0],
      }, 200);
      // There is no leave-room RPC yet. Seed its persisted state as postgres;
      // service_role cannot call the private system-message trigger directly.
      const departed = new Deno.Command("docker", {
        args: [
          "exec",
          "-i",
          "supabase_db_Ellimium-BE",
          "psql",
          "-U",
          "postgres",
          "-d",
          "postgres",
          "-v",
          "ON_ERROR_STOP=1",
        ],
        stdin: "piped",
        stdout: "null",
        stderr: "piped",
      }).spawn();
      const writer = departed.stdin.getWriter();
      await writer.write(new TextEncoder().encode(
        `update public.room_members set status = 'left' where room_id = '${roomId}' and user_id = '${left.id}';`,
      ));
      await writer.close();
      const departedResult = await departed.output();
      assert(departedResult.success, "could not seed departed member state");
      const kicked = await owner.api.rpc("force_remove_room_member", {
        target_room_id: roomId,
        target_user_id: removed.id,
      });
      if (kicked.error) throw kicked.error;
      for (const user of [left, removed]) {
        const read = await user.api.from("room_jukebox_states").select("*").eq(
          "room_id",
          roomId!,
        );
        assert(
          !read.error && read.data.length === 0,
          "departed member can read state with old JWT",
        );
        const denied = await user.api.rpc("control_room_jukebox", {
          target_room_id: roomId,
          action: "stop",
        });
        assert(
          denied.error?.code === "42501",
          "departed member can control state with old JWT",
        );
      }
      const state = await control("seek", { target_position_ms: 50 });
      await expectEvent(state, [owner, player, spectator], [
        left,
        removed,
        outsider,
      ]);
      await issue(left.token, { musicAssetId: assets[0] }, 403);
      await issue(removed.token, { musicAssetId: assets[0] }, 403);
      await download(issuedLeft.signedUrl, true);
      await download(issuedRemoved.signedUrl, true);
      const direct = await left.api.storage.from("music-assets")
        .createSignedUrl(paths[0], 300);
      assert(direct.error, "direct Storage API must also enforce departure");
      const removedDirect = await removed.api.storage.from("music-assets")
        .createSignedUrl(paths[0], 300);
      assert(
        removedDirect.error,
        "direct Storage API must also enforce removal",
      );
    });
    await test.step("reference replacement and clearing recheck access", async () => {
      const old = await issue(player.token, { musicAssetId: assets[0] }, 200);
      const changed = await control("play", {
        target_music_asset_id: assets[1],
        target_loop_enabled: true,
      });
      await expectEvent(changed, [owner, player, spectator], [
        left,
        removed,
        outsider,
      ]);
      await issue(player.token, { musicAssetId: assets[0] }, 403);
      await issue(player.token, { musicAssetId: assets[1] }, 200);
      await download(old.signedUrl, true);
      const cleared = await control("stop");
      await expectEvent(cleared, [owner, player, spectator], [
        left,
        removed,
        outsider,
      ]);
      assert(
        cleared.music_asset_id === null && cleared.position_ms === 0 &&
          cleared.loop_enabled === false,
        "stop did not clear playback fields",
      );
      await issue(player.token, { musicAssetId: assets[1] }, 403);
      await issue(owner.token, { musicAssetId: assets[0] }, 200);
    });
    await test.step("current music deletion sends a stopped UPDATE and denies URL renewal", async () => {
      await control("play", {
        target_music_asset_id: assets[1],
        target_position_ms: 100,
        target_loop_enabled: true,
      });
      const response = await fetch(`${url}/functions/v1/delete-music`, {
        method: "POST",
        headers: {
          apikey: anonKey!,
          Authorization: `Bearer ${owner.token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ musicAssetId: assets[1] }),
      });
      await response.json();
      assert(response.ok, "current music deletion failed");
      const read = await owner.api.from("room_jukebox_states").select("*").eq(
        "room_id",
        roomId!,
      ).single();
      if (read.error) throw read.error;
      assert(
        read.data.status === "stopped" && read.data.music_asset_id === null &&
          read.data.position_ms === 0 && !read.data.loop_enabled,
        "deletion did not preserve and clear the state row",
      );
      await expectEvent(read.data, [owner, player, spectator], [
        left,
        removed,
        outsider,
      ]);
      assert(
        [...events.values()].every((received) =>
          received.every((event) => event.eventType !== "DELETE")
        ),
        "music deletion must not delete the state row",
      );
      await issue(player.token, { musicAssetId: assets[1] }, 403);
      await issue(owner.token, { musicAssetId: assets[1] }, 403);
    });
    await test.step("departed member's previously issued Storage token expires", async () => {
      const state = await control("play", { target_music_asset_id: assets[0] });
      await expectEvent(state, [owner, player, spectator], [
        left,
        removed,
        outsider,
      ]);
      const short = await player.api.storage.from("music-assets")
        .createSignedUrl(paths[0], 2);
      if (short.error) throw short.error;
      const kicked = await owner.api.rpc("force_remove_room_member", {
        target_room_id: roomId,
        target_user_id: player.id,
      });
      if (kicked.error) throw kicked.error;
      await issue(player.token, { musicAssetId: assets[0] }, 403);
      await download(short.data.signedUrl, true);
      await new Promise((resolve) => setTimeout(resolve, 3100));
      await download(short.data.signedUrl, false);
    });
    await test.step("Storage signed token expires even without membership changes", async () => {
      // Exercise the same Storage issuer with a short TTL instead of waiting 5 minutes.
      const short = await owner.api.storage.from("music-assets")
        .createSignedUrl(paths[0], 2);
      if (short.error) throw short.error;
      await download(short.data.signedUrl, true);
      await new Promise((resolve) => setTimeout(resolve, 3100));
      await download(short.data.signedUrl, false);
    });
  } catch (error) {
    failure = error;
  } finally {
    for (const user of users) {
      try {
        await user.api.removeAllChannels();
        user.api.realtime.disconnect();
      } catch (error) {
        cleanupErrors.push(error);
      }
    }
    if (roomId) {
      const deleted = await admin.from("rooms").delete().eq("id", roomId);
      if (deleted.error) cleanupErrors.push(deleted.error);
    }
    if (paths.length) {
      const files = await admin.storage.from("music-assets").remove(paths);
      if (files.error) cleanupErrors.push(files.error);
    }
    for (const user of users) {
      const deleted = await admin.auth.admin.deleteUser(user.id);
      if (deleted.error) cleanupErrors.push(deleted.error);
    }
  }
  const errors = [...(failure ? [failure] : []), ...cleanupErrors];
  if (errors.length) {
    throw new AggregateError(errors, "music URL test or cleanup failed");
  }
});
