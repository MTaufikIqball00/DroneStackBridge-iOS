# DroneStackBridge (iOS)

Jembatan antara **DJI Spark** dan dashboard **drone-stack**, padanan iOS dari
app Android `RosBridgeClient.java`.

App ini punya **dua jalur**, sama seperti app Android:

1. **Jembatan kendali** — menyambung sebagai *client* ke `rosbridge_server`
   (port 9090), menerjemahkan perintah dashboard menjadi kontrol nyata lewat DJI
   Mobile SDK, dan mengirim balik telemetry.
2. **Jalur foto** — memindahkan foto dari kartu SD drone ke iPhone lewat radio
   DJI, lalu mengunggahnya sebagai satu batch ke `backend_ai`
   (`POST /jobs/stitch`, port 8000) untuk stitching + klasifikasi panen.

Dashboard dan backend **tidak perlu diubah sama sekali** — kedua kontraknya
sudah diuji cocok (lihat *Verifikasi* di bawah).

```
Dashboard Next.js ──ws──► rosbridge_server ──ws──┐
   (laptop :3000)          (laptop :9090)        │
                                                 ├─► app iOS ──DJI SDK──► Spark
backend_ai FastAPI ◄──── POST /jobs/stitch ──────┘   (iPhone)
   (laptop :8000)              (foto)
```

IP laptop diketik **sekali**; rosbridge (9090) dan backend (8000) diasumsikan
berjalan di mesin yang sama — persis seperti sisi Android.

Pada mode `--dji`, `scripts/start.sh` **tidak menjalankan** node Python
(`dashboard_bridge_node*.py`) sama sekali. App inilah penggantinya. Jangan
pernah menjalankan keduanya bersamaan — keduanya akan berebut nama service
`/takeoff` dan `/land` di ROS graph.

---

## Prasyarat

| Kebutuhan | Keterangan |
|---|---|
| **macOS + Xcode** | Wajib. Project iOS tidak bisa di-build dari Windows/WSL. |
| CocoaPods | `sudo gem install cocoapods` |
| iPhone/iPad fisik | DJI SDK **tidak jalan di Simulator** (framework tanpa slice arm64-sim). |
| App Key DJI **iOS** | Key Android tidak bisa dipakai — lihat di bawah. |
| Target minimum | iOS 15.0 |

### App Key DJI harus didaftarkan ULANG untuk iOS

DJI mengikat setiap App Key ke **satu Bundle ID / package name**. App Key yang
sudah terdaftar untuk app Android tidak akan diterima di sini, dan kegagalannya
muncul **saat runtime** (registrasi SDK gagal), bukan saat build.

