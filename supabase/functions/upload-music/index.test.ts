Deno.test("upload failures preserve status and clean up only attempted resources", async (test) => {
  type Handler = (request: Request) => Promise<Response>;
  let handler: Handler | undefined;
  const originalServe = Deno.serve;
  const originalFetch = globalThis.fetch;
  const env = {
    SUPABASE_URL: "http://127.0.0.1:54321",
    SUPABASE_ANON_KEY: "test-key",
    SUPABASE_SERVICE_ROLE_KEY: "test-key",
  };
  const previousEnv = Object.fromEntries(
    Object.keys(env).map((key) => [key, Deno.env.get(key)]),
  );
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
    if (!handler) throw new Error("upload handler was not registered");
    const upload = handler;
    const cases = [
      {
        name: "Storage size limit",
        status: 413,
        code: "storage_size_limit",
        storageStatus: 413,
        cleanupFails: false,
        invalid: false,
      },
      {
        name: "Storage service failure",
        status: 503,
        code: "storage_upload_failed",
        storageStatus: 503,
        cleanupFails: false,
        invalid: false,
      },
      {
        name: "metadata insertion failure",
        status: 500,
        code: "metadata_save_failed",
        storageStatus: 200,
        cleanupFails: false,
        invalid: false,
      },
      {
        name: "cleanup failure",
        status: 500,
        code: "cleanup_failed",
        storageStatus: 200,
        cleanupFails: true,
        invalid: false,
      },
      {
        name: "invalid audio",
        status: 400,
        code: "invalid_music_file",
        storageStatus: 200,
        cleanupFails: false,
        invalid: true,
      },
    ];
    for (const scenario of cases) {
      await test.step(scenario.name, async () => {
        const requests: string[] = [];
        let uploadedPath: string | undefined;
        globalThis.fetch = async (input, options) => {
          const request = new Request(input, options);
          const path = new URL(request.url).pathname;
          requests.push(`${request.method} ${path}`);
          if (path === "/auth/v1/user") {
            return Response.json({
              id: "00000000-0000-0000-0000-000000000150",
            });
          }
          if (
            request.method === "POST" &&
            path.startsWith("/storage/v1/object/music-assets/")
          ) {
            uploadedPath = path.slice(
              "/storage/v1/object/music-assets/".length,
            );
            return scenario.storageStatus === 200
              ? Response.json({ Key: uploadedPath, Id: "test-id" })
              : Response.json({
                statusCode: String(scenario.storageStatus),
                message: "forced storage failure",
                error: "Storage error",
              }, { status: scenario.storageStatus });
          }
          if (path === "/rest/v1/music_assets") {
            if (request.method === "POST") {
              return Response.json({
                code: "23514",
                message: "forced metadata failure",
              }, { status: 400 });
            }
            if (request.method === "DELETE") {
              return new Response(null, { status: 204 });
            }
          }
          if (
            request.method === "DELETE" &&
            path === "/storage/v1/object/music-assets"
          ) {
            const body = await request.json();
            if (
              body.prefixes.length !== 1 || body.prefixes[0] !== uploadedPath
            ) {
              throw new Error("cleanup targeted a different Storage object");
            }
            return scenario.cleanupFails
              ? Response.json({
                statusCode: "500",
                message: "forced cleanup failure",
              }, { status: 500 })
              : Response.json([]);
          }
          throw new Error(`unexpected request: ${request.method} ${path}`);
        };
        const bytes = scenario.invalid
          ? new Uint8Array([1, 2, 3])
          : await Deno.readFile(
            new URL("./testdata/silence.mp3", import.meta.url),
          );
        const form = new FormData();
        form.set("title", "Test");
        form.set("file", new File([bytes], "test.mp3", { type: "audio/mpeg" }));
        const response = await upload(
          new Request("http://127.0.0.1/upload-music", {
            method: "POST",
            headers: { Authorization: "Bearer test-token" },
            body: form,
          }),
        );
        const body = await response.json();
        if (
          response.status !== scenario.status || body.code !== scenario.code
        ) {
          throw new Error(
            `${scenario.name}: ${response.status} ${JSON.stringify(body)}`,
          );
        }
        const deletedMetadata = requests.includes(
          "DELETE /rest/v1/music_assets",
        );
        const deletedStorage = requests.includes(
          "DELETE /storage/v1/object/music-assets",
        );
        if (
          deletedMetadata !==
            (!scenario.invalid && scenario.storageStatus === 200) ||
          deletedStorage !== !scenario.invalid
        ) {
          throw new Error(`unexpected cleanup: ${requests.join(", ")}`);
        }
        if (scenario.invalid && requests.length !== 1) {
          throw new Error("invalid audio reached Storage or the database");
        }
      });
    }
  } finally {
    globalThis.fetch = originalFetch;
    for (const [key, value] of Object.entries(previousEnv)) {
      if (value === undefined) Deno.env.delete(key);
      else Deno.env.set(key, value);
    }
  }
});
