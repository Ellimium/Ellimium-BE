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
function check(result: { error: unknown }) {
  assert(!result.error, `request failed: ${JSON.stringify(result.error)}`);
}
function client(key: string) {
  return createClient(url!, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

Deno.test("token map changes cannot expose a masters image to another room", async () => {
  const admin = client(serviceKey!);
  const users: { id: string; token: string; api: ReturnType<typeof client> }[] =
    [];
  const rooms: string[] = [];
  const assetIds: string[] = [];
  const tokenId = crypto.randomUUID();
  let path = "";
  const bytes = Uint8Array.from(
    atob(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jL1sAAAAASUVORK5CYII=",
    ),
    (c) => c.charCodeAt(0),
  );
  async function imageAccess(user: typeof users[number], allowed: boolean) {
    const metadata = await user.api.from("assets").select("id").eq(
      "id",
      assetIds[0],
    );
    check(metadata);
    assert(
      metadata.data?.length === Number(allowed),
      "unexpected image metadata access",
    );
    const response = await fetch(
      `${url}/storage/v1/object/authenticated/assets/${path}`,
      {
        headers: { apikey: anonKey!, Authorization: `Bearer ${user.token}` },
        cache: "no-store",
      },
    );
    const content = new Uint8Array(await response.arrayBuffer());
    assert(
      response.ok === allowed,
      `unexpected file access: HTTP ${response.status}`,
    );
    if (allowed) {
      assert(
        content.length === bytes.length &&
          content.every((v, i) => v === bytes[i]),
        "file bytes differ",
      );
    } else {
      assert(
        [400, 401, 403, 404].includes(response.status),
        "denial must not be a server failure",
      );
    }
  }
  try {
    for (const label of ["master", "player", "observer"]) {
      const email =
        `token-boundary-${label}-${crypto.randomUUID()}@example.com`;
      const password = crypto.randomUUID();
      const created = await admin.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
        user_metadata: { nickname: label },
      });
      assert(!created.error && created.data.user, "user creation failed");
      const api = client(anonKey!);
      users.push({ id: created.data.user.id, token: "", api });
      const signed = await api.auth.signInWithPassword({ email, password });
      assert(!signed.error && signed.data.session, "sign-in failed");
      users[users.length - 1].token = signed.data.session.access_token;
    }
    const [master, player, observer] = users;
    for (const name of ["Token boundary A", "Token boundary B"]) {
      const created = await master.api.rpc("create_room", {
        room_name: name,
        room_description: null,
        room_game_system: "Test",
      });
      assert(!created.error && created.data, "room creation failed");
      rooms.push(created.data.id);
      check(
        await player.api.rpc("join_room", {
          room_invite_code: created.data.invite_code,
        }),
      );
      if (rooms.length === 2) {
        check(
          await observer.api.rpc("join_room", {
            room_invite_code: created.data.invite_code,
          }),
        );
      }
      for (const target_feature of ["map_view", "token_move"]) {
        const permission = await player.api.rpc("can_use_room_feature", {
          target_room_id: created.data.id,
          target_feature,
        });
        check(permission);
        assert(
          permission.data === true,
          "player must have both room permissions",
        );
      }
    }
    path = `${master.id}/token-boundary-${crypto.randomUUID()}.png`;
    check(
      await admin.storage.from("assets").upload(path, bytes, {
        contentType: "image/png",
        cacheControl: "0",
      }),
    );
    for (const category of ["token", "map", "map", "map"]) {
      const id = crypto.randomUUID();
      check(
        await admin.from("assets").insert({
          id,
          owner_id: master.id,
          category,
          storage_path: category === "token" ? path : `${master.id}/${id}.png`,
        }),
      );
      assetIds.push(id);
    }
    const maps: string[] = [];
    for (const [index, roomIndex] of [0, 0, 1].entries()) {
      const map = await master.api.from("room_maps").insert({
        room_id: rooms[roomIndex],
        asset_id: assetIds[index + 1],
      }).select("id").single();
      assert(!map.error && map.data, "map creation failed");
      maps.push(map.data.id);
    }
    const original = {
      map_id: maps[0],
      owner_id: player.id,
      image_asset_id: assetIds[0],
    };
    check(
      await master.api.from("room_tokens").insert({
        id: tokenId,
        name: "Boundary token",
        ...original,
      }),
    );
    await imageAccess(player, true);
    await imageAccess(observer, false);
    for (const user of [player, master]) {
      for (const map_id of maps.slice(1)) {
        const changed = await user.api.from("room_tokens").update({ map_id })
          .eq("id", tokenId).select("id");
        assert(
          changed.error?.code === "23514",
          "map change must fail with a constraint error",
        );
        const saved = await master.api.from("room_tokens").select(
          "map_id, owner_id, image_asset_id",
        ).eq("id", tokenId).single();
        check(saved);
        const state = saved.data;
        assert(
          state &&
            Object.entries(original).every(([key, value]) =>
              state[key as keyof typeof original] === value
            ),
          "failed update changed token state",
        );
        const target = await observer.api.from("room_tokens").select("id").eq(
          "id",
          tokenId,
        );
        check(target);
        assert(target.data?.length === 0, "token appeared in the target room");
        await imageAccess(observer, false);
      }
      for (const update of [{ x: 2, y: 3 }, { map_id: maps[0], x: 4, y: 5 }]) {
        const moved = await user.api.from("room_tokens").update(update).eq(
          "id",
          tokenId,
        ).select("x, y").single();
        check(moved);
        assert(
          moved.data?.x === update.x && moved.data?.y === update.y,
          "position update failed",
        );
      }
    }
    for (const owner_id of [null, player.id]) {
      const assigned = await master.api.from("room_tokens").update({ owner_id })
        .eq("id", tokenId).select("owner_id").single();
      check(assigned);
      assert(
        assigned.data?.owner_id === owner_id,
        "master reassignment failed",
      );
    }
    await imageAccess(player, true);
  } finally {
    if (rooms.length) check(await admin.from("rooms").delete().in("id", rooms));
    if (path) check(await admin.storage.from("assets").remove([path]));
    if (assetIds.length) {
      check(await admin.from("assets").delete().in("id", assetIds));
    }
    for (const user of users) check(await admin.auth.admin.deleteUser(user.id));
  }
});
