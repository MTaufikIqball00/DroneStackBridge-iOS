#!/usr/bin/env node
/**
 * check.js — uji kecocokan kontrak app iOS <-> dashboard drone-stack.
 * =============================================================================
 *
 * KENAPA SKRIP INI ADA
 * --------------------
 * Kode Swift di app ini tidak bisa dibuktikan benar hanya dengan membacanya:
 * satu nama field yang meleset (`stampMs` alih-alih `stamp_ms`) tidak membuat
 * apa pun gagal build, tidak membuat WebSocket putus, dan tidak memunculkan
 * pesan error di mana pun — dashboard hanya diam-diam menampilkan nilai
 * default. Kegagalan seperti itu baru ketahuan saat drone sudah di udara.
 *
 * Maka skrip ini menjalankan payload yang dikirim app MELALUI KODE DASHBOARD
 * YANG SESUNGGUHNYA (frontend/lib/telemetryStore.ts dan pemetaan field di
 * frontend/lib/useRos.ts, keduanya dibaca langsung dari repo — bukan disalin),
 * lalu memeriksa apa yang benar-benar dilihat dashboard.
 *
 * TIGA LAPIS PEMERIKSAAN
 *   1. Field yang DIBACA dashboard vs field yang DIKIRIM app iOS. Keduanya
 *      diekstrak MEKANIS dari sumbernya (useRos.ts dan RosBridgeClient.swift),
 *      jadi tidak ada daftar yang diketik ulang dan bisa basi diam-diam.
 *   2. Fixture di skrip ini vs payload di kode Swift — supaya fixture tidak
 *      bisa lulus uji sementara kode Swift-nya sudah berubah.
 *   3. Uji perilaku: payload dijalankan lewat telemetryStore asli, lalu hasil
 *      yang dilihat dashboard diperiksa (baterai, gpsValid, ACK, dst).
 *
 * CARA PAKAI
 *   node Tools/contract-check/check.js [path-ke-repo-drone-stack]
 *
 * Default path repo: ~/drone-stack. Bisa juga lewat env DRONE_STACK_DIR.
 */

"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");

// -----------------------------------------------------------------------------
// Lokasi berkas
// -----------------------------------------------------------------------------
const repoDir =
  process.argv[2] ||
  process.env.DRONE_STACK_DIR ||
  path.join(os.homedir(), "drone-stack");

const frontendLib = path.join(repoDir, "frontend", "lib");
const useRosPath = path.join(frontendLib, "useRos.ts");
const storePath = path.join(frontendLib, "telemetryStore.ts");
const geoPath = path.join(frontendLib, "geo.ts");
const swiftPath = path.join(
  __dirname,
  "..",
  "..",
  "DroneStackBridge",
  "Bridge",
  "RosBridgeClient.swift"
);

for (const [label, p] of [
  ["useRos.ts", useRosPath],
  ["telemetryStore.ts", storePath],
  ["geo.ts", geoPath],
  ["RosBridgeClient.swift", swiftPath],
]) {
  if (!fs.existsSync(p)) {
    console.error(`GAGAL: tidak menemukan ${label} di ${p}`);
    console.error("Beri path repo drone-stack sebagai argumen pertama.");
    process.exit(2);
  }
}

// -----------------------------------------------------------------------------
// Pelaporan
// -----------------------------------------------------------------------------
let failures = 0;
let checks = 0;

function check(description, condition, detail) {
  checks += 1;
  if (condition) {
    console.log(`  PASS  ${description}`);
  } else {
    failures += 1;
    console.log(`  FAIL  ${description}`);
    if (detail !== undefined) console.log(`        ${detail}`);
  }
}

function section(title) {
  console.log(`\n${title}`);
  console.log("-".repeat(title.length));
}

// -----------------------------------------------------------------------------
// 1. Ekstraksi mekanis dari sumber
// -----------------------------------------------------------------------------

