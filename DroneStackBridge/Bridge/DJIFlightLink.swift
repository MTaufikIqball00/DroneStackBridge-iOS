//
//  DJIFlightLink.swift
//  DroneStackBridge
//
//  Satu-satunya berkas yang menyentuh DJI SDK untuk KENDALI TERBANG.
//  (Jalur foto punya pintunya sendiri di Photo/MediaSyncManager.swift, yang
//  bicara ke kamera & MediaManager — dua bagian SDK yang tidak saling bergantung.)
//
//  Semua kode jembatan lain (RosBridgeClient) bicara ke DJI HANYA lewat kelas
//  ini. Pemisahan itu disengaja: kontrak dashboard dan API DJI berubah karena
//  alasan yang sama sekali berbeda, dan mencampurnya membuat setiap perubahan
//  SDK berisiko diam-diam mengubah format JSON yang dilihat dashboard.
//
//  Padanan di sisi Android: bagian registerKeyListeners() + controlTick() pada
//  RosBridgeClient.java. Bedanya, di iOS telemetry datang lewat SATU delegate
//  (DJIFlightControllerDelegate) yang mengirim seluruh state sekaligus ~10Hz,
//  jadi tidak perlu 12 KeyListener terpisah seperti di Android.
//

import CoreLocation
import Foundation
import DJISDK

/// Potret telemetry terakhir dari pesawat.
///
/// Konvensi sumbu: **ENU** (x = timur, y = utara, z = atas) di seluruh struct
/// ini. DJI sendiri memakai NED (velocityX = utara, velocityY = timur,
/// velocityZ = ke BAWAH); konversinya dilakukan sekali di satu tempat
/// (`apply(state:)`) supaya tidak ada bagian lain yang perlu mengingat
/// perbedaan itu.
struct FlightSnapshot {
    var latitude: Double?
    var longitude: Double?
    /// Meter relatif titik takeoff (bukan MSL).
    var altitude: Double = 0
    /// m/s ke timur.
    var velocityEast: Double = 0
    /// m/s ke utara.
    var velocityNorth: Double = 0
    /// m/s ke ATAS (sudah dibalik dari NED milik DJI).
    var velocityUp: Double = 0
    /// Derajat, 0 = utara, positif searah jarum jam.
    var yawDegrees: Double = 0
    /// Derajat kompas 0..360.
    var headingDegrees: Double = 0
    var batteryPercent: Int?
    var voltageVolts: Double?
    var areMotorsOn: Bool = false
    var isFlying: Bool = false
    var flightModeString: String = "UNKNOWN"
    var satelliteCount: Int = 0
    /// Ada data state yang pernah masuk sama sekali.
    var hasReceivedState: Bool = false
    /// Kapan state terakhir diterima. nil = belum pernah sama sekali.
    var stateReceivedAt: Date?

    /// Apakah data ini cukup baru untuk dijadikan dasar keputusan KONTROL.
    ///
    /// "Pernah menerima data" saja tidak cukup, dan nilai default struct ini
    /// justru berbahaya: `altitude = 0` tidak bisa dibedakan dari pembacaan
    /// sungguhan "drone di tanah". Loop kontrol yang membacanya sebelum
    /// telemetry mengalir akan menyimpulkan drone masih di bawah target lalu
    /// memerintahkan naik — terus-menerus, karena angkanya tidak pernah
    /// berubah. Nilai basi punya akibat yang sama untuk alasan berbeda:
    /// keputusan diambil dari keadaan yang sudah lewat.
    func isFresh(maxAge: TimeInterval) -> Bool {
        guard hasReceivedState, let at = stateReceivedAt else { return false }
        return Date().timeIntervalSince(at) <= maxAge
    }

    /// Fix GPS cukup baik untuk dipercaya sebagai koordinat bumi sungguhan.
    ///
    /// BERBEDA dari sisi Android, yang mengirim `gpsValid: true` secara HARDCODE
    /// (lihat publishTelemetryNow() di RosBridgeClient.java). Hardcode itu
    /// membuat dashboard memperlakukan posisi tanpa fix sebagai lokasi nyata,
    /// dan — lebih berbahaya — membuat waypoint GPS tetap diterima saat drone
    /// sebenarnya tidak tahu di mana ia berada.
    ///
    /// Ambang 6 satelit adalah nilai yang lazim dipakai sebagai syarat mode
    /// P-GPS. Ubah di sini kalau uji lapangan menunjukkan angka lain.
    var gpsValid: Bool {
        satelliteCount >= 6 && Geo.isValidLatLon(latitude, longitude)
    }
}

