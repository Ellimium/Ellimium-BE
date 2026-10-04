import { MPEGDecoder } from "npm:mpg123-decoder@1.0.3";
import { OggVorbisDecoder } from "npm:@wasm-audio-decoders/ogg-vorbis@0.1.20";
import { OggOpusDecoder } from "npm:ogg-opus-decoder@1.7.5";
import { decoder as wavDecoder } from "npm:@audio/decode-wav@1.5.0";

const chunkSize = 64 * 1024;
const invalidAudio = () =>
  new Error("audio file is invalid or cannot be decoded");

function text(bytes: Uint8Array, start: number, length: number) {
  if (start < 0 || start + length > bytes.length) return "";
  return String.fromCharCode(...bytes.subarray(start, start + length));
}

function* chunks(bytes: Uint8Array) {
  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    yield bytes.subarray(offset, offset + chunkSize);
  }
}

// Validate declared lengths before a decoder can recover from a truncated file.
function wavChunks(bytes: Uint8Array): Iterable<Uint8Array> {
  if (bytes.length < 12) throw invalidAudio();
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const end = view.getUint32(4, true) + 8;
  if (end !== bytes.length) throw invalidAudio();
  let fmt: Uint8Array | undefined;
  let audio: Uint8Array | undefined;
  for (let offset = 12; offset < end;) {
    if (offset + 8 > end) throw invalidAudio();
    const size = view.getUint32(offset + 4, true);
    const next = offset + 8 + size + (size % 2);
    if (next > end) throw invalidAudio();
    const id = text(bytes, offset, 4);
    if (id === "fmt ") {
      if (fmt || size < 16) throw invalidAudio();
      fmt = bytes.subarray(offset, offset + 8 + size);
    } else if (id === "data") {
      if (audio || !size) throw invalidAudio();
      audio = bytes.subarray(offset + 8, offset + 8 + size);
    }
    offset = next;
  }
  if (!fmt || !audio) throw invalidAudio();
  const format = new DataView(fmt.buffer, fmt.byteOffset, fmt.byteLength);
  const align = format.getUint16(20, true);
  if (
    !format.getUint16(10, true) || !format.getUint32(12, true) || !align ||
    audio.length % align
  ) {
    throw invalidAudio();
  }
  // Feed only fmt/data to the decoder; preserve the original file in Storage.
  // This also handles odd-sized metadata chunks with their RIFF padding.
  const header = new Uint8Array(12 + fmt.length + 8);
  header.set(bytes.subarray(0, 12));
  header.set(fmt, 12);
  header.set(new TextEncoder().encode("data"), 12 + fmt.length);
  const headerView = new DataView(header.buffer);
  headerView.setUint32(4, header.length + audio.length - 8, true);
  headerView.setUint32(header.length - 4, audio.length, true);
  return (function* () {
    yield header;
    yield* chunks(audio);
  })();
}

function mp3Frames(bytes: Uint8Array) {
  let start = 0;
  while (text(bytes, start, 3) === "ID3") {
    if (start + 10 > bytes.length) throw invalidAudio();
    const sizeBytes = bytes.subarray(start + 6, start + 10);
    if (sizeBytes.some((byte) => byte > 127)) throw invalidAudio();
    const size = sizeBytes.reduce((total, byte) => total * 128 + byte, 0);
    start += 10 + size +
      (bytes[start + 3] === 4 && (bytes[start + 5] & 16) ? 10 : 0);
    if (start > bytes.length) throw invalidAudio();
  }
  let end = bytes.length;
  if (text(bytes, end - 128, 3) === "TAG") end -= 128;
  if (end >= 32 && text(bytes, end - 32, 8) === "APETAGEX") {
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const size = view.getUint32(end - 20, true);
    if (size < 32 || size > end - start) throw invalidAudio();
    end -= size;
    if (end >= 32 && text(bytes, end - 32, 8) === "APETAGEX") end -= 32;
  }
  const bitrate1 = [
    0,
    32,
    40,
    48,
    56,
    64,
    80,
    96,
    112,
    128,
    160,
    192,
    224,
    256,
    320,
  ];
  const bitrate2 = [
    0,
    8,
    16,
    24,
    32,
    40,
    48,
    56,
    64,
    80,
    96,
    112,
    128,
    144,
    160,
  ];
  let offset = start;
  let frames = 0;
  while (offset < end) {
    if (
      bytes[offset] === 0 &&
      bytes.subarray(offset, end).every((byte) => byte === 0)
    ) {
      end = offset;
      break;
    }
    if (offset + 4 > end) throw invalidAudio();
    const [first, second, third] = bytes.subarray(offset, offset + 3);
    const version = (second >> 3) & 3;
    const layer = (second >> 1) & 3;
    const rateIndex = (third >> 2) & 3;
    const bitrate = (version === 3 ? bitrate1 : bitrate2)[third >> 4];
    if (
      first !== 255 || (second & 224) !== 224 || version === 1 || layer !== 1 ||
      rateIndex === 3 || !bitrate
    ) {
      throw invalidAudio();
    }
    const rate = [44100, 48000, 32000][rateIndex] /
      (version === 3 ? 1 : version === 2 ? 2 : 4);
    const size = Math.floor((version === 3 ? 144000 : 72000) * bitrate / rate) +
      ((third >> 1) & 1);
    if (offset + size > end) throw invalidAudio();
    offset += size;
    frames++;
  }
  if (!frames) throw invalidAudio();
  return bytes.subarray(start, end);
}

