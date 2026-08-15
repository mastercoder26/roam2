import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import puppeteer from 'puppeteer';
import { themeHexes, THEME_IDS } from './themes.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = path.join(__dirname, 'public');
const OUT_DIR = path.join(__dirname, 'out');

const WIDTH = 1170;
const HEIGHT = 2532;
const FPS = 60;
const DURATION = 2.4;
const FRAME_COUNT = Math.round(FPS * DURATION);

fs.mkdirSync(OUT_DIR, { recursive: true });

function serveStatic() {
  const server = http.createServer((req, res) => {
    const reqPath = decodeURIComponent(req.url.split('?')[0]);
    const filePath = path.join(PUBLIC_DIR, reqPath === '/' ? 'scene.html' : reqPath);
    if (!filePath.startsWith(PUBLIC_DIR)) {
      res.writeHead(403);
      res.end();
      return;
    }
    fs.readFile(filePath, (err, data) => {
      if (err) {
        res.writeHead(404);
        res.end();
        return;
      }
      const ext = path.extname(filePath);
      const type = ext === '.js' ? 'text/javascript' : ext === '.html' ? 'text/html' : 'application/octet-stream';
      res.writeHead(200, { 'Content-Type': type });
      res.end(data);
    });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server)));
}

async function renderTheme(browser, port, themeId) {
  const hexes = themeHexes(themeId);
  const query = new URLSearchParams({
    w: String(WIDTH),
    h: String(HEIGHT),
    duration: String(DURATION),
    fps: String(FPS),
    ...hexes,
  });

  const page = await browser.newPage();
  await page.setViewport({ width: WIDTH, height: HEIGHT, deviceScaleFactor: 1 });
  await page.goto(`http://127.0.0.1:${port}/scene.html?${query}`, { waitUntil: 'load' });
  await page.waitForFunction('window.__ready === true');

  const frameDir = fs.mkdtempSync(path.join(os.tmpdir(), `roam-intro-${themeId}-`));
  console.log(`[${themeId}] capturing ${FRAME_COUNT} frames -> ${frameDir}`);

  for (let i = 0; i < FRAME_COUNT; i++) {
    const t = i / FPS;
    await page.evaluate((time) => window.__renderFrame(time), t);
    const framePath = path.join(frameDir, `frame${String(i).padStart(5, '0')}.png`);
    const canvas = await page.$('canvas');
    await canvas.screenshot({ path: framePath });
  }

  await page.close();

  const outPath = path.join(OUT_DIR, `intro-${themeId}.mp4`);
  execFileSync('ffmpeg', [
    '-y',
    '-framerate', String(FPS),
    '-i', path.join(frameDir, 'frame%05d.png'),
    '-frames:v', String(FRAME_COUNT),
    '-c:v', 'libx264',
    '-pix_fmt', 'yuv420p',
    '-profile:v', 'high',
    '-crf', '18',
    '-movflags', '+faststart',
    outPath,
  ], { stdio: 'inherit' });

  fs.rmSync(frameDir, { recursive: true, force: true });
  console.log(`[${themeId}] wrote ${outPath}`);
}

async function main() {
  const only = process.argv.slice(2);
  const themes = only.length ? only : THEME_IDS;

  const server = await serveStatic();
  const port = server.address().port;
  const browser = await puppeteer.launch({ headless: true, args: ['--use-gl=angle', '--use-angle=metal'] });

  try {
    for (const themeId of themes) {
      await renderTheme(browser, port, themeId);
    }
  } finally {
    await browser.close();
    server.close();
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
