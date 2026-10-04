import { validateMusicFile } from "./validation.ts";

function wavFile() {
  const dataSize = 8000;
  const bytes = new Uint8Array(44 + dataSize);
  const view = new DataView(bytes.buffer);
  const write = (offset: number, value: string) => {
    for (let index = 0; index < value.length; index++) {
      bytes[offset + index] = value.charCodeAt(index);
    }
  };

  write(0, "RIFF");
  view.setUint32(4, 36 + dataSize, true);
  write(8, "WAVE");
  write(12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, 8000, true);
  view.setUint32(28, 8000, true);
  view.setUint16(32, 1, true);
  view.setUint16(34, 8, true);
  write(36, "data");
  view.setUint32(40, dataSize, true);
  bytes.fill(128, 44);
  return bytes;
}

Deno.test("extracts a positive WAV duration from file bytes", async () => {
  const result = await validateMusicFile("ambient.wav", "audio/wav", wavFile());
  if (result.type.contentType !== "audio/wav" || result.durationMs !== 1000) {
    throw new Error(`unexpected WAV metadata: ${JSON.stringify(result)}`);
  }
});

Deno.test("accepts the WAV MIME alias but stores the canonical type", async () => {
  const result = await validateMusicFile(
    "ambient.WAV",
    "audio/x-wav",
    wavFile(),
  );
  if (result.type.contentType !== "audio/wav") {
    throw new Error("WAV alias was not normalized");
  }
});

Deno.test("rejects extension and declared MIME mismatches", async () => {
  for (
    const [name, mime] of [["ambient.mp3", "audio/wav"], [
      "ambient.ogg",
      "audio/wav",
    ]]
  ) {
    let rejected = false;
    try {
      await validateMusicFile(name, mime, wavFile());
    } catch {
      rejected = true;
    }
    if (!rejected) throw new Error(`${name} with ${mime} should be rejected`);
  }
});

Deno.test("rejects empty, unknown, and malformed audio", async () => {
  for (
    const [name, mime, bytes] of [
      ["empty.wav", "audio/wav", new Uint8Array()],
      ["unknown.wav", "audio/wav", new Uint8Array([1, 2, 3])],
      [
        "truncated.wav",
        "audio/wav",
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
          0x41,
          0x56,
          0x45,
        ]),
      ],
    ] as const
  ) {
    let rejected = false;
    try {
      await validateMusicFile(name, mime, bytes);
    } catch {
      rejected = true;
    }
    if (!rejected) throw new Error(`${name} should be rejected`);
  }
});

Deno.test("rejects MP3 and OGG signatures without readable audio", async () => {
  for (
    const [name, mime, bytes] of [
      ["broken.mp3", "audio/mpeg", new Uint8Array([0xff, 0xfb, 0x90, 0x64])],
      ["broken.ogg", "audio/ogg", new TextEncoder().encode("OggS")],
    ] as const
  ) {
    let rejected = false;
    try {
      await validateMusicFile(name, mime, bytes);
    } catch {
      rejected = true;
    }
    if (!rejected) throw new Error(`${name} should be rejected`);
  }
});
