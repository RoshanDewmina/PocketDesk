export function markerSourceRect(videoWidth, videoHeight) {
  if (!Number.isFinite(videoWidth) || !Number.isFinite(videoHeight) || videoWidth < 88 || videoHeight < 48) return null;
  return { sx: videoWidth - 88, sy: videoHeight - 48, sw: 88, sh: 48 };
}