protocol DJIFlightLinkDelegate: AnyObject {
    /// Pesan untuk ditampilkan di UI dan log.
    func flightLink(_ link: DJIFlightLink, didLog message: String)
    /// Pesawat tersambung/terputus, atau registrasi SDK selesai.
    func flightLinkDidChangeAvailability(_ link: DJIFlightLink)
}

final class DJIFlightLink: NSObject {

    weak var delegate: DJIFlightLinkDelegate?

    private(set) var isRegistered = false
    private(set) var isProductConnected = false
    private(set) var productModel: String = "-"
    private(set) var isVirtualStickEnabled = false

    /// Status ketersediaan virtual stick yang terakhir DICATAT. Dipakai agar
    /// perubahannya dilaporkan sekali, bukan 10 kali per detik oleh loop kontrol.
    /// `true` sebagai nilai awal supaya ketidaktersediaan pertama tetap terlaporkan.
    private var lastVirtualStickAvailable = true

    private var flightController: DJIFlightController? {
        (DJISDKManager.product() as? DJIAircraft)?.flightController
    }

    /// Snapshot ditulis dari delegate DJI (utas utama) dan dibaca dari antrean
    /// jembatan (utas lain) 5-10x per detik. NSLock sudah lebih dari cukup untuk
    /// beban seringan ini, dan jauh lebih mudah dibuktikan benar daripada
    /// mekanisme bebas-kunci.
    private let lock = NSLock()
    private var snapshot = FlightSnapshot()

    /// Origin lokal untuk x/y dalam meter, dikunci dari fix GPS valid PERTAMA.
    /// Pola yang sama dipakai node PX4/ArduPilot (ref_lat/ref_lon di geodesy.py)
    /// dan sisi Android, supaya arti "x = 0, y = 0" identik di ketiga stack.
    private var originLat: Double?
    private var originLon: Double?

    /// Status tombol shutter RC pada callback SEBELUMNYA — dipakai untuk
    /// deteksi TEPI (rising edge).
    ///
    /// Callback `didUpdateHardwareState` berdenyut terus (~10Hz) selama RC
    /// tersambung, dan `isClicked` bernilai true SELAMA tombol ditahan — bukan
    /// sekali per tekan. Tanpa membandingkan dengan status sebelumnya, satu
    /// tekanan singkat akan memicu belasan `startShootPhoto()` beruntun.
    ///
    /// Diakses dari delegate RC yang tiba di thread utama, jadi tidak dikunci.
    private var wasShutterClicked = false

    // MARK: - Registrasi SDK

    func registerWithSDK() {
        let appKey = Bundle.main.object(forInfoDictionaryKey: SDK_APP_KEY_INFO_PLIST_KEY) as? String
        guard let appKey = appKey, !appKey.isEmpty else {
            log("App Key belum diisi di Info.plist (kunci DJISDKAppKey).")
            return
        }
        log("Mendaftarkan App Key ke server DJI...")
        DJISDKManager.registerApp(with: self)
    }

    // MARK: - Akses telemetry

    func currentSnapshot() -> FlightSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    /// Offset lokal (meter, ENU) terhadap origin yang dikunci saat fix pertama.
    /// Mengembalikan (0,0) selama origin belum pernah didapat — sama seperti
    /// perilaku sisi Android.
    func localOffset(for snapshot: FlightSnapshot) -> (x: Double, y: Double) {
        lock.lock()
        let origin = (lat: originLat, lon: originLon)
        lock.unlock()

        guard let originLat = origin.lat,
              let originLon = origin.lon,
              let lat = snapshot.latitude,
              let lon = snapshot.longitude
        else { return (0, 0) }

        let offset = Geo.localOffsetMeters(
            fromLat: originLat, fromLon: originLon, toLat: lat, toLon: lon
        )
        return (x: offset.east, y: offset.north)
    }

    // MARK: - Konfigurasi virtual stick

