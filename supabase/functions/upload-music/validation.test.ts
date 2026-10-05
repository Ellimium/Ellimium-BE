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

Deno.test("rejects forged WAV format fields before allocating decoded samples", async () => {
  const original = globalThis.Float32Array;
  let allocated = 0;
  globalThis.Float32Array = new Proxy(original, {
    construct(target, args, newTarget) {
      if (typeof args[0] === "number") allocated += args[0] * 4;
      return Reflect.construct(target, args, newTarget);
    },
  });
  try {
    for (const [offset, value] of [[22, 128], [32, 2], [34, 4], [28, 1]]) {
      const bytes = wavFile();
      new DataView(bytes.buffer).setUint16(offset, value, true);
      let rejected = false;
      try {
        await validateMusicFile("forged.wav", "audio/wav", bytes);
      } catch {
        rejected = true;
      }
      if (!rejected) throw new Error(`forged field ${offset} was accepted`);
    }
    if (allocated) {
      throw new Error(`invalid WAV allocated ${allocated} decoded bytes`);
    }
  } finally {
    globalThis.Float32Array = original;
  }
});

function formattedWav(
  codec: number,
  bits: number,
  channels: number,
  align: number,
  dataSize: number,
  extra?: Uint8Array,
) {
  const fmtSize = extra ? 18 + extra.length : 16;
  const dataOffset = 12 + 8 + fmtSize;
  const bytes = new Uint8Array(dataOffset + 8 + dataSize + dataSize % 2);
  const view = new DataView(bytes.buffer);
  for (
    const [offset, label] of [[0, "RIFF"], [8, "WAVE"], [12, "fmt "], [
      dataOffset,
      "data",
    ]] as const
  ) {
    bytes.set(new TextEncoder().encode(label), offset);
  }
  view.setUint32(4, bytes.length - 8, true);
  view.setUint32(16, fmtSize, true);
  view.setUint16(20, codec, true);
  view.setUint16(22, channels, true);
  view.setUint32(24, 8000, true);
  const samples = (codec === 0x11 || codec === 2) && extra
    ? new DataView(extra.buffer, extra.byteOffset, extra.byteLength).getUint16(
      0,
      true,
    )
    : 1;
  view.setUint32(28, Math.floor(8000 * align / samples), true);
  view.setUint16(32, align, true);
  view.setUint16(34, bits, true);
  if (extra) {
    view.setUint16(36, extra.length, true);
    bytes.set(extra, 38);
  }
  view.setUint32(dataOffset + 4, dataSize, true);
  return bytes;
}

Deno.test("keeps valid stereo PCM, float, companded and extensible WAV support", async () => {
  const extensible = new Uint8Array(22);
  new DataView(extensible.buffer).setUint16(0, 16, true);
  extensible.set([
    1,
    0,
    0,
    0,
    0,
    0,
    0x10,
    0,
    0x80,
    0,
    0,
    0xaa,
    0,
    0x38,
    0x9b,
    0x71,
  ], 6);
  for (
    const [codec, bits, channels, align, extra, duration] of [
      [1, 16, 2, 4, undefined, 250],
      [3, 32, 1, 4, undefined, 250],
      [3, 64, 1, 8, undefined, 125],
      [6, 8, 1, 1, undefined, 1000],
      [7, 8, 1, 1, undefined, 1000],
      [0xfffe, 16, 2, 4, extensible, 250],
    ] as const
  ) {
    const result = await validateMusicFile(
      "valid.wav",
      "audio/wav",
      formattedWav(codec, bits, channels, align, 8000, extra),
    );
    if (result.durationMs !== duration) {
      throw new Error(`codec ${codec}: wrong duration`);
    }
  }
});

Deno.test("validates ADPCM sample counts and extensions before decoding", async () => {
  const ima = new Uint8Array(2);
  new DataView(ima.buffer).setUint16(0, 505, true);
  const ms = new Uint8Array(32);
  const msView = new DataView(ms.buffer);
  msView.setUint16(0, 500, true);
  msView.setUint16(2, 7, true);
  for (
    const [i, pair] of [[256, 0], [512, -256], [0, 0], [192, 64], [240, 0], [
      460,
      -208,
    ], [392, -232]].entries()
  ) {
    msView.setInt16(4 + i * 4, pair[0], true);
    msView.setInt16(6 + i * 4, pair[1], true);
  }
  for (const [codec, extra] of [[0x11, ima], [2, ms]] as const) {
    const valid = formattedWav(codec, 4, 1, 256, 256, extra);
    const result = await validateMusicFile("valid.wav", "audio/wav", valid);
    if (result.durationMs !== 63) {
      throw new Error(`codec ${codec}: wrong duration`);
    }
    const forged = valid.slice();
    new DataView(forged.buffer).setUint16(38, 65535, true);
    const original = globalThis.Float32Array;
    let allocated = 0;
    globalThis.Float32Array = new Proxy(original, {
      construct(target, args, newTarget) {
        if (typeof args[0] === "number") allocated += args[0] * 4;
        return Reflect.construct(target, args, newTarget);
      },
    });
    try {
      let rejected = false;
      try {
        await validateMusicFile("forged.wav", "audio/wav", forged);
      } catch {
        rejected = true;
      }
      if (!rejected || allocated) {
        throw new Error(`forged ADPCM allocated ${allocated} bytes`);
      }
    } finally {
      globalThis.Float32Array = original;
    }
  }
});
