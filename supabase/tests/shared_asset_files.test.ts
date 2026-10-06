// deno-lint-ignore-file no-import-prefix
import { createClient } from "npm:@supabase/supabase-js@2.117.2";

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

Deno.test("shared originals and thumbnails recheck authorization on every download", async (test) => {
  const admin = client(serviceKey!);
  const users: { id: string; token: string; api: ReturnType<typeof client> }[] =
    [];
  const rooms: string[] = [];
  const invites: string[] = [];
  const paths: string[] = [];
  const bytes = Uint8Array.from(
    atob(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jL1sAAAAASUVORK5CYII=",
    ),
    (c) => c.charCodeAt(0),
  );
  let assetId = "";
  function check(result: { error: unknown }) {
    assert(
      !result.error,
      `fixture or mutation failed: ${JSON.stringify(result.error)}`,
    );
  }
  async function download(
    user: typeof users[number] | null,
    path: string,
    allowed: boolean,
  ) {
    const response = await fetch(
      `${url}/storage/v1/object/authenticated/assets/${path}`,
      {
        headers: {
          apikey: anonKey!,
          ...(user ? { Authorization: `Bearer ${user.token}` } : {}),
        },
        cache: "no-store",
      },
    );
    const content = new Uint8Array(await response.arrayBuffer());
    assert(
      response.ok === allowed,
      `download expected ${allowed}, got HTTP ${response.status}`,
    );
    if (!allowed) {
      assert(
        [400, 401, 403, 404].includes(response.status),
        "denial must not be a server failure",
      );
    }
    if (allowed) {
      assert(
        content.length === bytes.length &&
          content.every((value, i) => value === bytes[i]),
        "downloaded bytes differ",
      );
    }
  }
  async function pair(user: typeof users[number] | null, allowed: boolean) {
    for (const path of paths.slice(0, 2)) await download(user, path, allowed);
  }
  async function share(roomId: string) {
    check(
      await users[0].api.from("room_asset_shares").insert({
        asset_id: assetId,
        room_id: roomId,
      }),
    );
  }
  async function unshare(roomId: string) {
    const result = await users[0].api.from("room_asset_shares").delete().eq(
      "asset_id",
      assetId,
    ).eq("room_id", roomId).select();
    check(result);
    assert(result.data?.length === 1, "share was not removed");
  }
  try {
    for (
      const label of ["owner", "player", "spectator", "outsider", "second"]
    ) {
      const password = crypto.randomUUID();
      const email = `asset-share-${label}-${crypto.randomUUID()}@example.com`;
      const created = await admin.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
        user_metadata: { nickname: label },
      });
      assert(!created.error && created.data.user, "test user creation failed");
      const api = client(anonKey!);
      const signed = await api.auth.signInWithPassword({ email, password });
      assert(!signed.error && signed.data.session, "test sign-in failed");
      users.push({
        id: created.data.user.id,
        token: signed.data.session.access_token,
        api,
      });
    }
    for (const name of ["Shared files A", "Shared files B"]) {
      const result = await users[0].api.rpc("create_room", {
        room_name: name,
        room_description: null,
        room_game_system: "Test",
      });
      assert(!result.error && result.data, "test room creation failed");
      rooms.push(result.data.id);
      invites.push(result.data.invite_code);
    }
    for (const [userIndex, roomIndex] of [[1, 0], [2, 0], [4, 1]]) {
      check(
        await users[userIndex].api.rpc("join_room", {
          room_invite_code: invites[roomIndex],
        }),
      );
    }
    check(
      await users[0].api.rpc("set_room_member_role", {
        target_room_id: rooms[0],
        target_user_id: users[2].id,
        target_role: "spectator",
      }),
    );
    assetId = crypto.randomUUID();
    paths.push(
      `${users[0].id}/${assetId}.png`,
      `${users[0].id}/${assetId}-thumb.png`,
    );
    for (const path of paths) {
      check(
        await admin.storage.from("assets").upload(path, bytes, {
          contentType: "image/png",
          cacheControl: "0",
        }),
      );
    }
    check(
      await admin.from("assets").insert({
        id: assetId,
        owner_id: users[0].id,
        category: "token",
        storage_path: paths[0],
        thumbnail_storage_path: paths[1],
      }),
    );

    await test.step("unshared files remain private", async () => {
      await pair(users[0], true);
      for (const user of users.slice(1)) await pair(user, false);
      await pair(null, false);
    });
    await test.step("active players and spectators download but cannot sign or modify", async () => {
      await share(rooms[0]);
      await pair(users[1], true);
      await pair(users[2], true);
      await pair(users[3], false);
      await pair(users[4], false);
      await pair(null, false);
      for (const path of paths) {
        const single = await users[1].api.storage.from("assets")
          .createSignedUrl(path, 3600);
        assert(
          single.error && !single.data,
          "library-only access must not issue signed URLs",
        );
        const batch = await users[1].api.storage.from("assets")
          .createSignedUrls([path], 3600);
        assert(
          batch.error || batch.data?.every((entry) => !entry.signedUrl),
          "batch signing must also be denied",
        );
        const changed = await users[1].api.storage.from("assets").update(
          path,
          bytes,
          { contentType: "image/png" },
        );
        assert(changed.error, "shared file cannot be overwritten");
        await users[1].api.storage.from("assets").remove([path]);
        await download(users[0], path, true);
      }
      const ownSigned = await users[0].api.storage.from("assets")
        .createSignedUrl(paths[0], 60);
      assert(
        !ownSigned.error && ownSigned.data,
        "owner signing remains allowed",
      );
      const response = await fetch(ownSigned.data.signedUrl);
      await response.arrayBuffer();
      assert(response.ok, "owner signed URL remains usable");
    });
    await test.step("revocation rejects the same authenticated URLs and preserves other room access", async () => {
      await share(rooms[1]);
      await pair(users[4], true);
      await unshare(rooms[0]);
      await pair(users[1], false);
      await pair(users[2], false);
      await pair(users[4], true);
      await pair(users[0], true);
      await unshare(rooms[1]);
      await pair(users[4], false);
    });
    await test.step("departure and removal revoke access without refreshing JWT", async () => {
      await share(rooms[0]);
      await pair(users[1], true);
      await pair(users[2], true);
      // There is no leave-room API yet; prepare that state as in the jukebox tests.
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
      await writer.write(
        new TextEncoder().encode(
          `update public.room_members set status = 'left' where room_id = '${
            rooms[0]
          }' and user_id = '${users[1].id}';`,
        ),
      );
      await writer.close();
      assert((await departed.output()).success, "departure fixture failed");
      check(
        await users[0].api.rpc("force_remove_room_member", {
          target_room_id: rooms[0],
          target_user_id: users[2].id,
        }),
      );
      await pair(users[1], false);
      await pair(users[2], false);
      await unshare(rooms[0]);
      for (const user of [users[1], users[2]]) {
        check(
          await user.api.rpc("join_room", { room_invite_code: invites[0] }),
        );
      }
    });
    await test.step("existing map and token authorities survive library revocation", async () => {
      const mapId = crypto.randomUUID();
      const mapPath = `${users[0].id}/${mapId}.png`;
      paths.push(mapPath);
      check(
        await admin.storage.from("assets").upload(mapPath, bytes, {
          contentType: "image/png",
        }),
      );
      check(
        await admin.from("assets").insert({
          id: mapId,
          owner_id: users[0].id,
          category: "map",
          storage_path: mapPath,
        }),
      );
      const map = await admin.from("room_maps").insert({
        room_id: rooms[0],
        asset_id: mapId,
      }).select().single();
      assert(!map.error && map.data, "test map creation failed");
      check(
        await admin.from("room_tokens").insert({
          map_id: map.data.id,
          image_asset_id: assetId,
          name: "Test token",
        }),
      );
      await share(rooms[0]);
      await unshare(rooms[0]);
      for (const path of paths) {
        await download(users[1], path, true);
        const signed = await users[1].api.storage.from("assets")
          .createSignedUrl(path, 60);
        assert(
          !signed.error && signed.data,
          "map/token signing authority is preserved",
        );
        const response = await fetch(signed.data.signedUrl);
        await response.arrayBuffer();
        assert(response.ok, "map/token signed file is readable");
      }
      await pair(users[3], false);
      check(await admin.from("room_maps").delete().eq("id", map.data.id));
      await pair(users[1], false);
      await download(users[1], mapPath, false);
    });
  } finally {
    if (rooms.length) await admin.from("rooms").delete().in("id", rooms);
    if (paths.length) await admin.storage.from("assets").remove(paths);
    for (const user of users) await admin.auth.admin.deleteUser(user.id);
  }
});
