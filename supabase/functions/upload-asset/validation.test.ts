import { imageType, validateAsset, validateThumbnail } from "./validation.ts";

function assert(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}

Deno.test("accepts each supported image signature", () => {
  assert(
    imageType(new Uint8Array([0xff, 0xd8, 0xff]))?.contentType === "image/jpeg",
    "JPEG must be accepted",
  );
  assert(
    imageType(new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))
      ?.contentType === "image/png",
    "PNG must be accepted",
  );
  assert(
    imageType(
      new Uint8Array([
        0x52,
        0x49,
        0x46,
        0x46,
        0,
        0,
        0,
        0,
        0x57,
        0x45,
        0x42,
        0x50,
      ]),
    )?.contentType === "image/webp",
    "WebP must be accepted",
  );
  assert(
    imageType(new Uint8Array([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]))
      ?.contentType === "image/gif",
    "GIF must be accepted",
  );
});

Deno.test("rejects unknown formats and oversized uploads", () => {
  let invalidFormat = false;
  let oversizedToken = false;
  let oversizedMap = false;
  let oversizedThumbnail = false;
  try {
    validateThumbnail(new Uint8Array([0]));
  } catch {
    invalidFormat = true;
  }
  try {
    validateAsset("token", new Uint8Array(5 * 1024 * 1024 + 1));
  } catch {
    oversizedToken = true;
  }
  try {
    validateAsset("map", new Uint8Array(10 * 1024 * 1024 + 1));
  } catch {
    oversizedMap = true;
  }
  try {
    validateThumbnail(new Uint8Array(5 * 1024 * 1024 + 1));
  } catch {
    oversizedThumbnail = true;
  }
  assert(invalidFormat, "unknown thumbnails must be rejected");
  assert(oversizedToken, "tokens over 5MB must be rejected");
  assert(oversizedMap, "maps over 10MB must be rejected");
  assert(oversizedThumbnail, "thumbnails over 5MB must be rejected");
});
