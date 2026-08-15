import * as THREE from './three.module.js';

// ---- Params (theme colors + render config), passed via query string ----
const params = new URLSearchParams(location.search);
const color = (key, fallback) => {
  const v = params.get(key);
  return new THREE.Color(v ? `#${v}` : fallback);
};
const num = (key, fallback) => {
  const v = params.get(key);
  return v ? Number(v) : fallback;
};

const COLORS = {
  bg: color('bg', '#121212'),
  stroke: color('stroke', '#333333'),
  ink: color('ink', '#f1f1f1'),
};

const WIDTH = num('w', 1170);
const HEIGHT = num('h', 2532);
const DURATION = num('duration', 2.4);
const FPS = num('fps', 60);

// ---- Renderer ----
const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: false, preserveDrawingBuffer: true });
renderer.setSize(WIDTH, HEIGHT, false);
renderer.setPixelRatio(1);
renderer.setClearColor(COLORS.bg, 1);
document.body.appendChild(renderer.domElement);

const scene = new THREE.Scene();
scene.background = COLORS.bg;

const camera = new THREE.PerspectiveCamera(40, WIDTH / HEIGHT, 0.1, 100);

// ---- Lighting: flat, directional, no gradient washes ----
scene.add(new THREE.AmbientLight(COLORS.ink, 0.55));
const key = new THREE.DirectionalLight(0xffffff, 1.1);
key.position.set(2.2, 2.6, 1.8);
scene.add(key);
const rim = new THREE.DirectionalLight(0x2b6cb5, 0.35);
rim.position.set(-2, -1, -1.5);
scene.add(rim);

// ---- Globe: low-poly faceted sphere, colored ocean-blue and land-green ----
const RADIUS = 1.55;
const OCEAN_DEEP = new THREE.Color('#123e78');
const OCEAN_SHALLOW = new THREE.Color('#1f6fb2');
const LAND_DARK = new THREE.Color('#1f5c34');
const LAND_LIGHT = new THREE.Color('#3c9a52');

const globeGeo = new THREE.IcosahedronGeometry(RADIUS, 3).toNonIndexed();
assignFacePalette(globeGeo);

const globeMat = new THREE.MeshStandardMaterial({
  vertexColors: true,
  flatShading: true,
  roughness: 0.85,
  metalness: 0.05,
});
const globe = new THREE.Mesh(globeGeo, globeMat);
scene.add(globe);

/// Colors each triangle solid blue or green from cheap trig noise on its
/// centroid — flat per-face fills only, so the "no gradients" rule holds
/// even though the planet now reads with two hues instead of one.
function assignFacePalette(geometry) {
  const position = geometry.attributes.position;
  const faceCount = position.count / 3;
  const colors = new Float32Array(position.count * 3);
  const centroid = new THREE.Vector3();
  const vertex = new THREE.Vector3();

  for (let face = 0; face < faceCount; face++) {
    centroid.set(0, 0, 0);
    for (let v = 0; v < 3; v++) {
      vertex.fromBufferAttribute(position, face * 3 + v);
      centroid.add(vertex);
    }
    centroid.multiplyScalar(1 / 3).normalize();

    const land =
      Math.sin(centroid.x * 4.1 + centroid.y * 2.7) * 0.5 +
      Math.sin(centroid.y * 5.3 - centroid.z * 3.1) * 0.3 +
      Math.sin(centroid.z * 6.7 + centroid.x * 1.9) * 0.4;
    const shade =
      Math.sin(centroid.x * 9.3 - centroid.z * 4.4) * 0.5 +
      Math.sin(centroid.y * 7.1 + centroid.x * 3.6) * 0.5;

    const isLand = land > 0.12;
    const pick = isLand
      ? shade > 0
        ? LAND_LIGHT
        : LAND_DARK
      : shade > 0.2
        ? OCEAN_SHALLOW
        : OCEAN_DEEP;

    for (let v = 0; v < 3; v++) {
      const i = (face * 3 + v) * 3;
      colors[i] = pick.r;
      colors[i + 1] = pick.g;
      colors[i + 2] = pick.b;
    }
  }

  geometry.setAttribute('color', new THREE.BufferAttribute(colors, 3));
}

// Wireframe shell — the same "map grid" language as the app's atmosphere.
const wireGeo = new THREE.IcosahedronGeometry(RADIUS * 1.004, 2);
const wireMat = new THREE.MeshBasicMaterial({
  color: COLORS.stroke,
  wireframe: true,
  transparent: true,
  opacity: 0.4,
});
const wire = new THREE.Mesh(wireGeo, wireMat);
scene.add(wire);

// ---- Fade overlay for a clean handoff into the native wordmark reveal ----
const fadeGeo = new THREE.PlaneGeometry(2, 2);
const fadeMat = new THREE.MeshBasicMaterial({ color: COLORS.bg, transparent: true, opacity: 0 });
const fadeCamera = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);
const fadeScene = new THREE.Scene();
fadeScene.add(new THREE.Mesh(fadeGeo, fadeMat));

// ---- Easing ----
const easeOutCubic = (t) => 1 - Math.pow(1 - t, 3);
const easeInOutCubic = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
const easeOutBack = (t) => {
  const c1 = 1.70158, c3 = c1 + 1;
  return 1 + c3 * Math.pow(t - 1, 3) + c1 * Math.pow(t - 1, 2);
};
const clamp01 = (v) => Math.min(1, Math.max(0, v));
const remap = (t, a, b) => clamp01((t - a) / (b - a));

// ---- Beat timings (fraction of DURATION) ----
const T_GLOBE_IN_END = 0.34 / DURATION;
const T_FADE_START = 2.02 / DURATION;

function render(timeSeconds) {
  const t = clamp01(timeSeconds / DURATION);

  // Globe scale-in.
  const globeIn = easeOutBack(remap(t, 0, T_GLOBE_IN_END));
  const scale = THREE.MathUtils.clamp(globeIn, 0.001, 1.08);
  globe.scale.setScalar(scale);
  wire.scale.setScalar(scale);

  // The whole point of the shot now: the planet just spins, at a constant
  // angular velocity. The camera stays put so nothing competes with that
  // motion — an eased camera drift on top of a linear spin reads as an
  // uneven, wobbly rotation instead of a smooth one.
  const spin = t * Math.PI * 0.85;
  globe.rotation.y = spin;
  wire.rotation.y = spin;

  const elevation = 0.18;
  const distance = 9.4;

  camera.position.set(0, distance * Math.sin(elevation), distance * Math.cos(elevation));
  camera.lookAt(0, 0, 0);

  // Fade to canvas color for the handoff to the native lockup.
  const fade = easeInOutCubic(remap(t, T_FADE_START, 1));
  fadeMat.opacity = fade;

  renderer.render(scene, camera);
  if (fade > 0) {
    renderer.autoClear = false;
    renderer.render(fadeScene, fadeCamera);
    renderer.autoClear = true;
  }
}

window.__renderFrame = render;
window.__ready = true;
render(0);
