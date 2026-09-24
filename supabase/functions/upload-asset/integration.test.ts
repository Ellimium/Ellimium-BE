import {
  ImageMagick,
  initializeImageMagick,
  MagickColor,
  MagickFormat,
} from "npm:@imagemagick/magick-wasm@^0";
import { createClient } from "npm:@supabase/supabase-js@2";

const apiUrl = Deno.env.get("API_URL");
const anonKey = Deno.env.get("ANON_KEY");
if (!apiUrl || !anonKey) throw new Error("API_URL and ANON_KEY are required");

const wasmBytes = await Deno.readFile(
  new URL(import.meta.resolve("npm:@imagemagick/magick-wasm@^0/magick.wasm")),
);
await initializeImageMagick(wasmBytes);

function assert(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}

function image(width: number, height: number, format: MagickFormat) {
  return ImageMagick.read(
    new MagickColor("#305080"),
    width,
    height,
    (value) => value.write(format, (data) => Uint8Array.from(data)),
  );
}

function bytesPart(bytes: Uint8Array) {
  return Uint8Array.from(bytes).buffer;
}

async function user(label: string) {
  const client = createClient(apiUrl!, anonKey!, {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
      detectSessionInUrl: false,
    },
  });
  const { data, error } = await client.auth.signUp({
    email: `asset-${crypto.randomUUID()}@example.com`,
    password: "integration-test-password",
    options: { data: { nickname: `${label}사용자` } },
  });
  assert(
    !error && data.session,
    `failed to create ${label} user: ${error?.message}`,
  );
  return client;
}

async function upload(
  client: Awaited<ReturnType<typeof user>>,
  category: string,
  bytes: Uint8Array,
  contentType: string,
  thumbnail?: Uint8Array,
) {
  const body = new FormData();
  body.set("category", category);
  body.set(
    "file",
    new File([bytesPart(bytes)], `asset.${contentType.split("/")[1]}`, {
      type: contentType,
    }),
  );
  if (thumbnail) {
    body.set(
      "thumbnail",
      new File([bytesPart(thumbnail)], "thumbnail.png", { type: "image/png" }),
    );
  }
  const { data, error } = await client.functions.invoke("upload-asset", {
    body,
  });
  if (error) {
    const detail = "context" in error && error.context instanceof Response
      ? await error.context.text()
      : error.message;
    throw new Error(`upload failed: ${detail}`);
  }
  assert(data?.asset, "upload response did not include an asset");
  return data.asset;
}

Deno.test("uploads, resizes, queries, and protects image assets", async () => {
  const owner = await user("소유자");
  const outsider = await user("외부인");
  const formats = [
    [MagickFormat.Jpeg, "image/jpeg"],
    [MagickFormat.Png, "image/png"],
    [MagickFormat.WebP, "image/webp"],
    [MagickFormat.Gif, "image/gif"],
  ] as const;

  for (const [format, contentType] of formats) {
    const asset = await upload(
      owner,
      "token",
      image(16, 8, format),
      contentType,
      format === MagickFormat.Jpeg ? image(8, 8, MagickFormat.Png) : undefined,
    );
    if (format === MagickFormat.Jpeg) {
      assert(
        asset.thumbnail_storage_path,
        "thumbnail reference must be stored",
      );
    }
  }

  const map = await upload(
    owner,
    "map",
    image(3000, 1200, MagickFormat.Png),
    "image/png",
  );
  assert(
    map.thumbnail_storage_path === null,
    "omitted thumbnail reference must be null",
  );

  const { data: storedMap, error: downloadError } = await owner.storage.from(
    "assets",
  ).download(map.storage_path);
  assert(
    storedMap && !downloadError,
    `owner could not download map: ${downloadError?.message}`,
  );
  const dimensions = ImageMagick.read(
    new Uint8Array(await storedMap.arrayBuffer()),
    (value) => [value.width, value.height],
  );
  assert(
    dimensions[0] === 2048 && dimensions[1] === 819,
    `unexpected resized dimensions: ${dimensions.join("x")}`,
  );

  const { data: metadata, error: queryError } = await owner.from("assets")
    .select("id, thumbnail_storage_path").eq("id", map.id).single();
  assert(
    !queryError && metadata?.thumbnail_storage_path === null,
    `owner could not query metadata: ${queryError?.message}`,
  );

  const { data: hiddenMetadata, error: hiddenQueryError } = await outsider.from(
    "assets",
  ).select("id").eq("id", map.id);
  assert(
    !hiddenQueryError && hiddenMetadata.length === 0,
    "outsider could read asset metadata",
  );
  const { data: hiddenFile } = await outsider.storage.from("assets").download(
    map.storage_path,
  );
  assert(hiddenFile === null, "outsider could read asset file");
});
