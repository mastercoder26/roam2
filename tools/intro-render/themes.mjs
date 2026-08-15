// Palette values transcribed from ios/Roam/Models/Theme.swift (ThemeCatalog).
// Keep in sync by hand — there are only six themes and they change rarely.

const rgb = (r, g, b, a = 1) => ({ r, g, b, a });
const white = (a) => rgb(1, 1, 1, a);
const black = (a) => rgb(0, 0, 0, a);

const THEMES = {
  dark: {
    accent: rgb(0.02, 0.42, 0.92),
    safety: rgb(1.0, 0.58, 0.0),
    canvas: rgb(18 / 255, 18 / 255, 18 / 255),
    cardSurface: rgb(30 / 255, 30 / 255, 30 / 255),
    cardStrokeStrong: white(0.16),
    inkPrimary: rgb(241 / 255, 241 / 255, 241 / 255),
  },
  light: {
    accent: rgb(0.02, 0.42, 0.92),
    safety: rgb(0.90, 0.45, 0.05),
    canvas: rgb(0.96, 0.96, 0.97),
    cardSurface: rgb(1.0, 1.0, 1.0),
    cardStrokeStrong: black(0.14),
    inkPrimary: rgb(0.10, 0.10, 0.12),
  },
  goldfish: {
    accent: rgb(1.0, 0.45, 0.18),
    safety: rgb(0.92, 0.28, 0.18),
    canvas: rgb(1.0, 0.96, 0.90),
    cardSurface: rgb(1.0, 0.99, 0.96),
    cardStrokeStrong: rgb(0.85, 0.45, 0.18, 0.40),
    inkPrimary: rgb(0.28, 0.14, 0.06),
  },
  midnight: {
    accent: rgb(0.20, 0.82, 0.92),
    safety: rgb(1.0, 0.62, 0.28),
    canvas: rgb(0.05, 0.08, 0.16),
    cardSurface: rgb(0.09, 0.13, 0.24),
    cardStrokeStrong: white(0.18),
    inkPrimary: rgb(0.90, 0.95, 1.0),
  },
  ember: {
    accent: rgb(0.98, 0.62, 0.18),
    safety: rgb(1.0, 0.42, 0.18),
    canvas: rgb(0.10, 0.08, 0.07),
    cardSurface: rgb(0.16, 0.12, 0.10),
    cardStrokeStrong: white(0.16),
    inkPrimary: rgb(0.98, 0.94, 0.88),
  },
  sequoia: {
    accent: rgb(0.35, 0.78, 0.58),
    safety: rgb(0.95, 0.55, 0.20),
    canvas: rgb(0.07, 0.11, 0.09),
    cardSurface: rgb(0.11, 0.16, 0.13),
    cardStrokeStrong: white(0.16),
    inkPrimary: rgb(0.90, 0.96, 0.92),
  },
};

function compositeOverOpaque(fg, bg) {
  const outA = fg.a + bg.a * (1 - fg.a);
  const ch = (f, b) => (f * fg.a + b * bg.a * (1 - fg.a)) / outA;
  return { r: ch(fg.r, bg.r), g: ch(fg.g, bg.g), b: ch(fg.b, bg.b), a: outA };
}

const toHex = ({ r, g, b }) =>
  [r, g, b]
    .map((c) => Math.round(Math.max(0, Math.min(1, c)) * 255).toString(16).padStart(2, '0'))
    .join('');

export function themeHexes(id) {
  const t = THEMES[id];
  if (!t) throw new Error(`Unknown theme: ${id}`);
  const strokeOpaque = compositeOverOpaque(t.cardStrokeStrong, t.canvas);
  return {
    bg: toHex(t.canvas),
    surface: toHex(t.cardSurface),
    stroke: toHex(strokeOpaque),
    ink: toHex(t.inkPrimary),
    accent: toHex(t.accent),
    safety: toHex(t.safety),
  };
}

export const THEME_IDS = Object.keys(THEMES);
