import { createClient } from "npm:@supabase/supabase-js@2.117.2";
const url = Deno.env.get("SUPABASE_URL");
const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
if (url !== "http://127.0.0.1:54321" || !anonKey || !serviceKey) {
  throw new Error("local test URL and keys are required");
}
function assert(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}
function client(key: string) {
  return createClient(url!, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

Deno.test("owner deletion stops referenced rooms and supports retry and duplicate requests", async (test) => {
  const admin = client(serviceKey!);
  const users: { id: string; token: string; api: ReturnType<typeof client> }[] =
    [];
  const rooms: string[] = [];
  const assets: { id: string; storage_path: string }[] = [];
  let failure: unknown;
  const cleanupErrors: unknown[] = [];
  async function call(
    token: string | null,
    musicAssetId: string,
    status = 200,
    endpoint = "delete-music",
  ) {
    const response = await fetch(`${url}/functions/v1/${endpoint}`, {
      method: "POST",
      headers: {
        apikey: anonKey!,
        "Content-Type": "application/json",
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: JSON.stringify({ musicAssetId }),
    });
    const result = await response.json();
    assert(
      response.status === status,
      `${endpoint}: expected ${status}, got ${response.status}`,
    );
    return result;
  }
  async function assertGone(asset: { id: string; storage_path: string }) {
    const row = await admin.from("music_assets").select("id").eq(
      "id",
      asset.id,
    );
    assert(!row.error && row.data.length === 0, "metadata was not deleted");
    const exists = await admin.storage.from("music-assets").exists(
      asset.storage_path,
    );
    const absent = exists.data === false &&
      (!exists.error ||
        ("status" in exists.error &&
          [400, 404].includes(Number(exists.error.status))));
    assert(absent, "file deletion was not confirmed by Storage");
  }
  try {
    for (const label of ["owner", "member"]) {
      const email = `delete-${label}-${crypto.randomUUID()}@example.com`;
      const password = crypto.randomUUID();
      const created = await admin.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
        user_metadata: { nickname: label },
      });
      if (created.error) throw created.error;
      assert(created.data.user, "user creation failed");
      const api = client(anonKey!);
      users.push({ id: created.data.user.id, token: "", api });
      const login = await api.auth.signInWithPassword({ email, password });
      if (login.error) throw login.error;
      assert(login.data.session, "login failed");
      users.at(-1)!.token = login.data.session.access_token;
    }
    const [owner, member] = users;
    for (let index = 0; index < 3; index++) {
      const created = await owner.api.rpc("create_room", {
        room_name: "Music deletion test",
        room_description: null,
        room_game_system: "Test",
      });
      if (created.error) throw created.error;
      const room = Array.isArray(created.data) ? created.data[0] : created.data;
      rooms.push(room.id);
      const joined = await member.api.rpc("join_room", {
        room_invite_code: room.invite_code,
      });
      if (joined.error) throw joined.error;
    }
    const bytes = await Deno.readFile(
      new URL("../upload-music/testdata/silence.mp3", import.meta.url),
    );
    for (
      const title of [
        "Used",
        "Keep",
        "Interrupted before file cleanup",
        "Interrupted after file cleanup",
        "Concurrent delete",
      ]
    ) {
      const form = new FormData();
      form.set("title", title);
      form.set("file", new File([bytes], "test.mp3", { type: "audio/mpeg" }));
      const response = await fetch(`${url}/functions/v1/upload-music`, {
        method: "POST",
        headers: { apikey: anonKey!, Authorization: `Bearer ${owner.token}` },
        body: form,
      });
      const result = await response.json();
      assert(
        response.status === 201 && result.musicAsset,
        "fixture music upload failed",
      );
      assets.push(result.musicAsset);
    }
    const linked = await admin.from("room_jukebox_states").insert([
      { room_id: rooms[0], music_asset_id: assets[0].id, status: "playing" },
      { room_id: rooms[1], music_asset_id: assets[0].id, status: "paused" },
      { room_id: rooms[2], music_asset_id: assets[1].id, status: "playing" },
    ]);
    if (linked.error) throw linked.error;
    await test.step("authentication, input and non-owner rejection leave music intact", async () => {
      const preflight = await fetch(`${url}/functions/v1/delete-music`, {
        method: "OPTIONS",
      });
      await preflight.text();
      assert(preflight.ok, "CORS failed");
      const get = await fetch(`${url}/functions/v1/delete-music`);
      await get.text();
      assert(get.status === 405, "GET must be rejected");
      await call(null, assets[0].id, 401);
      await call("invalid-token", assets[0].id, 401);
      await call(owner.token, "invalid-id", 400);
      await call(member.token, assets[0].id, 403);
      const current = await admin.from("room_jukebox_states").select(
        "music_asset_id,status",
      ).eq("room_id", rooms[0]).single();
      assert(
        !current.error && current.data.status === "playing" &&
          current.data.music_asset_id === assets[0].id,
        "denied deletion changed room",
      );
      const exists = await admin.storage.from("music-assets").exists(
        assets[0].storage_path,
      );
      assert(!exists.error && exists.data, "denied deletion removed file");
      const direct = await owner.api.rpc("finish_music_asset_deletion", {
        target_music_asset_id: assets[0].id,
        target_owner_id: owner.id,
      });
      assert(
        direct.error?.code === "42501",
        "client must not bypass Storage cleanup",
      );
    });
    await test.step("deleting playing/paused music stops all references and preserves other music", async () => {
      const before = await call(
        member.token,
        assets[0].id,
        200,
        "music-signed-url",
      );
      const deleted = await call(owner.token, assets[0].id);
      assert(deleted.deleted === true, "owner deletion did not complete");
      await assertGone(assets[0]);
      const state = await admin.from("room_jukebox_states").select(
        "room_id,music_asset_id,status",
      );
      assert(!state.error, "state read failed");
      for (const room of rooms.slice(0, 2)) {
        const row = state.data.find((value) => value.room_id === room);
        assert(
          row?.status === "stopped" && row.music_asset_id === null,
          "state row was removed or failed to stop",
        );
      }
      const unchanged = state.data.find((value) => value.room_id === rooms[2]);
      assert(
        unchanged?.status === "playing" &&
          unchanged.music_asset_id === assets[1].id,
        "unrelated music changed",
      );
      await call(member.token, assets[0].id, 403, "music-signed-url");
      const oldUrl = await fetch(before.signedUrl);
      await oldUrl.arrayBuffer();
      assert(!oldUrl.ok, "deleted object must no longer be downloadable");
      const keep = await admin.storage.from("music-assets").exists(
        assets[1].storage_path,
      );
      assert(!keep.error && keep.data, "unrelated file was deleted");
    });
    await test.step("repeated and already-missing deletion are successful no-ops", async () => {
      assert(
        (await call(owner.token, assets[0].id)).deleted === false,
        "repeated deletion is not idempotent",
      );
      assert(
        (await call(owner.token, crypto.randomUUID())).deleted === false,
        "missing deletion is not idempotent",
      );
    });
    await test.step("interrupted cleanup retains path, denies playback and resumes", async () => {
      for (const [index, fileRemoved] of [[2, false], [3, true]] as const) {
        const asset = assets[index];
        const linked = await admin.from("room_jukebox_states").update({
          music_asset_id: asset.id,
          status: "playing",
        }).eq("room_id", rooms[0]);
        if (linked.error) throw linked.error;
        const prepared = await owner.api.rpc("prepare_music_asset_deletion", {
          target_music_asset_id: asset.id,
        });
        assert(
          !prepared.error && prepared.data === asset.storage_path,
          "preparation failed",
        );
        const retryRow = await owner.api.from("music_assets").select(
          "deletion_pending,storage_path",
        ).eq("id", asset.id).single();
        assert(
          !retryRow.error && retryRow.data.deletion_pending &&
            retryRow.data.storage_path === asset.storage_path,
          "retry state was lost",
        );
        await call(owner.token, asset.id, 403, "music-signed-url");
        const reselection = await admin.from("room_jukebox_states").update({
          music_asset_id: asset.id,
          status: "playing",
        }).eq("room_id", rooms[0]);
        assert(
          reselection.error?.code === "23514",
          "pending music can be reselected",
        );
        if (fileRemoved) {
          const removed = await admin.storage.from("music-assets").remove([
            asset.storage_path,
          ]);
          if (removed.error) throw removed.error;
        }
        assert(
          (await call(owner.token, asset.id)).deleted === true,
          "cleanup retry failed",
        );
        await assertGone(asset);
      }
    });
    await test.step("concurrent owner requests converge on one deletion", async () => {
      await Promise.all([
        call(owner.token, assets[4].id),
        call(owner.token, assets[4].id),
      ]);
      await assertGone(assets[4]);
    });
  } catch (error) {
    failure = error;
  } finally {
    for (const room of rooms) {
      const deleted = await admin.from("rooms").delete().eq("id", room);
      if (deleted.error) cleanupErrors.push(deleted.error);
    }
    if (assets.length) {
      const deleted = await admin.storage.from("music-assets").remove(
        assets.map((asset) => asset.storage_path),
      );
      if (deleted.error) cleanupErrors.push(deleted.error);
    }
    for (const user of users) {
      const deleted = await admin.auth.admin.deleteUser(user.id);
      if (deleted.error) cleanupErrors.push(deleted.error);
    }
  }
  const errors = [...(failure ? [failure] : []), ...cleanupErrors];
  if (errors.length) {
    throw new AggregateError(errors, "music deletion test or cleanup failed");
  }
});