    /// Menyalakan virtual stick DAN menetapkan seluruh mode kontrolnya.
    ///
    /// PENTING — dan inilah alasan fungsi ini dipanggil ulang setiap kali
    /// pesawat tersambung, bukan sekali saja: dokumentasi resmi DJI menyatakan
    /// `rollPitchControlMode`, `yawControlMode`, `rollPitchCoordinateSystem`,
    /// dan `isVirtualStickAdvancedModeEnabled` SEMUANYA DIRESET ke nilai default
    /// begitu flight controller tersambung ulang. Default `rollPitchControlMode`
    /// adalah *Angle*, bukan *Velocity* — jadi setelah sambung-ulang, nilai
    /// "3.0" yang kita maksud sebagai 3 m/s akan ditafsirkan sebagai sudut
    /// miring 3 derajat. Drone tidak berhenti, ia hanya bergerak dengan aturan
    /// yang sama sekali lain dari yang diasumsikan kode ini.
    func enableVirtualStick(completion: @escaping (Bool, String) -> Void) {
        guard let fc = flightController else {
            completion(false, "FlightController drone tidak tersedia.")
            return
        }

        fc.rollPitchControlMode = .velocity
        fc.verticalControlMode = .velocity
        fc.yawControlMode = .angularVelocity
        // BODY: sumbu X = arah hidung, sumbu Y = kanan pesawat. Dipilih (sama
        // seperti sisi Android) supaya kontrol manual WASD dari dashboard terasa
        // alami — "maju" selalu berarti maju menurut hidung drone, bukan menurut
        // arah utara. Navigasi waypoint yang bekerja dalam kerangka bumi
        // dikonversi ke kerangka badan lebih dulu; lihat Geo.groundToBody().
        fc.rollPitchCoordinateSystem = .body

        fc.setVirtualStickModeEnabled(true) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.isVirtualStickEnabled = false
                completion(false, "Gagal mengaktifkan Virtual Stick: \(error.localizedDescription)")
                return
            }
            // Mode lanjutan membuat drone mengompensasi angin saat hover
            // (syarat: sinyal GPS baik). Disetel SETELAH virtual stick menyala,
            // mengikuti urutan yang dipakai sisi Android.
            fc.isVirtualStickAdvancedModeEnabled = true
            self.isVirtualStickEnabled = true
            completion(true, "Virtual Stick aktif (velocity / body frame).")
        }
    }

    func disableVirtualStick() {
        isVirtualStickEnabled = false
        flightController?.setVirtualStickModeEnabled(false, withCompletion: nil)
    }

    // MARK: - Perintah terbang

    /// Kirim satu paket kontrol virtual stick.
    ///
    /// - Parameters:
    ///   - forward: m/s ke arah hidung pesawat (sumbu X kerangka badan).
    ///   - right: m/s ke kanan pesawat (sumbu Y kerangka badan).
    ///   - yawRate: derajat/detik, positif searah jarum jam.
    ///   - verticalRate: m/s, positif ke ATAS.
    ///
    /// PEMETAAN YANG MUDAH SALAH: pada DJI SDK, field `roll` mengendalikan sumbu
    /// X dan field `pitch` mengendalikan sumbu Y — kebalikan dari dugaan
    /// kebanyakan orang bahwa "pitch = maju". Sample resmi DJI menegaskannya:
    /// "In rollPitchVelocity mode, the pitch property represents the Y direction
    /// velocity. The roll property represents the X direction velocity."
    /// (FCVirtualStickViewController.m). Karena itu forward -> roll, right ->
    /// pitch. Sisi Android mencapai hasil yang sama dengan cara berbeda: ia
    /// menukar urutan argumen di constructor FlightControlData.
    func sendControl(forward: Double, right: Double, yawRate: Double, verticalRate: Double) {
        guard let fc = flightController, isVirtualStickEnabled else { return }

        // KETERSEDIAAN VIRTUAL STICK TIDAK LAGI MEMBLOKIR PENGIRIMAN.
        //
        // Versi sebelumnya: `guard fc.isVirtualStickControlModeAvailable() else
        // { return }` — perintah dibuang DIAM-DIAM, tanpa log maupun pesan ke
        // operator. Gejala di lapangan: WASD ditekan, drone diam, dan tidak ada
        // satu pun petunjuk kenapa. Sisi Android tidak punya penjaga ini sama
        // sekali (lihat sendVirtualStickFlightControlData di RosBridgeClient.java),
        // dan justru itulah sebabnya Android terasa lancar pada kondisi yang
        // membuat iOS tampak mati total.
        //
        // Perintah sekarang TETAP dikirim. Kalau SDK memang menolaknya, itu
        // urusan SDK — bukan alasan bagi jembatan ini untuk membisu. Statusnya
        // hanya dicatat, dan hanya saat BERUBAH, supaya loop 10 Hz tidak
        // membanjiri log.
        //
        // METODE, bukan properti — di ObjC ini `-isVirtualStickControlModeAvailable`
        // yang diimpor Swift sebagai fungsi, jadi tanda kurungnya wajib.
        let available = fc.isVirtualStickControlModeAvailable()
        if available != lastVirtualStickAvailable {
            lastVirtualStickAvailable = available
            log(available
                ? "Virtual stick tersedia kembali — perintah kendali berlaku lagi."
                : "SDK melaporkan virtual stick TIDAK tersedia. Perintah tetap dikirim, "
                + "tetapi drone mungkin mengabaikannya. Periksa sakelar mode di remote "
                + "(harus P) dan pastikan remote tidak sedang mengambil alih kendali.")
        }

        let data = DJIVirtualStickFlightControlData(
            pitch: Float(right),
            roll: Float(forward),
            yaw: Float(yawRate),
            verticalThrottle: Float(verticalRate)
        )
        // Catatan bila compiler mengeluh soal nama metode: importer Swift
        // memendekkan `-sendVirtualStickFlightControlData:withCompletion:`
        // menjadi `send(_:withCompletion:)`. Pada versi SDK yang tidak
        // memendekkannya, ganti baris ini menjadi
        // `fc.sendVirtualStickFlightControlData(data, withCompletion: nil)`.
        fc.send(data, withCompletion: nil)
    }

    func startTakeoff(completion: @escaping (Bool, String) -> Void) {
        guard let fc = flightController else {
            completion(false, "FlightController tidak tersedia.")
            return
        }
        fc.startTakeoff { error in
            if let error = error {
                completion(false, "Takeoff gagal: \(error.localizedDescription)")
            } else {
                completion(true, "Takeoff dimulai.")
            }
        }
    }

    func startLanding(completion: @escaping (Bool, String) -> Void) {
        guard let fc = flightController else {
            completion(false, "FlightController tidak tersedia.")
            return
        }
        fc.startLanding { error in
            if let error = error {
                completion(false, "Land gagal: \(error.localizedDescription)")
            } else {
                completion(true, "Landing dimulai.")
            }
        }
    }

    /// Ambil satu foto.
    ///
    /// Dipanggil dari tombol shutter fisik RC (lihat DJIRemoteControllerDelegate
    /// di bawah) maupun tombol "Ambil Foto" di layar app.
    ///
    /// KENAPA APP HARUS IKUT CAMPUR SAMA SEKALI: selama app kustom ini yang
    /// memegang sesi SDK (menggantikan DJI GO 4), tombol RC hanya mengirimkan
    /// PERUBAHAN STATUS ke app — bukan langsung memerintah kamera. Kalau tidak
    /// ada yang mendengarkan dan menerjemahkannya jadi `startShootPhoto()`,
    /// menekan shutter tidak berefek apa pun.
    func capturePhoto(completion: ((Bool, String) -> Void)? = nil) {
        guard let camera = currentCamera() else {
            let message = "Kamera drone tidak tersedia."
            log(message)
            completion?(false, message)
            return
        }
        // Selama sinkronisasi berjalan kamera dipindah ke mode unduh dan TIDAK
        // bisa memotret. Dicegat di sini supaya pesannya menjelaskan sebabnya,
        // bukan sekadar galat mentah dari SDK.
        guard !MediaSyncManager.isSyncInProgress else {
            let message = "Sedang sinkronisasi foto — kamera di mode unduh, pemotretan dilewati."
            log(message)
            completion?(false, message)
            return
        }

        camera.startShootPhoto { [weak self] error in
            if let error = error {
                // Sebab paling umum: kamera belum berada di mode ShootPhoto
                // (prasyarat yang disebut dokumentasi `startShootPhoto`), mis.
                // masih tertinggal di mode unduh dari sinkronisasi sebelumnya
                // yang gagal di tengah.
                let message = "Gagal memotret: \(error.localizedDescription)"
                self?.log(message)
                completion?(false, message)
            } else {
                let message = "Foto diambil."
                self?.log(message)
                completion?(true, message)
            }
        }
    }

    func startGoHome(completion: @escaping (Bool, String) -> Void) {
        guard let fc = flightController else {
            completion(false, "FlightController tidak tersedia.")
            return
        }
        fc.startGoHome { error in
            if let error = error {
                completion(false, "RTH gagal: \(error.localizedDescription)")
            } else {
                completion(true, "Return-To-Home dimulai.")
            }
        }
    }

    // MARK: - Internal

    private func log(_ message: String) {
        NSLog("[DJIFlightLink] %@", message)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.flightLink(self, didLog: message)
        }
    }

    private func notifyAvailabilityChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.flightLinkDidChangeAvailability(self)
        }
    }

    private func currentCamera() -> DJICamera? {
        (DJISDKManager.product() as? DJIAircraft)?.camera
    }

    private func attachComponentDelegates() {
        guard let aircraft = DJISDKManager.product() as? DJIAircraft else { return }
        aircraft.flightController?.delegate = self
        aircraft.battery?.delegate = self
        aircraft.remoteController?.delegate = self
    }

    private func detachComponentDelegates() {
        guard let aircraft = DJISDKManager.product() as? DJIAircraft else { return }
        if aircraft.remoteController?.delegate === self {
            aircraft.remoteController?.delegate = nil
        }
        if aircraft.flightController?.delegate === self {
            aircraft.flightController?.delegate = nil
        }
        if aircraft.battery?.delegate === self {
            aircraft.battery?.delegate = nil
        }
    }
}

