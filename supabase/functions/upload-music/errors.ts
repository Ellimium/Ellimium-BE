export class MusicUploadError extends Error {
  constructor(message: string, public status: number, public code: string) {
    super(message);
  }
}

export function storageUploadError(
  error: { status?: number; statusCode?: string },
) {
  const status = Number(error.statusCode ?? error.status);
  if (status === 413) {
    return new MusicUploadError(
      "music file exceeds the Storage size limit",
      413,
      "storage_size_limit",
    );
  }
  return new MusicUploadError(
    "Storage rejected the music upload",
    status >= 400 && status <= 599 ? status : 502,
    "storage_upload_failed",
  );
}