1. Buka [developer.dji.com](https://developer.dji.com) → **Apps** → *Create App*
2. Platform: **iOS**, Bundle Identifier: `com.dronestack.bridge`
   (harus sama persis dengan `PRODUCT_BUNDLE_IDENTIFIER` di target Xcode)
3. Salin App Key ke `DroneStackBridge/Info.plist`, kunci `DJISDKAppKey`,
   menggantikan `ISI_APP_KEY_IOS_ANDA_DI_SINI`

---

## Membuat project Xcode

Berkas `.xcodeproj` sengaja **tidak** disertakan: isinya penuh UUID yang hanya
bisa dihasilkan Xcode dengan benar, dan versi karangan-tangan biasanya gagal
dibuka dengan pesan yang tidak menolong.

### Jalur cepat — XcodeGen

```bash
brew install xcodegen
cd DroneStackBridge-iOS
xcodegen generate
pod install
open DroneStackBridge.xcworkspace
```

### Jalur manual — tanpa XcodeGen

1. Xcode → *File ▸ New ▸ Project ▸ iOS ▸ App*
   - Product Name: `DroneStackBridge`
   - Interface: **SwiftUI**, Language: **Swift**
   - Bundle Identifier: `com.dronestack.bridge`
   - Simpan di folder ini, **timpa/gabung** dengan folder `DroneStackBridge/`
2. Hapus `ContentView.swift` dan `DroneStackBridgeApp.swift` bawaan Xcode,
   lalu *Add Files to…* seluruh isi folder `DroneStackBridge/`
   (centang **Create groups**, bukan folder reference)
3. Target ▸ *Build Settings* ▸ **iOS Deployment Target** = `15.0`
4. Target ▸ *Build Settings* ▸ **Info.plist File** = `DroneStackBridge/Info.plist`
   dan **Generate Info.plist File** = `No`
5. Tutup Xcode, `pod install`, lalu buka `DroneStackBridge.xcworkspace`

> Setelah `pod install`, **selalu buka `.xcworkspace`**, bukan `.xcodeproj`.
> Kalau salah, `import DJISDK` gagal dengan "no such module".

---

## Cara memakai di lapangan

**PENTING soal topologi jaringan:** Remote Controller DJI Spark tersambung ke
HP lewat **WiFi**, BUKAN kabel USB (beda dari Mavic/Phantom yang pakai USB).
Karena itu WiFi iPhone "terpakai penuh" untuk bicara ke RC dan tidak bisa
sekaligus jadi anggota WiFi/LAN laptop untuk rosbridge — keduanya butuh WiFi,
dan iPhone cuma punya satu radio WiFi. Solusinya: **laptop ikut bergabung ke
WiFi yang dipancarkan RC Spark**, bukan sebaliknya. Detail & urutan lengkap ada
di bawah.

### Persiapan (di rumah/kantor, SEBELUM ke lapangan)

1. **Laptop:** `./scripts/start.sh --dji`
2. **Aktifkan/perbarui portproxy Windows** — WAJIB setiap kali laptop/WSL
   di-restart, karena IP internal WSL2 berubah tiap kali itu terjadi. Di WSL:
   ```bash
   hostname -I
   ```
   Salin IP yang muncul (mis. `172.24.180.182`), lalu di **PowerShell sebagai
   Administrator** di Windows:
   ```powershell
   netsh interface portproxy delete v4tov4 listenport=9090 listenaddress=0.0.0.0
   netsh interface portproxy add v4tov4 listenport=9090 listenaddress=0.0.0.0 connectport=9090 connectaddress=<IP_DARI_HOSTNAME_I>
   ```
   Rule ini yang meneruskan trafik dari **adapter Windows manapun** (WiFi
   biasa, WiFi RC Spark, dst — `0.0.0.0` berarti "semua") ke rosbridge yang
   sebenarnya jalan di dalam WSL2. Tanpa langkah ini, HP tidak akan pernah
   bisa mencapai rosbridge dari jaringan manapun.
3. **iPhone masih di WiFi/data seluler biasa** (jangan disambungkan ke RC dulu).
   Buka app → tunggu **Registrasi SDK** hijau. Ini WAJIB dilakukan sebelum
   WiFi iPhone pindah ke jaringan RC, karena registrasi butuh internet dan
   jaringan RC Spark biasanya tidak tersambung ke internet sama sekali.
4. **Jangan force-close app** setelah langkah 3 — registrasi hanya diverifikasi
   sekali per sesi berjalan, tapi kalau app di-restart selagi WiFi sudah pindah
   ke jaringan RC (tanpa internet), registrasi bisa gagal lagi.
5. Jaga-jaga: aktifkan **Settings → Cellular → Wi-Fi Assist** di iPhone. Kalau
   nanti app terlanjur harus dibuka ulang saat WiFi sudah di jaringan RC, iOS
   otomatis melimpahkan trafik yang butuh internet ke data seluler.

### Di lapangan

6. Nyalakan **Spark** dan **Remote Controller** — RC mulai memancarkan WiFi-nya.
7. **Di iPhone:** Settings → Wi-Fi → sambungkan ke jaringan RC Spark (nama &
   password biasanya tertera di stiker RC). Kembali ke app — status
   **Drone tersambung** akan menyala hijau.
8. **Di laptop:** sambungkan WiFi Windows ke jaringan RC Spark yang sama.
9. **Cari IP laptop di jaringan itu — WAJIB dari sisi WINDOWS, BUKAN dari WSL.**
   `hostname -I` di WSL memberi IP internal WSL2 yang **tidak bisa dijangkau
   HP sama sekali** — itu cuma dipakai sebagai target di langkah 2 di atas,
   bukan yang diketik ke app. Cek IP yang benar lewat **Command Prompt/
   PowerShell Windows** (persis seperti app Android Anda selama ini):
   ```cmd
   ipconfig
   ```
   Cari adapter yang **sedang aktif** menuju jaringan RC Spark (biasanya
   "Wireless LAN adapter Wi-Fi", tapi namanya bisa berubah — cocokkan dengan
   yang statusnya "Connected" ke SSID RC Spark), pakai **IPv4 Address**-nya.
10. **Di app:** ganti isian **IP** dengan IP dari langkah 9 (dari `ipconfig`,
    BUKAN `hostname -I`), port tetap `9090` → **Sambungkan Jembatan**. Log
    app harus menunjukkan "Virtual Stick aktif" lalu "Jembatan AKTIF".
11. **Dashboard** (`http://localhost:3000` dibuka langsung di laptop — tidak
    perlu IP jaringan RC untuk ini) akan menampilkan telemetry.
12. **Setelah misi selesai** — tekan **Sync Foto ke Backend** di app. Foto
    diunduh dari kartu SD drone ke iPhone, lalu diunggah sebagai satu batch;
    app menampilkan `job_id` yang bisa dipantau di `GET /jobs/{id}`.

> Sinkronisasi foto memindahkan kamera ke mode unduh, sehingga drone **tidak bisa
> memotret** selama proses berlangsung. Jalankan setelah pemotretan selesai, bukan
> sambil terbang. Tombolnya sengaja tidak menuntut jembatan rosbridge aktif —
> jalur foto hanya butuh kamera.

### Jaringan — jebakan paling sering

- **iPhone dan laptop harus berada di jaringan WiFi yang SAMA** — dalam
  praktiknya berarti WiFi yang dipancarkan RC Spark (lihat topologi di atas).
- **Laptop memakai WSL2, dan di lingkungan ini WSL2 jalan mode NAT KLASIK, BUKAN
  mirrored networking** (dicek langsung 2026-08-15 — `.wslconfig` tidak ada/tidak
  aktif, IP WSL2 di rentang NAT `172.24.x.x`, terpisah total dari IP asli
  Windows). Konsekuensinya:
  - **`hostname -I` di WSL TIDAK PERNAH bisa dipakai sebagai IP yang diketik
    ke app** — itu IP internal yang tidak terjangkau dari luar WSL2 sama
    sekali. IP yang benar untuk app selalu dari **`ipconfig` di Windows**
    (CMD/PowerShell), cari adapter yang sedang aktif ke jaringan yang sama
    dengan HP.
  - Rosbridge hanya bisa dijangkau dari luar lewat **portproxy manual**
    (`netsh interface portproxy`, lihat langkah 2 di atas), yang meneruskan
    dari `0.0.0.0:9090` di Windows ke IP internal WSL2. Rule ini **basi
    setiap kali WSL/laptop restart** (IP internal WSL2 berubah) — harus
    dihapus & dibuat ulang dengan IP baru dari `hostname -I` setiap kali itu
    terjadi.
  - Kalau di lain waktu ingin mencoba mirrored networking (supaya tidak perlu
    portproxy manual lagi), buat `C:\Users\<user>\.wslconfig`:
    ```ini
    [wsl2]
    networkingMode=mirrored
    ```
    lalu `wsl --shutdown` dan **verifikasi ulang** dengan `hostname -I` di WSL
    vs `ipconfig` di Windows — kalau angkanya SAMA, mirrored aktif dan
    portproxy tidak diperlukan lagi. Jangan asumsikan aktif tanpa mengecek
    langsung; itu yang sebelumnya bikin dokumentasi ini salah.
  - Cek cepat status rosbridge: `ss -tlnp | grep 9090` di WSL.
- iOS akan menampilkan prompt izin **Local Network** saat pertama menyambung
  ke jaringan baru. Harus diizinkan; kalau tertolak, WebSocket gagal tanpa
  pesan yang jelas.
- Kalau laptop gagal join WiFi RC (password salah/band tidak cocok), cek
  stiker fisik di badan RC untuk SSID & password default.

---

## Kontrak dengan dashboard

### Yang app ini SEDIAKAN (dashboard → app)

| Nama | Tipe | Catatan |
|---|---|---|
| `/takeoff` | service `std_srvs/srv/Trigger` | timeout dashboard 5 s |
| `/land` | service `Trigger` | |
| `/dashboard/resync` | service `Trigger` | `message` balasannya **JSON state**, bukan teks |
| `/dashboard/takeoff_altitude` | `std_msgs/msg/Float32` | dikirim tepat sebelum `/takeoff` |
| `/cmd_vel` | `geometry_msgs/msg/Twist` | manual 10 Hz |
| `/dashboard/waypoints` | `std_msgs/msg/String` | `{"seq":N,"waypoints":[{lat,lon,z}]}` |

Service lanjutan (`/arm`, `/disarm`, `/return_home`, `/emergency_stop`,
`/force_arm_takeoff`, `/start_auto_survey`, `/start_orbit_mission`) **tidak**
disediakan — app mengirim `armDisarmSupported:false` dan
`advancedFeaturesSupported:false`, dan dashboard menyembunyikan tombolnya
sepenuhnya alih-alih menampilkan tombol yang hanya akan timeout.

### Yang app ini KIRIM (app → dashboard)

- **`/dashboard/telemetry`** — String berisi JSON, 5 Hz
- **`/dashboard/state`** — String berisi JSON, 2 Hz, dua bentuk:
  - tanpa `event` → snapshot state
  - dengan `event` → `waypoints_ack` / `waypoints_nack` / `mission_complete`

Tiga hal yang paling mudah salah dan sudah ditangani:

1. `stamp_ms` adalah **satu-satunya** field snake_case di payload telemetry.
2. `battery` di `/dashboard/telemetry` adalah **persen 0–100**, sedangkan
   `battery.remaining` di `/dashboard/state` adalah **fraksi 0–1**.
3. `seq` pada event harus **sama persis** dengan yang dikirim dashboard, kalau
   tidak badge "Menunggu ACK" menggantung selamanya.

---

## Verifikasi

```bash
node Tools/contract-check/check.js /path/ke/drone-stack
```

Skrip ini menjalankan payload app **melalui kode dashboard yang sesungguhnya**
(`frontend/lib/telemetryStore.ts` dikompilasi dan dijalankan, pemetaan field
diambil langsung dari `frontend/lib/useRos.ts`) lalu memeriksa apa yang
benar-benar dilihat dashboard. Daftar field dibandingkan secara mekanis dari
kedua sumber, jadi tidak ada daftar yang bisa basi diam-diam.

Kontrak jalur foto juga diperiksa terhadap `backend_ai/api.py` asli: endpoint,
nama field multipart (`images`), ambang minimum 4 foto, serta field `job_id` dan
`detail` pada balasan.

Hasil terakhir: **27 pemeriksaan, 0 gagal**. Ketahanannya diuji dengan tiga
kontrol negatif (`stamp_ms` → `stampMs`; tegangan dikirim dalam mV; nama field
`images` → `photos` dan ambang 4 → 1) — semuanya benar terdeteksi gagal.

**Yang BELUM diverifikasi:** kode Swift belum pernah dikompilasi (butuh Xcode
di macOS), dan belum pernah diterbangkan. Uji di atas membuktikan *kontrak
datanya* cocok, bukan bahwa app-nya bisa di-build atau bahwa drone terbang benar.

---

## Perbedaan yang disengaja dari versi Android

Semuanya kompatibel dengan dashboard tanpa perubahan apa pun di sisi dashboard.
Setiap butir ditandai `BEDA DARI ANDROID` di kode pada tempatnya.

| # | Perbedaan | Alasan |
|---|---|---|
| 1 | **Navigasi waypoint dikonversi ke kerangka badan** (`Geo.groundToBody`) | Versi Android menyetel koordinat `BODY` tapi mengirim vektor utara/timur tanpa konversi — benar hanya saat hidung drone menghadap utara. Kode Android sendiri menyisakan `TODO lapangan: verifikasi arah pitch/roll benar`. |
| 2 | **Mode virtual stick disetel ulang tiap pesawat tersambung** | Dokumentasi DJI: `rollPitchControlMode` dkk **direset ke default saat FC tersambung ulang**, dan defaultnya *Angle*, bukan *Velocity*. |
| 3 | **`/cmd_vel` kedaluwarsa setelah 1 detik** | Versi Android menyimpan setpoint terakhir tanpa batas waktu; kalau browser dashboard mati di tengah perintah gerak, drone terus melaju. |
| 4 | **`/dashboard/state` diterbitkan periodik 2 Hz** | Versi Android hanya menerbitkannya saat ACK, sehingga panel Journey Status tidak pernah bergerak selama terbang. |
| 5 | **`gpsValid` dilaporkan apa adanya** (≥ 6 satelit) | Versi Android hardcode `true`, sehingga posisi tanpa fix diperlakukan sebagai lokasi nyata dan waypoint tetap diterima. |
| 6 | **Tegangan dibagi 1000 (mV → V)** | `DJIBatteryState.voltage` bersatuan milivolt; versi Android meneruskannya apa adanya sehingga dashboard menampilkan ~11400 V. |
| 7 | **`vx`/`vy` memakai sumbu yang sama dengan `x`/`y` (ENU), `vz` positif ke atas** | Versi Android mencampur: `x`=timur/`y`=utara tapi `vx`=utara/`vy`=timur, dan `vz` positif ke bawah — berlawanan dengan `linear.z` pada `/cmd_vel`. Tidak terlihat di dashboard, tapi menghasilkan grafik yang salah untuk laporan. |
| 8 | **Foto ditulis ke disk hanya setelah unduhan lengkap** | DJI iOS mengalirkan berkas sebagai potongan `Data` (Android menyerahkan penulisan ke SDK). Kalau ditulis bertahap lalu unduhan putus, tersisa berkas separuh berukuran > 0 yang dianggap "sudah lengkap" pada sinkronisasi berikutnya, lalu ikut terkirim dan menggagalkan stitching. |
| 9 | **Tombol "Unggah Ulang Tanpa Drone"** | Sisi Android sudah punya `uploadStoredPhotos()` tetapi tidak pernah dipasang di UI. Berguna saat foto sudah ada di HP tapi laptop belum siap — tidak perlu menyalakan drone lagi. |
| 10 | **`/cmd_vel` diperlakukan sebagai vektor TERNORMALISASI, lalu dikalikan manual_speed / vertical_speed / yaw_rate** | Ini kontrak `/cmd_vel` yang sesungguhnya: `publish_velocity_setpoint()` di `dashboard_bridge_node_px4.py` menjepit tiap sumbu ke ±1 lalu mengalikannya, dan dashboard hanya pernah mengirim ±1/±0,5. Versi Android memakai angka itu apa adanya sebagai m/s dan derajat/detik, sehingga di drone asli "W" berarti 1 m/s dan **"Q" berarti 0,5 derajat/detik** — satu putaran penuh 12 menit, tak bisa dibedakan dari drone yang diam. |
| 11 | **Virtual Stick dinyalakan ulang otomatis** | Versi Android maupun versi iOS sebelumnya hanya menyalakannya sekali saat Connect. Setelah `productDisconnected()` memadamkan flagnya, tidak ada apa pun yang menghidupkannya lagi: seluruh perintah dashboard dibuang diam-diam sampai operator menekan Disconnect→Connect manual. |
| 12 | **Goal lebih dekat dari 5 m ditolak** | Radius terima 2 m + galat GPS Spark (±1,5-3 m) membuat target sedekat itu langsung dinyatakan TERCAPAI pada tick pertama: drone tidak bergerak, tapi dashboard mencatat misi SUKSES. |
| 13 | **Kewenangan kendali diterbitkan sebagai `controlReady`** | Sebelumnya hilangnya kewenangan hanya terlihat di layar HP. Dashboard sekarang menampilkan badge `NO CONTROL` + alasannya, dan menerima event `control_lost`/`control_ready`. |

Butir 5, 6, 7, dan 10 **mengubah angka yang muncul di dashboard/laporan**
dibanding app Android. Butir 10 yang paling besar dampaknya pada data terbang:
kecepatan manual naik dari 1 m/s menjadi 3 m/s dan laju yaw dari 0,5 menjadi
25 derajat/detik, jadi rekaman manual SEBELUM dan SESUDAH perubahan ini tidak
bisa dicampur dalam satu tabel tanpa keterangan. Kalau data lama harus tetap sebanding, butir-butir itu
mudah dikembalikan — semuanya terpusat di satu tempat di kode.

---

## Struktur

```
DroneStackBridge-iOS/
├── Podfile                     DJI-SDK-iOS 4.16.2
├── project.yml                 spesifikasi XcodeGen (opsional)
├── Tools/contract-check/       uji kecocokan kontrak (Node)
└── DroneStackBridge/
    ├── Info.plist              App Key, izin Local Network, ATS
    ├── DroneStackBridgeApp.swift
    ├── ContentView.swift       satu layar status + tombol
    ├── Bridge/
    │   ├── BridgeCoordinator.swift   perekat UI ↔ SDK ↔ jembatan
    │   ├── BridgeSettings.swift      IP/port tersimpan (9090 + 8000)
    │   ├── DJIFlightLink.swift       DJI SDK untuk KENDALI TERBANG
    │   ├── RosBridgeClient.swift     inti jembatan (port dari Java)
    │   ├── RosBridgeProtocol.swift   pembentuk pesan rosbridge
    │   └── RosBridgeSocket.swift     WebSocket (URLSessionWebSocketTask)
    ├── Photo/
    │   ├── MediaSyncManager.swift    kartu SD drone → iPhone (DJI MediaManager)
    │   ├── PhotoBatchUploader.swift  iPhone → POST /jobs/stitch (multipart)
    │   └── PhotoPipelineBridge.swift perangkai keduanya, callback ke main thread
    └── Support/
        └── Geo.swift                 konversi geodetik + rotasi ke kerangka badan
```

### Padanan berkas dengan sisi Android

| Android | iOS |
|---|---|
| `bridge/RosBridgeClient.java` | `Bridge/RosBridgeClient.swift` + `RosBridgeSocket` + `RosBridgeProtocol` + `DJIFlightLink` |
| `bridge/MediaSyncManager.java` | `Photo/MediaSyncManager.swift` |
| `bridge/PhotoBatchUploader.java` | `Photo/PhotoBatchUploader.swift` |
| `bridge/PhotoPipelineBridge.java` | `Photo/PhotoPipelineBridge.swift` |
| `demo/flightcontroller/VirtualStickView.java` (dialog IP + tombol Sync Foto) | `ContentView.swift` + `BridgeCoordinator.swift` |
| `AndroidManifest.xml` → `usesCleartextTraffic` | `Info.plist` → `NSAppTransportSecurity` |

## Keselamatan

- Selama jembatan aktif, dashboard mengendalikan drone lewat virtual stick.
  **Pegang terus remote fisik** — tombol pause/RTH di remote adalah cara
  tercepat mengambil alih.
- Kalau WebSocket putus **saat app sedang mengendalikan penerbangan**, app
  memicu **Return-To-Home** otomatis. Failsafe bawaan DJI belum tentu terpicu:
  dari sudut pandang pesawat tidak ada "RC yang hilang", datanya hanya berhenti
  datang.
- Layar iPhone dijaga tetap menyala selama jembatan aktif. Kalau layar terkunci,
  app masuk background dan pengiriman virtual stick berhenti.
- Uji pertama sebaiknya di **lapangan terbuka dengan fix GPS baik**. Fitur
  waypoint memerlukan fix GPS; di dalam ruangan app akan menolak waypoint
  dengan alasan yang tampil di dashboard, bukan terbang ke arah asal.
