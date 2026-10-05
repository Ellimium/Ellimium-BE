Deno.test("deletion failures preserve retry path and never bypass ownership", async (test) => {
  type Handler = (request: Request) => Promise<Response>;
  let handler: Handler | undefined;
  const originalServe = Deno.serve;
  const originalFetch = globalThis.fetch;
  const env = {
    SUPABASE_URL: "http://127.0.0.1:54321",
    SUPABASE_ANON_KEY: "test-anon",
    SUPABASE_SERVICE_ROLE_KEY: "test-admin",
  };
  const previous = Object.fromEntries(
    Object.keys(env).map((key) => [key, Deno.env.get(key)]),
  );
  const owner = "00000000-0000-0000-0000-000000000300";
  const id = "00000000-0000-0000-0000-000000000320";
  const path = `${owner}/track.mp3`;
  try {
    for (const [key, value] of Object.entries(env)) Deno.env.set(key, value);
    Object.defineProperty(Deno, "serve", {
      configurable: true,
      value: (callback: Handler) => {
        handler = callback;
      },
    });
    try {
      await import("./index.ts");
    } finally {
      Object.defineProperty(Deno, "serve", {
        configurable: true,
        value: originalServe,
      });
    }
    if (!handler) throw new Error("deletion handler not registered");
    const remove = handler;
    for (
      const scenario of [
        "Storage failure",
        "metadata failure",
        "non-owner",
        "already deleted",
        "success",
      ]
    ) {
      await test.step(scenario, async () => {
        let attempt = 0;
        const calls: string[] = [];
        globalThis.fetch = async (input, init) => {
          const request = new Request(input, init);
          const route = new URL(request.url).pathname;
          calls.push(route);
          if (route === "/auth/v1/user") return Response.json({ id: owner });
          if (route === "/rest/v1/rpc/prepare_music_asset_deletion") {
            const body = await request.json();
            if (
              body.target_music_asset_id !== id ||
              request.headers.get("Authorization") !== "Bearer test-user-token"
            ) {
              throw new Error(
                "preparation must use caller JWT and requested ID",
              );
            }
            if (scenario === "non-owner") {
              return Response.json({
                code: "42501",
                message: "music owner required",
              }, { status: 403 });
            }
            return Response.json(scenario === "already deleted" ? null : path);
          }
          if (route === "/storage/v1/object/music-assets") {
            const body = await request.json();
            if (
              request.method !== "DELETE" ||
              JSON.stringify(body.prefixes) !== JSON.stringify([path])
            ) throw new Error("wrong cleanup target");
            if (scenario === "Storage failure" && attempt === 0) {
              return Response.json({
                statusCode: "503",
                message: "forced Storage failure",
              }, { status: 503 });
            }
            return Response.json([]);
          }
          if (route === "/rest/v1/rpc/finish_music_asset_deletion") {
            const body = await request.json();
            if (
              body.target_music_asset_id !== id ||
              body.target_owner_id !== owner ||
              request.headers.get("Authorization") !== "Bearer test-admin"
            ) {
              throw new Error(
                "finalization must use authenticated owner and server credentials",
              );
            }
            if (scenario === "metadata failure" && attempt === 0) {
              return Response.json({
                code: "XX000",
                message: "forced metadata failure",
              }, { status: 500 });
            }
            return Response.json(true);
          }
          throw new Error("unexpected route");
        };
        async function requestDelete() {
          const response = await remove(
            new Request("http://127.0.0.1/delete-music", {
              method: "POST",
              headers: {
                Authorization: "Bearer test-user-token",
                "Content-Type": "application/json",
              },
              body: JSON.stringify({
                musicAssetId: id,
                ownerId: "fake-owner",
                storagePath: "fake/path.mp3",
              }),
            }),
          );
          return { status: response.status, data: await response.json() };
        }
        const first = await requestDelete();
        if (scenario === "Storage failure") {
          if (
            first.status !== 502 ||
            first.data.code !== "storage_delete_failed" ||
            calls.includes("/rest/v1/rpc/finish_music_asset_deletion")
          ) throw new Error("Storage failure must not finalize metadata");
        } else if (scenario === "metadata failure") {
          if (
            first.status !== 500 ||
            first.data.code !== "metadata_delete_failed" ||
            calls.at(-1) !== "/rest/v1/rpc/finish_music_asset_deletion"
          ) throw new Error("metadata failure must report retryable cleanup");
        } else if (scenario === "non-owner" || scenario === "already deleted") {
          if (
            first.status !== (scenario === "non-owner" ? 403 : 200) ||
            calls.length !== 2
          ) throw new Error("denied/missing music must not reach Storage");
        } else if (
          first.status !== 200 || first.data.deleted !== true ||
          calls.length !== 4
        ) throw new Error("unexpected deletion flow");
        if (scenario === "Storage failure" || scenario === "metadata failure") {
          attempt++;
          calls.length = 0;
          const retry = await requestDelete();
          if (
            retry.status !== 200 || retry.data.deleted !== true ||
            calls.length !== 4
          ) throw new Error("cleanup retry did not finish");
        }
      });
    }
  } finally {
    globalThis.fetch = originalFetch;
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) Deno.env.delete(key);
      else Deno.env.set(key, value);
    }
  }
});