// MARK: - DJISDKManagerDelegate

extension DJIFlightLink: DJISDKManagerDelegate {

    func appRegisteredWithError(_ error: Error?) {
        if let error = error {
            isRegistered = false
            log("Registrasi SDK GAGAL: \(error.localizedDescription)")
            notifyAvailabilityChanged()
            return
        }
        isRegistered = true
        log("Registrasi SDK berhasil. Menyambung ke produk...")
        DJISDKManager.startConnectionToProduct()
        notifyAvailabilityChanged()
    }

    func didUpdateDatabaseDownloadProgress(_ progress: Progress) {
        // Basis data FlySafe/GEO. Tidak menghalangi penerbangan, jadi cukup
        // dicatat tanpa mengganggu UI.
        NSLog("[DJIFlightLink] Unduh basis data FlySafe: %lld/%lld",
              progress.completedUnitCount, progress.totalUnitCount)
    }

    func productConnected(_ product: DJIBaseProduct?) {
        isProductConnected = product != nil
        productModel = product?.model ?? "-"
        log("Produk tersambung: \(productModel)")
        attachComponentDelegates()
        notifyAvailabilityChanged()
    }

    func productDisconnected() {
        isProductConnected = false
        isVirtualStickEnabled = false
        productModel = "-"
        log("Produk terputus.")
        detachComponentDelegates()
        notifyAvailabilityChanged()
    }