const oggCrcTable = Uint32Array.from({ length: 256 }, (_, index) => {
  let crc = index << 24;
  for (let bit = 0; bit < 8; bit++) {
    crc = (crc << 1) ^ (crc & 0x80000000 ? 0x04c11db7 : 0);
  }
  return crc >>> 0;
});

function oggCodec(bytes: Uint8Array) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let codec: "vorbis" | "opus" | undefined;
  let lastFlags = 0;
  for (let offset = 0; offset < bytes.length;) {
    if (
      offset + 27 > bytes.length || text(bytes, offset, 4) !== "OggS" ||
      bytes[offset + 4] !== 0
    ) throw invalidAudio();
    const body = offset + 27 + bytes[offset + 26];
    if (body > bytes.length) throw invalidAudio();
    const size = bytes.subarray(offset + 27, body).reduce(
      (sum, value) => sum + value,
      0,
    );
    const end = body + size;
    if (end > bytes.length) throw invalidAudio();
    let crc = 0;
    for (let index = offset; index < end; index++) {
      const byte = index >= offset + 22 && index < offset + 26
        ? 0
        : bytes[index];
      crc = (crc << 8) ^ oggCrcTable[((crc >>> 24) ^ byte) & 255];
    }
    if ((crc >>> 0) !== view.getUint32(offset + 22, true)) throw invalidAudio();
    if (offset === 0) {
      if (!(bytes[offset + 5] & 2)) throw invalidAudio();
      if (bytes[body] === 1 && text(bytes, body + 1, 6) === "vorbis") {
        codec = "vorbis";
      } else if (text(bytes, body, 8) === "OpusHead") codec = "opus";
      else throw invalidAudio();
    }
    lastFlags = bytes[offset + 5];
    offset = end;
  }
  if (!codec || !(lastFlags & 4)) throw invalidAudio();
  return codec;
}

interface DecodedAudio {
  channelData: Float32Array[];
  sampleRate: number;
  errors?: unknown[];
}

interface Decoder {
  ready?: Promise<void>;
  decode(bytes: Uint8Array): DecodedAudio | Promise<DecodedAudio>;
  flush?(): DecodedAudio | Promise<DecodedAudio>;
  free(): void;
}

export async function decodedDurationMs(
  bytes: Uint8Array,
  extension: "mp3" | "ogg" | "wav",
) {
  let decoder: Decoder;
  let input: Iterable<Uint8Array>;
  if (extension === "wav") {
    input = wavChunks(bytes);
    decoder = wavDecoder();
  } else if (extension === "mp3") {
    input = chunks(mp3Frames(bytes));
    decoder = new MPEGDecoder();
  } else {
    const codec = oggCodec(bytes);
    input = chunks(bytes);
    decoder = codec === "vorbis"
      ? new OggVorbisDecoder()
      : new OggOpusDecoder();
  }
  let duration = 0;
  function count(audio: DecodedAudio) {
    if (audio.errors?.length) throw invalidAudio();
    if (!audio.channelData.length || !audio.channelData[0].length) return;
    if (
      !Number.isFinite(audio.sampleRate) || audio.sampleRate <= 0 ||
      audio.channelData.some((channel) =>
        channel.some((sample) => !Number.isFinite(sample))
      )
    ) throw invalidAudio();
    duration += audio.channelData[0].length / audio.sampleRate;
  }
  try {
    await decoder.ready;
    for (const chunk of input) count(await decoder.decode(chunk));
    if (decoder.flush) count(await decoder.flush());
  } finally {
    decoder.free();
  }
  const durationMs = Math.round(duration * 1000);
  if (!Number.isSafeInteger(durationMs) || durationMs <= 0) {
    throw invalidAudio();
  }
  return durationMs;
}
