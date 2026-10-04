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

Deno.test("WAV PCM containing MP3 sync bytes keeps its WAV type", async () => {
  const bytes = wavFile();
  bytes.set([0xff, 0xfb, 0x90, 0x64], 100);
  const result = await validateMusicFile("ambient.wav", "audio/wav", bytes);
  if (result.type.extension !== "wav" || result.durationMs !== 1000) {
    throw new Error("PCM data was mistaken for an MP3 signature");
  }
});

async function fixture(name: string) {
  return await Deno.readFile(new URL(`./testdata/${name}`, import.meta.url));
}

Deno.test("decodes MP3 Layer III and OGG Vorbis/Opus audio", async () => {
  for (
    const [name, mime, duration] of [
      ["silence.mp3", "audio/mpeg", 261],
      ["silence-opus.ogg", "audio/ogg", 20],
      ["tone-vorbis.ogg", "audio/ogg", 100],
    ] as const
  ) {
    const result = await validateMusicFile(name, mime, await fixture(name));
    if (result.durationMs !== duration) {
      throw new Error(
        `${name}: expected ${duration}ms, got ${result.durationMs}`,
      );
    }
  }
});

Deno.test("rejects unsupported WAV codecs and truncated WAV payloads", async () => {
  const unsupported = wavFile();
  new DataView(unsupported.buffer).setUint16(20, 99, true);
  const truncated = wavFile().subarray(0, 144);
  for (const bytes of [unsupported, truncated]) {
    let rejected = false;
    try {
      await validateMusicFile("bad.wav", "audio/wav", bytes);
    } catch {
      rejected = true;
    }
    if (!rejected) throw new Error("undecodable WAV was accepted");
  }
});

Deno.test("rejects MPEG Layer II even behind an ID3 tag", async () => {
  const bytes = await fixture("silence.mp3");
  for (let offset = 0; offset < bytes.length; offset += 417) {
    bytes[offset + 1] = 0xfd;
  }
  const tagged = new Uint8Array(10 + bytes.length);
  tagged.set([0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 0]);
  tagged.set(bytes, 10);
  for (const input of [bytes, tagged]) {
    let rejected = false;
    try {
      await validateMusicFile("layer2.mp3", "audio/mpeg", input);
    } catch {
      rejected = true;
    }
    if (!rejected) throw new Error("Layer II was accepted as MP3");
  }
});

Deno.test("rejects truncated MP3 and corrupt or unfinished OGG pages", async () => {
  const mp3 = await fixture("silence.mp3");
  const ogg = await fixture("silence-opus.ogg");
  const corrupt = ogg.slice();
  corrupt[corrupt.length - 1] ^= 1;
  for (
    const [name, mime, bytes] of [
      ["bad.mp3", "audio/mpeg", mp3.subarray(0, mp3.length - 1)],
      ["bad.ogg", "audio/ogg", corrupt],
      ["bad.ogg", "audio/ogg", ogg.subarray(0, 91)],
    ] as const
  ) {
    let rejected = false;
    try {
      await validateMusicFile(name, mime, bytes);
    } catch {
      rejected = true;
    }
    if (!rejected) throw new Error(`${name} corruption was accepted`);
  }
});