    func componentConnected(withKey key: String?, andIndex index: Int) {
        // Flight controller bisa muncul BELAKANGAN setelah produk tersambung.
        // Tanpa memasang ulang delegate di sini, telemetry tidak pernah mengalir
        // pada urutan sambung tertentu.
        attachComponentDelegates()
        notifyAvailabilityChanged()
    }

    func componentDisconnected(withKey key: String?, andIndex index: Int) {
        notifyAvailabilityChanged()
    }
}

// MARK: - DJIFlightControllerDelegate

extension DJIFlightLink: DJIFlightControllerDelegate {

    func flightController(_ fc: DJIFlightController, didUpdate state: DJIFlightControllerState) {
        var updated = FlightSnapshot()

        if let location = state.aircraftLocation,
           Geo.isValidLatLon(location.coordinate.latitude, location.coordinate.longitude) {
            updated.latitude = location.coordinate.latitude
            updated.longitude = location.coordinate.longitude
        }

        // `Double(...)` dipakai eksplisit karena beberapa properti ini bertipe
        // float dan sebagian double tergantung versi SDK; konversi eksplisit
        // membuat kode ini tidak peduli yang mana.
        updated.altitude = Double(state.altitude)

        // DJI memakai NED: velocityX = utara, velocityY = timur, velocityZ = ke
        // BAWAH. Struct ini memakai ENU, jadi sumbu ditukar dan velocityZ
        // dibalik tandanya TEPAT DI SINI — satu-satunya tempat konversi terjadi.
        updated.velocityNorth = Double(state.velocityX)
        updated.velocityEast = Double(state.velocityY)
        updated.velocityUp = -Double(state.velocityZ)

        updated.yawDegrees = Double(state.attitude.yaw)
        // Kompas 0..360 supaya HUD dashboard tidak pernah menerima nilai negatif.
        updated.headingDegrees = (updated.yawDegrees.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)

        updated.areMotorsOn = state.areMotorsOn
        updated.isFlying = state.isFlying
        updated.flightModeString = state.flightModeString ?? "UNKNOWN"
        updated.satelliteCount = Int(state.satelliteCount)
        updated.hasReceivedState = true
        updated.stateReceivedAt = Date()

        lock.lock()
        // Baterai datang dari delegate LAIN dengan irama sendiri — nilainya
        // dibawa dari snapshot sebelumnya, kalau tidak setiap update flight
        // controller akan menghapusnya dan dashboard melihat baterai berkedip
        // antara ada dan tidak ada.
        updated.batteryPercent = snapshot.batteryPercent
        updated.voltageVolts = snapshot.voltageVolts
        snapshot = updated

        if originLat == nil,
           let lat = updated.latitude,
           let lon = updated.longitude,
           updated.gpsValid {
            originLat = lat
            originLon = lon
            NSLog("[DJIFlightLink] Origin lokal ditetapkan: %f, %f", lat, lon)
        }
        lock.unlock()
    }
}

