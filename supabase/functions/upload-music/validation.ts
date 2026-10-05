import { decodedDurationMs } from "./decoding.ts";

export const musicTypes = {
  mp3: { contentType: "audio/mpeg", extension: "mp3", aliases: ["audio/mpeg"] },
  ogg: { contentType: "audio/ogg", extension: "ogg", aliases: ["audio/ogg"] },
  wav: {
    contentType: "audio/wav",
    extension: "wav",
    aliases: ["audio/wav", "audio/x-wav"],
  },
} as const;

export type MusicType = (typeof musicTypes)[keyof typeof musicTypes];

function startsWith(bytes: Uint8Array, signature: number[], offset = 0) {
  return signature.every((value, index) => bytes[offset + index] === value);
}

function isMp3(bytes: Uint8Array) {
  if (startsWith(bytes, [0x49, 0x44, 0x33])) return true;
  return bytes[0] === 0xff && (bytes[1] & 0xe0) === 0xe0 &&
    ((bytes[1] >> 3) & 3) !== 1 && ((bytes[1] >> 1) & 3) === 1;
}

function sniffMusicType(bytes: Uint8Array): MusicType | null {
  if (startsWith(bytes, [0x4f, 0x67, 0x67, 0x53])) return musicTypes.ogg;
  if (
    startsWith(bytes, [0x52, 0x49, 0x46, 0x46]) &&
    startsWith(bytes, [0x57, 0x41, 0x56, 0x45], 8)
  ) return musicTypes.wav;
  if (isMp3(bytes)) return musicTypes.mp3;
  return null;
}

export async function validateMusicFile(
  fileName: string,
  declaredMimeType: string,
  bytes: Uint8Array,
) {
  if (!bytes.byteLength) throw new Error("music file is empty");

  const extension = fileName.split(".").at(-1)?.toLowerCase();
  const type = sniffMusicType(bytes);
  if (!type) throw new Error("only valid MP3, OGG, and WAV files are allowed");
  if (extension !== type.extension) {
    throw new Error("file extension does not match the audio format");
  }
  if (!type.aliases.some((alias) => alias === declaredMimeType.toLowerCase())) {
    throw new Error("MIME type does not match the audio format");
  }

  let durationMs: number;
  try {
    durationMs = await decodedDurationMs(bytes, type.extension);
  } catch {
    throw new Error("audio file is invalid or cannot be decoded");
  }

  return { type, durationMs };
}
