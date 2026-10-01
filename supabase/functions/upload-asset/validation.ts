export const MAX_MAP_DIMENSION = 2048;

const imageTypes = {
  jpeg: { contentType: "image/jpeg", extension: "jpg" },
  png: { contentType: "image/png", extension: "png" },
  webp: { contentType: "image/webp", extension: "webp" },
  gif: { contentType: "image/gif", extension: "gif" },
} as const;

export type AssetCategory = "map" | "token" | "item" | "other";
export type ImageType = (typeof imageTypes)[keyof typeof imageTypes];

const maxAssetBytes: Record<AssetCategory, number> = {
  map: 10 * 1024 * 1024,
  token: 5 * 1024 * 1024,
  item: 5 * 1024 * 1024,
  other: 5 * 1024 * 1024,
};
const maxThumbnailBytes = 5 * 1024 * 1024;

function startsWith(bytes: Uint8Array, signature: number[], offset = 0) {
  return signature.every((value, index) => bytes[offset + index] === value);
}

export function imageType(bytes: Uint8Array): ImageType | null {
  if (startsWith(bytes, [0xff, 0xd8, 0xff])) return imageTypes.jpeg;
  if (startsWith(bytes, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) {
    return imageTypes.png;
  }
  if (
    startsWith(bytes, [0x47, 0x49, 0x46, 0x38]) &&
    (bytes[4] === 0x37 || bytes[4] === 0x39) && bytes[5] === 0x61
  ) return imageTypes.gif;
  if (
    startsWith(bytes, [0x52, 0x49, 0x46, 0x46]) &&
    startsWith(bytes, [0x57, 0x45, 0x42, 0x50], 8)
  ) return imageTypes.webp;
  return null;
}

function assetCategory(value: string): AssetCategory {
  if (
    value === "map" || value === "token" || value === "item" ||
    value === "other"
  ) return value;
  throw new Error("category must be map, token, item, or other");
}

export function validateAsset(categoryValue: string, bytes: Uint8Array) {
  const category = assetCategory(categoryValue);
  if (bytes.byteLength > maxAssetBytes[category]) {
    throw new Error(
      `${category} images must be ${
        maxAssetBytes[category] / 1024 / 1024
      }MB or smaller`,
    );
  }
  const type = imageType(bytes);
  if (!type) throw new Error("only JPEG, PNG, WebP, and GIF files are allowed");
  return { category, type };
}

export function validateThumbnail(bytes: Uint8Array) {
  if (bytes.byteLength > maxThumbnailBytes) {
    throw new Error("thumbnails must be 5MB or smaller");
  }
  const type = imageType(bytes);
  if (!type) {
    throw new Error("only JPEG, PNG, WebP, and GIF thumbnails are allowed");
  }
  return type;
}