// MARK: - DJIRemoteControllerDelegate

extension DJIFlightLink: DJIRemoteControllerDelegate {

    /// Tombol shutter fisik di RC.
    ///
    /// Callback ini berdenyut terus selama RC tersambung dan membawa SELURUH
    /// status perangkat keras (stik, sakelar, semua tombol), jadi yang dilakukan
    /// di sini harus murah. Hanya transisi tidak-ditekan -> ditekan yang
    /// diteruskan; lihat `wasShutterClicked`.
    /// Nama Swift-nya `remoteController(_:didUpdate:)`, BUKAN
    /// `remoteController(_:didUpdateHardwareState:)` seperti di header ObjC —
    /// importer memendekkan labelnya karena tipe parameter sudah menyebut
    /// "HardwareState". Pola yang sama seperti `fetchData(withOffset:update:...)`
    /// di MediaSyncManager.
    func remoteController(
        _ rc: DJIRemoteController,
        didUpdate state: DJIRCHardwareState
    ) {
        let shutter = state.shutterButton
        // Anggota struct C bertipe BOOL diimpor Swift sebagai `ObjCBool`, bukan
        // `Bool` — jadi harus lewat `.boolValue` sebelum bisa dipakai sebagai
        // kondisi. (Berbeda dari properti kelas ObjC seperti `state.areMotorsOn`
        // yang otomatis jadi `Bool` biasa.)
        //
        // `isPresent` false berarti model RC ini memang tidak punya tombol
        // tersebut — bukan berarti sedang tidak ditekan.
        guard shutter.isPresent.boolValue else { return }

        let clicked = shutter.isClicked.boolValue
        defer { wasShutterClicked = clicked }
        guard clicked, !wasShutterClicked else { return }

        capturePhoto()
    }
}

// MARK: - DJIBatteryDelegate

extension DJIFlightLink: DJIBatteryDelegate {

    func battery(_ battery: DJIBattery, didUpdate state: DJIBatteryState) {
        lock.lock()
        snapshot.batteryPercent = Int(state.chargeRemainingInPercent)
        // DJIBatteryState.voltage bersatuan MILIVOLT. Sisi Android meneruskan
        // nilai ini apa adanya, sehingga dashboard menampilkan tegangan seperti
        // "11400 V" alih-alih "11.4 V" (lihat lastVoltage di
        // RosBridgeClient.java). Dibagi 1000 di sini.
        //
        // Cek saat uji pertama: baterai Spark 3S sehat harus terbaca 11-12.6 V.
        // Kalau yang muncul justru angka ribuan, berarti asumsi satuan ini salah
        // untuk firmware Anda dan pembagi di bawah harus dihapus.
        snapshot.voltageVolts = Double(state.voltage) / 1000.0
        lock.unlock()
    }
}
