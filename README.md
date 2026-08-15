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

1. **Laptop:** `./scripts/start.sh --dji` — skrip mencetak IP yang harus diisi
2. **iPhone:** sambungkan ke remote Spark (kabel USB), tunggu status
   *Drone tersambung* hijau
3. Isi **IP laptop** + port `9090`, tekan **Sambungkan Jembatan**
4. **Dashboard** (`http://<ip-laptop>:3000`) akan langsung menampilkan telemetry
5. **Setelah misi selesai** — tekan **Sync Foto ke Backend**. Foto diunduh dari
   kartu SD drone ke iPhone, lalu diunggah sebagai satu batch; app menampilkan
   `job_id` yang bisa dipantau di `GET /jobs/{id}`.

> Sinkronisasi foto memindahkan kamera ke mode unduh, sehingga drone **tidak bisa
> memotret** selama proses berlangsung. Jalankan setelah pemotretan selesai, bukan
> sambil terbang. Tombolnya sengaja tidak menuntut jembatan rosbridge aktif —
> jalur foto hanya butuh kamera.

### Jaringan — jebakan paling sering

- **iPhone dan laptop harus berada di jaringan yang sama.** Kalau iPhone
  tersambung ke Wi-Fi Spark, Wi-Fi-nya terpakai untuk drone dan tidak bisa
  menjangkau laptop. **Sambungkan iPhone ke remote lewat kabel USB** supaya
  Wi-Fi iPhone bebas dipakai untuk LAN laptop.
- **Laptop memakai WSL2** — IP WSL2 berbeda dari IP LAN Windows dan berubah tiap
  restart. Kalau app tidak bisa connect padahal IP terlihat benar, itu penyebab
  paling mungkin. Perbaikannya: aktifkan *mirrored networking* di
  `C:\Users\<user>\.wslconfig`:
  ```ini
  [wsl2]
  networkingMode=mirrored
  ```
  lalu `wsl --shutdown`. Cek cepat di WSL: `hostname -I` dan
  `ss -tlnp | grep 9090`.
- iOS akan menampilkan prompt izin **Local Network** saat pertama menyambung.
  Harus diizinkan; kalau tertolak, WebSocket gagal tanpa pesan yang jelas.

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

Hasil terakhir: **26 pemeriksaan, 0 gagal**. Ketahanannya diuji dengan tiga
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

Butir 5, 6, dan 7 **mengubah angka yang muncul di dashboard/laporan**
dibanding app Android. Kalau data lama harus tetap sebanding, butir-butir itu
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
