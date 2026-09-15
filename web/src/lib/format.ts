export function clock(seconds?: number) {
  if (seconds == null || !Number.isFinite(seconds)) return "–:––";
  const s = Math.max(0, Math.floor(seconds));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

export function fixed(value: number, digits: number, unit = "") {
  const text = Number.isFinite(value) ? value.toFixed(digits) : "–";
  return unit ? `${text} ${unit}` : text;
}

export function gainDb(gain: number) {
  const db = 20 * Math.log10(Math.max(gain, 1e-4));
  return `${db > -0.05 ? "0.0" : db.toFixed(1)} dB`;
}

export function clamp(value: number, min: number, max: number) {
  return Math.min(max, Math.max(min, value));
}

/** dBFS mapped onto 0…1 over a 60 dB window. */
export function levelFraction(db: number) {
  return clamp((db + 60) / 60, 0, 1);
}
