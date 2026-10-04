import { parseBuffer } from "npm:music-metadata@11.16.1";

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
  const scanLength = Math.min(bytes.length - 1, 64 * 1024);
  for (let index = 0; index < scanLength; index++) {
    const first = bytes[index];
    const second = bytes[index + 1];
    if (
      first === 0xff && second !== undefined && (second & 0xe0) === 0xe0 &&
      ((second >> 3) & 0x03) !== 0x01 && ((second >> 1) & 0x03) !== 0
    ) return true;
  }
  return false;
}

function sniffMusicType(bytes: Uint8Array): MusicType | null {
  if (isMp3(bytes)) return musicTypes.mp3;
  if (startsWith(bytes, [0x4f, 0x67, 0x67, 0x53])) return musicTypes.ogg;
  if (
    startsWith(bytes, [0x52, 0x49, 0x46, 0x46]) &&
    startsWith(bytes, [0x57, 0x41, 0x56, 0x45], 8)
  ) return musicTypes.wav;
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

  let metadata;
  try {
    metadata = await parseBuffer(
      bytes,
      { mimeType: type.contentType, path: fileName, size: bytes.byteLength },
      { duration: true, skipCovers: true },
    );
  } catch {
    throw new Error("audio file is invalid or cannot be decoded");
  }

  if (
    !Number.isFinite(metadata.format.duration) || metadata.format.duration! <= 0
  ) {
    throw new Error("audio duration could not be determined");
  }

  const durationMs = Math.round(metadata.format.duration! * 1000);
  if (!Number.isSafeInteger(durationMs) || durationMs <= 0) {
    throw new Error("audio duration could not be determined");
  }

  return { type, durationMs };
}