/** Ambil teks di dalam sepasang kurung, mulai dari indeks kurung pembuka. */
function extractBalanced(source, startIndex, open, close) {
  let depth = 0;
  for (let i = startIndex; i < source.length; i += 1) {
    const ch = source[i];
    if (ch === open) depth += 1;
    else if (ch === close) {
      depth -= 1;
      if (depth === 0) return source.slice(startIndex, i + 1);
    }
  }
  throw new Error("Kurung tidak seimbang saat mengekstrak blok.");
}

/**
 * Ambil OBJEK PEMETAAN yang sesungguhnya dari useRos.ts.
 *
 * Isi argumen ingestTelemetry({...}) di sana hanyalah ekspresi JavaScript biasa
 * atas variabel `data`, jadi bisa dievaluasi apa adanya. Dengan begitu uji ini
 * memakai pemetaan yang BENAR-BENAR dipakai dashboard, bukan tiruannya.
 */
function loadDashboardTelemetryMapper(useRosSource) {
  const marker = "telemetryStore.ingestTelemetry(";
  const at = useRosSource.indexOf(marker);
  if (at < 0) throw new Error("Tidak menemukan panggilan ingestTelemetry di useRos.ts");
  const braceAt = useRosSource.indexOf("{", at);
  const literal = extractBalanced(useRosSource, braceAt, "{", "}");
  // eslint-disable-next-line no-new-func
  return new Function("data", `return ${literal};`);
}

/** Nama field payload telemetry yang dibaca dashboard (`data.<nama>`). */
function dashboardTelemetryFields(useRosSource) {
  const marker = "telemetryStore.ingestTelemetry(";
  const at = useRosSource.indexOf(marker);
  const braceAt = useRosSource.indexOf("{", at);
  const literal = extractBalanced(useRosSource, braceAt, "{", "}");
  const found = new Set();
  for (const match of literal.matchAll(/\bdata\.([A-Za-z_][A-Za-z0-9_]*)/g)) {
    found.add(match[1]);
  }
  return found;
}

/** Kunci payload telemetry yang dikirim app iOS (dari kode Swift). */
function swiftTelemetryFields(swiftSource) {
  const fnAt = swiftSource.indexOf("private func publishTelemetryNow()");
  if (fnAt < 0) throw new Error("Tidak menemukan publishTelemetryNow() di Swift.");
  const fnEnd = swiftSource.indexOf("\n    // MARK: - Loop kontrol", fnAt);
  const body = swiftSource.slice(fnAt, fnEnd > 0 ? fnEnd : undefined);

  const declAt = body.indexOf("var payload: [String: Any] = [");
  const bracketAt = body.indexOf("[", declAt + "var payload: [String: Any] = ".length - 1);
  const literal = extractBalanced(body, bracketAt, "[", "]");

  const found = new Set();
  // Kunci literal di dalam dictionary: "nama": nilai
  for (const match of literal.matchAll(/"([A-Za-z_][A-Za-z0-9_]*)"\s*:/g)) {
    found.add(match[1]);
  }
  // Penetapan menyusul di luar literal: payload["nama"] = ...
  for (const match of body.matchAll(/payload\["([A-Za-z_][A-Za-z0-9_]*)"\]\s*=/g)) {
    found.add(match[1]);
  }
  return found;
}

/** Kunci payload /dashboard/state yang dikirim app iOS. */
function swiftStateFields(swiftSource) {
  const fnAt = swiftSource.indexOf("private func buildStatePayload()");
  if (fnAt < 0) throw new Error("Tidak menemukan buildStatePayload() di Swift.");
  const fnEnd = swiftSource.indexOf("\n    private func publishStateNow()", fnAt);
  const body = swiftSource.slice(fnAt, fnEnd > 0 ? fnEnd : undefined);
  const found = new Set();
  for (const match of body.matchAll(/"([A-Za-z_][A-Za-z0-9_]*)"\s*:/g)) {
    found.add(match[1]);
  }
  for (const match of body.matchAll(/payload\["([A-Za-z_][A-Za-z0-9_]*)"\]\s*=/g)) {
    found.add(match[1]);
  }
  return found;
}

// -----------------------------------------------------------------------------
// 2. Kompilasi telemetryStore.ts yang ASLI supaya bisa dijalankan di Node
// -----------------------------------------------------------------------------
function compileStore() {
  const workDir = fs.mkdtempSync(path.join(os.tmpdir(), "contract-check-"));
  const srcDir = path.join(workDir, "src");
  const outDir = path.join(workDir, "out");
  fs.mkdirSync(srcDir);

  // Alias "@/lib/geo" tidak ada di luar Next.js, jadi diarahkan ke berkas
  // tetangga. Ini SATU-SATUNYA perubahan terhadap sumber aslinya.
  const storeSource = fs
    .readFileSync(storePath, "utf8")
    .replace(/["']@\/lib\/geo["']/g, '"./geo"');

  fs.writeFileSync(path.join(srcDir, "telemetryStore.ts"), storeSource);
  fs.copyFileSync(geoPath, path.join(srcDir, "geo.ts"));

  const tsc = path.join(repoDir, "frontend", "node_modules", ".bin", "tsc");
  if (!fs.existsSync(tsc)) {
    throw new Error(
      `tsc tidak ditemukan di ${tsc}. Jalankan 'npm install' di frontend/ dulu.`
    );
  }

  // geo.ts memakai process.env, jadi definisi tipe Node harus ikut ditunjuk —
  // kalau tidak, tsc melapor "Cannot find name 'process'" hanya karena berkas
  // sementara ini berada di luar pohon node_modules milik frontend.
  const typeRoots = path.join(repoDir, "frontend", "node_modules", "@types");

  let compileOutput = "";
  try {
    execFileSync(
      tsc,
      [
        path.join(srcDir, "telemetryStore.ts"),
        path.join(srcDir, "geo.ts"),
        "--module", "commonjs",
        "--target", "es2020",
        "--outDir", outDir,
        "--skipLibCheck",
        "--typeRoots", typeRoots,
        "--types", "node",
      ],
      { stdio: "pipe" }
    );
  } catch (err) {
    // tsc TETAP menghasilkan JavaScript meski ada galat tipe. Yang menentukan
    // uji ini bisa lanjut adalah ada tidaknya berkas keluaran, bukan kode
    // keluar tsc — jadi galat dicatat lalu diperiksa hasilnya.
    compileOutput = [err.stdout, err.stderr]
      .map((buf) => (buf ? buf.toString() : ""))
      .join("")
      .trim();
  }

  const compiled = path.join(outDir, "telemetryStore.js");
  if (!fs.existsSync(compiled)) {
    throw new Error(compileOutput || "tsc tidak menghasilkan telemetryStore.js");
  }
  if (compileOutput) {
    console.log("  INFO  tsc melaporkan galat tipe (JavaScript tetap dihasilkan):");
    for (const line of compileOutput.split("\n").slice(0, 5)) {
      console.log(`        ${line}`);
    }
  }

  return require(compiled);
}

// -----------------------------------------------------------------------------
// 3. Fixture — cerminan payload yang dibangun kode Swift
// -----------------------------------------------------------------------------
// Nilainya dipilih supaya setiap konversi yang mudah salah bisa dibedakan
// hasilnya: baterai 87 (bukan 100), tegangan 11.4 V (bukan mV), lat/lon nyata,
// dan gpsValid true.
const telemetryFixture = {
  stamp_ms: Date.now(),
  x: 12.5,
  y: -8.25,
  z: 6.0,
  alt: 6.0,
  yaw: 1.5708,
  heading: 90.0,
  vx: 1.2,
  vy: 0.4,
  vz: 0.3,
  speed: 1.265,
  voltage: 11.4,
  armed: true,
  flightMode: "P-GPS",
  navState: "auto",
  journeyStatus: "Navigating to Target",
  nearestObstacle: null,
  pathIndex: 0,
  pathLength: 1,
  gpsValid: true,
  lat: -6.9175,
  lon: 107.6191,
  armDisarmSupported: false,
  advancedFeaturesSupported: false,
  // Kewenangan kendali jembatan. Sengaja false di fixture: itulah jalur
  // yang HARUS terlihat di dashboard, dan yang selama ini gagal diam.
  controlReady: false,
  battery: 87,
};

const stateFixture = {
  mode: "auto",
  journey_status: "Navigating to Target",
  rtlTriggered: false,
  nearestObstacle: null,
  vehicle: { armed: true, navStateName: "P-GPS" },
  waypointSeq: 7,
  battery: { remaining: 0.87, voltage: 11.4 },
};

// -----------------------------------------------------------------------------
// Jalankan
// -----------------------------------------------------------------------------
console.log("Uji kontrak app iOS <-> dashboard drone-stack");
console.log(`Repo dashboard : ${repoDir}`);
console.log(`Kode Swift     : ${swiftPath}`);

const useRosSource = fs.readFileSync(useRosPath, "utf8");
const swiftSource = fs.readFileSync(swiftPath, "utf8");

// --- Lapis 1: nama field -----------------------------------------------------
section("1. Field telemetry: yang dibaca dashboard vs yang dikirim app iOS");

const readFields = dashboardTelemetryFields(useRosSource);
const sentFields = swiftTelemetryFields(swiftSource);

const missing = [...readFields].filter((f) => !sentFields.has(f)).sort();
const extra = [...sentFields].filter((f) => !readFields.has(f)).sort();

console.log(`  Dashboard membaca ${readFields.size} field, app mengirim ${sentFields.size}.`);
check(
  "Setiap field yang dibaca dashboard benar-benar dikirim app iOS",
  missing.length === 0,
  `Tidak terkirim: ${missing.join(", ")}`
);
console.log(
  `  INFO  Field ekstra yang dikirim app (diabaikan dashboard, tidak berbahaya): ${
    extra.length ? extra.join(", ") : "-"
  }`
);

// --- Lapis 2: fixture vs kode Swift -----------------------------------------
section("2. Fixture uji vs payload di kode Swift");

const fixtureKeys = new Set(Object.keys(telemetryFixture));
const fixtureMissing = [...sentFields].filter((f) => !fixtureKeys.has(f)).sort();
const fixtureExtra = [...fixtureKeys].filter((f) => !sentFields.has(f)).sort();
check(
  "Fixture telemetry memuat persis field yang dibangun publishTelemetryNow()",
  fixtureMissing.length === 0 && fixtureExtra.length === 0,
  `kurang: [${fixtureMissing.join(", ")}] lebih: [${fixtureExtra.join(", ")}]`
);

const stateFields = swiftStateFields(swiftSource);
const stateFixtureKeys = new Set(Object.keys(stateFixture));
// `remaining`/`voltage`/`armed`/`navStateName` ada di dalam sub-objek, jadi
// dibandingkan hanya pada tingkat teratas.
const nestedKeys = new Set(["remaining", "voltage", "armed", "navStateName"]);
const stateMissing = [...stateFields].filter(
  (f) => !stateFixtureKeys.has(f) && !nestedKeys.has(f)
).sort();
check(
  "Fixture state memuat persis field yang dibangun buildStatePayload()",
  stateMissing.length === 0,
  `kurang: [${stateMissing.join(", ")}]`
);

// --- Lapis 3: perilaku dashboard sesungguhnya --------------------------------
section("3. Perilaku: payload dijalankan lewat telemetryStore.ts asli");

// Shim minimal supaya store bisa menerbitkan snapshot di luar browser. Store
// memanggil requestAnimationFrame lewat objek window; di sini dijalankan
// serentak supaya hasilnya bisa langsung diperiksa.
global.window = {
  requestAnimationFrame: (cb) => {
    cb();
    return 1;
  },
  cancelAnimationFrame: () => {},
};
global.performance = { now: () => Date.now() };

let storeModule;
try {
  storeModule = compileStore();
} catch (err) {
  console.log("  FAIL  Gagal mengompilasi telemetryStore.ts");
  console.log(`        ${err.message}`);
  process.exit(1);
}

const { telemetryStore } = storeModule;
const mapTelemetry = loadDashboardTelemetryMapper(useRosSource);

// -- telemetry --
telemetryStore.ingestTelemetry(mapTelemetry(telemetryFixture));
const live = telemetryStore.live;
const vehicle1 = telemetryStore.getVehicleSnapshot();

check("Posisi GPS sampai ke dashboard", live.lat === -6.9175 && live.lon === 107.6191,
  `lat=${live.lat} lon=${live.lon}`);
check("Altitude sampai ke dashboard", live.alt === 6.0, `alt=${live.alt}`);
check("Baterai terbaca 87% (bukan 8700% / 0%)", live.battery === 87, `battery=${live.battery}`);
check("Tegangan terbaca 11.4 V (bukan 11400)", live.voltage === 11.4, `voltage=${live.voltage}`);
check("Kecepatan sampai ke dashboard", live.speed === 1.265, `speed=${live.speed}`);
check("gpsValid diteruskan sebagai true", vehicle1.gpsValid === true);
check("armed diteruskan sebagai true", vehicle1.armed === true);
check("flightMode terbaca 'P-GPS'", vehicle1.flightMode === "P-GPS", `flightMode=${vehicle1.flightMode}`);
check(
  "armDisarmSupported=false -> dashboard menyembunyikan tombol ARM/DISARM",
  vehicle1.armDisarmSupported === false
);
check(
  "advancedFeaturesSupported=false -> RTH/Emergency/Auto Survey disembunyikan",
  vehicle1.advancedFeaturesSupported === false
);
check(
  "controlReady=false -> dashboard menampilkan peringatan NO CONTROL",
  vehicle1.controlReady === false
);
check(
  "stamp_ms terbaca sebagai basis latency (bukan NaN/0)",
  Number.isFinite(vehicle1.latencyMs) && Math.abs(vehicle1.latencyMs) < 60000,
  `latencyMs=${vehicle1.latencyMs}`
);

// -- state (tanpa field `event` -> jalur ingestState) --
// Pencabangan di bawah persis seperti useRos.ts: ada `event` -> ingestEvent,
// selain itu -> ingestState.
function routeStatePayload(payload) {
  if (payload && typeof payload.event === "string") telemetryStore.ingestEvent(payload);
  else telemetryStore.ingestState(payload);
}

routeStatePayload(stateFixture);
const vehicle2 = telemetryStore.getVehicleSnapshot();
check(
  "journey_status muncul di dashboard sebagai Journey Status",
  vehicle2.journeyStatus === "Navigating to Target",
  `journeyStatus=${vehicle2.journeyStatus}`
);
check(
  "battery.remaining 0.87 -> tetap terbaca 87% (bukan 0.87%)",
  telemetryStore.live.battery === 87,
  `battery=${telemetryStore.live.battery}`
);

// -- event: ACK, NACK, kedatangan --
routeStatePayload({
  event: "waypoints_ack",
  seq: 7,
  count: 1,
  message: "1 waypoint diterima via GPS (lat/lon) & navigasi dimulai.",
  stamp_ms: Date.now(),
});
check(
  "waypoints_ack seq=7 mengakhiri status 'Menunggu ACK' di dashboard",
  telemetryStore.getVehicleSnapshot().ackedSeq === 7,
  `ackedSeq=${telemetryStore.getVehicleSnapshot().ackedSeq}`
);

routeStatePayload({
  event: "waypoints_nack",
  seq: 8,
  count: 0,
  message: "Posisi drone belum punya fix GPS (3 satelit).",
  stamp_ms: Date.now(),
});
const vehicle3 = telemetryStore.getVehicleSnapshot();
check(
  "waypoints_nack seq=8 ikut membersihkan status pending (nackedSeq terisi)",
  vehicle3.nackedSeq === 8,
  `nackedSeq=${vehicle3.nackedSeq}`
);
check(
  "Alasan penolakan sampai ke operator",
  vehicle3.ackMessage.includes("fix GPS"),
  `ackMessage=${vehicle3.ackMessage}`
);

routeStatePayload({
  event: "mission_complete",
  seq: 7,
  count: 1,
  message: "Waypoint tercapai.",
  stamp_ms: Date.now(),
});
check(
  "mission_complete seq=7 menandai kedatangan di dashboard",
  telemetryStore.getVehicleSnapshot().completedSeq === 7,
  `completedSeq=${telemetryStore.getVehicleSnapshot().completedSeq}`
);

// -- resync: balasan service harus JSON yang bisa di-ingest --
section("4. Balasan /dashboard/resync bisa diparse dashboard");
const resyncMessage = JSON.stringify(stateFixture);
let resyncOk = true;
try {
  telemetryStore.ingestState(JSON.parse(resyncMessage));
} catch (err) {
  resyncOk = false;
}
check(
  "message balasan resync valid sebagai JSON state (useRos mem-parse-nya)",
  resyncOk
);

// --- Lapis 5: kontrak jalur foto vs backend_ai/api.py -----------------------
section("5. Jalur foto: app iOS vs backend_ai/api.py");

const apiPath = path.join(repoDir, "backend_ai", "api.py");
const uploaderPath = path.join(
  __dirname, "..", "..", "DroneStackBridge", "Photo", "PhotoBatchUploader.swift"
);

if (!fs.existsSync(apiPath) || !fs.existsSync(uploaderPath)) {
  console.log("  SKIP  api.py atau PhotoBatchUploader.swift tidak ditemukan.");
} else {
  const apiSource = fs.readFileSync(apiPath, "utf8");
  const uploaderSource = fs.readFileSync(uploaderPath, "utf8");

  // Endpoint yang dituju app harus benar-benar ada di backend.
  const swiftUrl = uploaderSource.match(/http:\/\/\\\(serverIp\):\\\(port\)(\/[A-Za-z0-9/_-]*)/);
  const swiftPath_ = swiftUrl ? swiftUrl[1] : null;
  check(
    "Endpoint yang dipanggil app terdaftar di api.py",
    swiftPath_ !== null && apiSource.includes(`@app.post("${swiftPath_}"`),
    `app memanggil ${swiftPath_}`
  );

  // Nama field multipart harus sama dengan parameter FastAPI.
  const fastapiField = apiSource.match(/^\s*(\w+)\s*:\s*list\[UploadFile\]\s*=\s*File\(/m);
  const swiftField = uploaderSource.match(/name=\\"([A-Za-z_][A-Za-z0-9_]*)\\"/);
  check(
    "Nama field multipart app == parameter list[UploadFile] di FastAPI",
    fastapiField !== null && swiftField !== null && fastapiField[1] === swiftField[1],
    `FastAPI="${fastapiField ? fastapiField[1] : "?"}" app="${swiftField ? swiftField[1] : "?"}"`
  );

  // Ambang minimum foto harus sama, kalau tidak app mengirim batch yang
  // dijamin ditolak HTTP 400 setelah menunggu unggahan puluhan MB selesai.
  const apiMin = apiSource.match(/if\s+len\(images\)\s*<\s*(\d+)/);
  const swiftMin = uploaderSource.match(/static let minPhotos\s*=\s*(\d+)/);
  check(
    "Ambang minimum foto app == ambang di backend",
    apiMin !== null && swiftMin !== null && apiMin[1] === swiftMin[1],
    `backend=${apiMin ? apiMin[1] : "?"} app=${swiftMin ? swiftMin[1] : "?"}`
  );

  // Field balasan yang dibaca app harus benar-benar diterbitkan backend.
  check(
    "Field 'job_id' yang dibaca app ada di model balasan backend",
    /job_id\s*:\s*str/.test(apiSource) && uploaderSource.includes('"job_id"')
  );
  check(
    "Field 'detail' untuk pesan galat dipakai backend (HTTPException)",
    apiSource.includes("HTTPException") && uploaderSource.includes('"detail"')
  );
}

// -----------------------------------------------------------------------------
console.log("\n" + "=".repeat(60));
console.log(`Total ${checks} pemeriksaan, ${failures} gagal.`);
console.log("=".repeat(60));
process.exit(failures === 0 ? 0 : 1);
