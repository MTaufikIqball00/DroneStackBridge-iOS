//
//  RosBridgeClient.swift
//  DroneStackBridge
//
//  Jembatan antara DJI Spark (via DJI Mobile SDK) dan dashboard drone-stack,
//  dengan menyambung LANGSUNG ke rosbridge_server (port 9090) sebagai client.
//
//  Ini port dari RosBridgeClient.java milik app Android. Kontrak JSON-nya
//  DISAMAKAN FIELD-PER-FIELD supaya dashboard Next.js tidak perlu diubah sama
//  sekali dan tidak perlu tahu apakah ia sedang bicara dengan PX4, ArduPilot,
//  Android, atau iOS.
//
//  KENAPA TIDAK ADA NODE ROS 2 PYTHON
//  ----------------------------------
//  Pada mode `--dji` (scripts/start.sh), dashboard_bridge_node.py maupun
//  dashboard_bridge_node_px4.py TIDAK dijalankan sama sekali. Kelas inilah yang
//  menggantikan peran keduanya: menerjemahkan kontrak dashboard menjadi perintah
//  DJI dan sebaliknya. Menjalankan node Python itu bersamaan akan membuat DUA
//  service server dengan nama sama (/takeoff, /land) di ROS graph.
//
//  PERBEDAAN YANG DISENGAJA DARI VERSI ANDROID
//  -------------------------------------------
//  Semuanya ditandai dengan komentar "BEDA DARI ANDROID" di tempatnya, dan
//  diringkas di README.md. Tidak ada satu pun yang menuntut perubahan di sisi
//  dashboard.
//

import Foundation

protocol RosBridgeClientDelegate: AnyObject {
    func bridge(_ bridge: RosBridgeClient, didLog message: String)
    func bridge(_ bridge: RosBridgeClient, didChangeConnected connected: Bool)
}

final class RosBridgeClient {

    // MARK: - Konstanta (paritas dengan sisi Android)

    /// Rate publish telemetry. Delegate DJI mengirim state ~10Hz; 5Hz sudah
    /// cukup halus untuk HUD dan menyisakan bandwidth untuk kontrol. Sama dengan
    /// TELEMETRY_PERIOD_MS di sisi Android.
    private let telemetryPeriod: TimeInterval = 0.2

    /// Rate loop virtual stick. DJI mensyaratkan perintah virtual stick dikirim
    /// antara 5Hz dan 25Hz — di bawah itu pesawat menganggap koneksi kontrol
    /// putus dan hover di tempat sampai perintah berikutnya datang.
    private let controlPeriod: TimeInterval = 0.1

    /// BEDA DARI ANDROID: publikasi state periodik.
    ///
    /// Versi Android HANYA menerbitkan /dashboard/state saat ada event ACK.
    /// Akibatnya panel "Journey Status" di dashboard tidak pernah bergerak
    /// selama penerbangan — ia hanya terisi sekali saat resync. Payload state
    /// tanpa field `event` masuk ke jalur ingestState() yang memang sudah
    /// ditangani dashboard, jadi ini murni tambahan yang kompatibel.
    private let statePeriod: TimeInterval = 0.5

    private let waypointAcceptanceRadiusM = 2.0
    private let waypointCruiseSpeedMps = 3.0

    /// JARAK MINIMUM sebuah goal supaya layak diterbangkan.
    ///
    /// Target yang lebih dekat dari ini langsung lolos `distance <= radius
    /// terima` pada tick PERTAMA: jembatan menerbitkan `mission_complete`,
    /// drone tidak bergerak satu sentimeter pun, dan dashboard justru melapor
    /// misi SUKSES. Gejala itulah yang tercatat di uji terbang sebagai
    /// "Send Goal 2-10 m tidak bergerak".
    ///
    /// Menaikkan radius terima TIDAK memperbaikinya — justru memperparah,
    /// karena target dekat jadi makin gampang dianggap tercapai. Yang benar
    /// adalah menolak perintahnya secara terbuka, dengan alasan yang terbaca.
    ///
    /// Nilainya 5 m: dua kali lipat radius terima, sekaligus jauh di atas
    /// galat GPS Spark (±1,5-3 m) sehingga "sampai" berarti benar-benar sampai
    /// dan bukan sekadar derau. Angka yang sama dipakai sebagai titik akhir
    /// ramp perlambatan di controlTick (`distance / 5.0`).
    private let minGoalDistanceM = 5.0

    /// PENGALI PERINTAH MANUAL — padanan manual_speed / vertical_speed /
    /// yaw_rate pada ros2_ws/.../launch/dashboard_bridge.launch.py.
    ///
    /// Dashboard mengirim /cmd_vel sebagai vektor TERNORMALISASI (lihat
    /// handleCmdVel), jadi angka-angka inilah yang menentukan seberapa cepat
    /// drone asli bergerak saat WASD ditekan. Turunkan di sini — dan hanya di
    /// sini — bila terasa terlalu agresif untuk lokasi uji yang sempit.
    private let manualSpeedMps = 3.0
    private let manualVerticalSpeedMps = 3.0
    /// 0,9 rad/detik pada launch file ROS = 51,6 derajat/detik. Dibulatkan ke
    /// 50 supaya angkanya mudah dibaca di laporan.
    private let manualYawRateDegPerSec = 50.0

    private let climbToleranceM = 0.3
    private let climbFastRateMps = 2.0
    private let climbSlowRateMps = 0.5
    private let minTakeoffAltitudeM = 1.0
    private let maxTakeoffAltitudeM = 50.0

    /// Umur maksimum telemetry yang masih boleh dipakai mengambil keputusan
    /// KONTROL (auto-climb & navigasi waypoint).
    ///
    /// Dipilih 1 detik: loop kontrol berjalan 10x per detik, jadi ambang ini
    /// menoleransi ~10 pembaruan yang hilang berturut-turut sebelum menyerah —
    /// cukup longgar untuk riak WiFi biasa, tapi jauh lebih pendek daripada
    /// waktu yang dibutuhkan drone untuk melenceng jauh pada 2 m/s.
    private let telemetryFreshnessTimeout: TimeInterval = 1.0

    /// Berapa lama auto-climb boleh menunggu telemetry pulih sebelum menyerah
    /// dan mengembalikan kendali ke operator.
    private let climbStaleAbortSeconds: TimeInterval = 3.0

    /// BEDA DARI ANDROID: batas kedaluwarsa perintah manual.
    ///
    /// Versi Android menyimpan nilai /cmd_vel terakhir tanpa batas waktu. Selama
    /// socket app<->rosbridge tetap hidup, perintah itu terus diterapkan 10x per
    /// detik — jadi kalau BROWSER dashboard yang mati/di-refresh di tengah
    /// perintah gerak (socket app sendiri tidak putus, sehingga failsafe RTH
    /// tidak terpicu), drone terus melaju dengan setpoint terakhir tanpa ada
    /// yang mengirim nol. Dashboard mengirim /cmd_vel pada 10Hz selama tombol
    /// ditahan, jadi ambang 1 detik tidak pernah menyentuh pemakaian normal.
    private let manualCommandTimeout: TimeInterval = 1.0

    // MARK: - Kolaborator

    weak var delegate: RosBridgeClientDelegate?
    private let flightLink: DJIFlightLink
    private let socket: RosBridgeSocket

    /// SELURUH state di bawah hanya boleh disentuh di antrean ini.
    private let queue = DispatchQueue(label: "com.dronestack.bridge")

    /// Antrean TERPISAH khusus lalu lintas WebSocket.
    ///
    /// Dulu socket berbagi `queue` dengan ketiga timer (kontrol 10 Hz,
    /// telemetry 5 Hz, state 2 Hz). Karena antrean itu serial, setiap pesan
    /// masuk maupun balasan keluar harus MENGANTRE di belakang pekerjaan timer —
    /// termasuk panggilan DJI SDK di loop kontrol yang bisa melambat sewaktu
    /// kanal radio sibuk. Akibatnya balasan `service_response` untuk /takeoff
    /// dan /land kerap lewat dari batas 5 detik dashboard, sehingga muncul
    /// "menunggu ACK" padahal perintahnya sendiri berhasil.
    ///
    /// Sisi Android tidak pernah mengalaminya karena di sana tiap `Timer` punya
    /// thread sendiri dan java-websocket punya thread pembaca sendiri — jalur
    /// jaringan tidak pernah bergantung pada selesainya loop kontrol.
    private let socketQueue = DispatchQueue(label: "com.dronestack.bridge.socket")

    // MARK: - State jembatan

    private var isRunning = false
    private var telemetryTimer: DispatchSourceTimer?
    private var controlTimer: DispatchSourceTimer?
    private var stateTimer: DispatchSourceTimer?

    /// true selama virtual stick benar-benar MENGENDALIKAN penerbangan (bukan
    /// sekadar menganggur di darat). Dipakai failsafe untuk memutuskan apakah
    /// link yang putus harus memicu Return-To-Home.
    private var isControllingFlight = false

    // Perintah manual terakhir dari /cmd_vel.
    private var cmdForward: Double = 0
    private var cmdRight: Double = 0
    private var cmdYawRate: Double = 0
    private var cmdVertical: Double = 0
    private var lastCmdVelAt: Date?

    /// Kewenangan kendali yang TERAKHIR dilaporkan ke dashboard, dengan
    /// histeresis (lihat `controlLossReportDelay`). Dipakai oleh field
    /// `controlReady` di telemetry juga, supaya badge di dashboard tidak
    /// berkedip 5x per detik mengikuti nilai mentahnya.
    private var lastReportedControlReady: Bool?
    private var controlNotReadySince: Date?

    /// Berapa lama kewenangan harus hilang TERUS-MENERUS sebelum dilaporkan.
    ///
    /// `isVirtualStickControlModeAvailable()` juga bernilai false selama
    /// operator menyentuh stik RC — hal yang normal dan berlangsung sekejap.
    /// Tanpa jeda ini, setiap koreksi kecil dari remote akan memuntahkan
    /// sepasang event ke dashboard.
    private let controlLossReportDelay: TimeInterval = 1.5

    // Auto-climb setelah takeoff.
    private var targetAltitudeM = 1.0
    private var climbInProgress = false
    /// Sejak kapan auto-climb berjalan tanpa telemetry segar; nil bila normal.
    private var staleClimbStartedAt: Date?

    // Waypoint aktif.
    private var targetLat: Double?
    private var targetLon: Double?
    private var waypointSeq = 0

    init(flightLink: DJIFlightLink) {
        self.flightLink = flightLink
        self.socket = RosBridgeSocket(queue: socketQueue)
        self.socket.delegate = self
    }

    // MARK: - Lifecycle

    func start(host: String, port: Int) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isRunning else {
                self.log("Jembatan sudah berjalan.")
                return
            }
            self.log("Menyambung ke rosbridge ws://\(host):\(port) ...")
            self.socket.connect(host: host, port: port)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.isRunning = false
            self.isControllingFlight = false
            self.climbInProgress = false
            self.staleClimbStartedAt = nil
            self.targetLat = nil
            self.targetLon = nil
            self.stopTimers()
            self.socket.disconnect()
            self.log("Jembatan dihentikan.")
        }
    }

    // MARK: - Advertise & subscribe

    /// Dipanggil setiap kali socket TERBUKA — termasuk setelah sambung ulang.
    /// Advertise tidak bertahan melewati koneksi yang putus, jadi mengulanginya
    /// bukan pemborosan melainkan syarat.
    private func advertiseAndSubscribe() {
        socket.send(RosBridgeProtocol.advertise(
            topic: RosBridgeProtocol.Topic.telemetry,
            type: RosBridgeProtocol.MessageType.string))
        socket.send(RosBridgeProtocol.advertise(
            topic: RosBridgeProtocol.Topic.state,
            type: RosBridgeProtocol.MessageType.string))

        socket.send(RosBridgeProtocol.advertiseService(
            service: RosBridgeProtocol.Service.takeoff,
            type: RosBridgeProtocol.MessageType.trigger))
        socket.send(RosBridgeProtocol.advertiseService(
            service: RosBridgeProtocol.Service.land,
            type: RosBridgeProtocol.MessageType.trigger))
        socket.send(RosBridgeProtocol.advertiseService(
            service: RosBridgeProtocol.Service.resync,
            type: RosBridgeProtocol.MessageType.trigger))

        socket.send(RosBridgeProtocol.subscribe(
            topic: RosBridgeProtocol.Topic.cmdVel,
            type: RosBridgeProtocol.MessageType.twist))
        socket.send(RosBridgeProtocol.subscribe(
            topic: RosBridgeProtocol.Topic.waypoints,
            type: RosBridgeProtocol.MessageType.string))
        socket.send(RosBridgeProtocol.subscribe(
            topic: RosBridgeProtocol.Topic.takeoffAltitude,
            type: RosBridgeProtocol.MessageType.float32))
    }

    // MARK: - Pesan masuk

    private func handleIncoming(text: String) {
        guard let data = text.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }

        switch json["op"] as? String {
        case "publish":
            let topic = json["topic"] as? String ?? ""
            handleTopic(topic, msg: json["msg"] as? [String: Any])
        case "call_service":
            handleServiceCall(json)
        default:
            // op lain (status/ping dari rosbridge) diabaikan.
            break
        }
    }

    private func handleTopic(_ topic: String, msg: [String: Any]?) {
        guard let msg = msg else { return }
        switch topic {
        case RosBridgeProtocol.Topic.cmdVel:
            handleCmdVel(msg)
        case RosBridgeProtocol.Topic.waypoints:
            handleWaypoints(msg)
        case RosBridgeProtocol.Topic.takeoffAltitude:
            // std_msgs/Float32 tiba sebagai {"data": <angka>}.
            if let value = msg["data"] as? Double {
                targetAltitudeM = min(max(value, minTakeoffAltitudeM), maxTakeoffAltitudeM)
                log("Target altitude takeoff: \(targetAltitudeM) m")
            } else if let value = msg["data"] as? NSNumber {
                targetAltitudeM = min(max(value.doubleValue, minTakeoffAltitudeM), maxTakeoffAltitudeM)
                log("Target altitude takeoff: \(targetAltitudeM) m")
            }
        default:
            break
        }
    }

    /// Konvensi dari dashboard (frontend/components/DroneController.tsx):
    ///   linear.x  -> maju/mundur (W/S)
    ///   linear.y  -> kanan/kiri  (D/A)
    ///   linear.z  -> naik/turun  (R/F), positif = naik
    ///   angular.z -> yaw (Q/E), positif = searah jarum jam
    ///
    /// NILAINYA TERNORMALISASI (-1..1), BUKAN m/s. Ini kontrak `/cmd_vel` yang
    /// sesungguhnya, dan sebelumnya jembatan ini salah membacanya.
    ///
    /// Buktinya ada di sisi ROS: `publish_velocity_setpoint()` pada
    /// dashboard_bridge_node_px4.py menjepit tiap sumbu ke ±1 lalu
    /// MENGALIKANNYA dengan manual_speed / vertical_speed / yaw_rate. Dashboard
    /// sendiri hanya mengirim ±1 dan ±0.5 (KEY_BINDINGS). Jembatan ini —
    /// dan sisi Android — dulu memakai angka itu apa adanya sebagai m/s dan
    /// derajat/detik, sehingga di drone ASLI:
    ///   W  = 1 m/s        (di simulasi 3,5 m/s)
    ///   R  = 0,5 m/s
    ///   Q  = 0,5 DERAJAT per detik — satu putaran penuh butuh 12 menit,
    ///        tidak bisa dibedakan dari drone yang diam total.
    /// Itulah sebabnya "WASD tidak berfungsi" sebagian benar: perintahnya
    /// sampai, besarannya saja yang nyaris nol.
    ///
    /// Angka pengalinya sengaja mengikuti tuning lapangan di
    /// ros2_ws/.../launch/dashboard_bridge.launch.py supaya satu penerbangan
    /// simulasi dan satu penerbangan asli bisa dibandingkan di laporan.
    ///
    /// Perhatikan linear.y: dashboard memakai "positif = KANAN", berlawanan
    /// dengan konvensi ROS REP-103 (positif = kiri). Yang diikuti di sini adalah
    /// dashboard, sama seperti sisi Android, karena itulah perilaku yang sudah
    /// teruji dipakai operator.
    private func handleCmdVel(_ msg: [String: Any]) {
        guard let linear = msg["linear"] as? [String: Any],
              let angular = msg["angular"] as? [String: Any]
        else { return }

        // Penjepitan WAJIB dilakukan sebelum dikalikan: tanpa itu satu pesan
        // rusak (atau klien lain yang salah paham kontrak) bisa memerintahkan
        // kecepatan berapa pun langsung ke virtual stick.
        cmdForward = Self.clampUnit(doubleValue(linear["x"])) * manualSpeedMps
        cmdRight = Self.clampUnit(doubleValue(linear["y"])) * manualSpeedMps
        cmdVertical = Self.clampUnit(doubleValue(linear["z"])) * manualVerticalSpeedMps
        cmdYawRate = Self.clampUnit(doubleValue(angular["z"])) * manualYawRateDegPerSec
        lastCmdVelAt = Date()

        // Perintah manual membatalkan SELURUH mode otomatis — operator selalu
        // menang.
        //
        // Auto-climb WAJIB ikut dibatalkan di sini, bukan hanya waypoint.
        // Urutan prioritas di controlTick() adalah
        // auto-climb > waypoint > manual, jadi selama climbInProgress menyala
        // cabang pertama selalu menang dan perintah stick TIDAK PERNAH sampai
        // ke drone: operator menekan WASD dan drone diam saja, tanpa satu pun
        // pesan yang menjelaskan kenapa. Membatalkannya di sini membuat aturan
        // "operator selalu menang" berlaku sungguhan, bukan hanya untuk
        // waypoint.
        climbInProgress = false
        staleClimbStartedAt = nil
        targetLat = nil
        targetLon = nil
    }

    /// Kontrak sama dengan waypoints_cb() di dashboard_bridge_node_px4.py:
    ///   {"seq": N, "waypoints": [{"lat":.., "lon":.., "z":..}, ...]}
    ///
    /// HANYA bentuk lat/lon yang diterima. Dashboard mengirim bentuk {x,y,z}
    /// dalam meter lokal ketika ia menganggap GPS tidak valid (lihat
    /// sendWaypoints() di useRos.ts) — dan menerbangkan drone asli ke offset
    /// meter tanpa origin yang disepakati adalah cara yang bagus untuk kehilangan
    /// drone. Ditolak eksplisit, dengan alasan yang terbaca operator.
    private func handleWaypoints(_ msg: [String: Any]) {
        guard let dataStr = msg["data"] as? String else {
            // JANGAN diam. Dashboard menunggu ACK/NACK untuk mengakhiri status
            // "Menunggu ACK"; diam membuatnya menggantung selamanya dan tidak
            // bisa dibedakan dari pesan yang hilang di jalan.
            publishEvent("waypoints_nack", seq: 0, count: 0,
                         message: "Pesan waypoint tanpa field 'data'.")
            return
        }

        guard let payloadData = dataStr.data(using: .utf8),
              let payload = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any]
        else {
            publishEvent("waypoints_nack", seq: 0, count: 0,
                         message: "Payload waypoint bukan JSON yang valid.")
            return
        }

        let seq = Int(doubleValue(payload["seq"]))

        guard let waypoints = payload["waypoints"] as? [[String: Any]], !waypoints.isEmpty else {
            publishEvent("waypoints_nack", seq: seq, count: 0, message: "Daftar waypoint kosong.")
            return
        }

        // Hanya waypoint PERTAMA yang dipakai (satu target tunggal), sama dengan
        // sisi Android — dashboard memang memakai pola point-to-point.
        let first = waypoints[0]
        guard first["lat"] != nil, first["lon"] != nil else {
            publishEvent("waypoints_nack", seq: seq, count: 0,
                         message: "Waypoint harus berformat lat/lon. Dashboard mengirim x/y lokal "
                                + "karena GPS dilaporkan tidak valid — tunggu fix GPS lalu ulangi.")
            return
        }

        let lat = doubleValue(first["lat"])
        let lon = doubleValue(first["lon"])
        guard Geo.isValidLatLon(lat, lon) else {
            publishEvent("waypoints_nack", seq: seq, count: 0,
                         message: "Koordinat lat/lon tidak valid.")
            return
        }

        // Tolak juga bila POSISI KITA SENDIRI belum diketahui: tanpa itu loop
        // kontrol tidak bisa menghitung arah, jadi ACK hanya akan berarti
        // "diterima lalu didiamkan".
        let snapshot = flightLink.currentSnapshot()
        guard snapshot.gpsValid else {
            publishEvent("waypoints_nack", seq: seq, count: 0,
                         message: "Posisi drone belum punya fix GPS (\(snapshot.satelliteCount) satelit).")
            return
        }

        // TOLAK GOAL YANG TERLALU DEKAT — lihat `minGoalDistanceM`.
        //
        // Tanpa penjaga ini, target di bawah radius terima langsung dinyatakan
        // TERCAPAI pada tick pertama: drone tidak bergerak sama sekali, tapi
        // dashboard menerima `mission_complete` dan mencatat misinya sebagai
        // selesai. Kegagalan yang menyamar jadi keberhasilan adalah kegagalan
        // paling mahal di lapangan — operator mengira jalur perintahnya sehat
        // padahal belum pernah diuji.
        // (gpsValid di atas sudah menjamin keduanya terisi; guard ini hanya
        // membuat jaminan itu terbaca oleh compiler.)
        guard let hereLat = snapshot.latitude, let hereLon = snapshot.longitude else {
            publishEvent("waypoints_nack", seq: seq, count: 0,
                         message: "Posisi drone belum diketahui.")
            return
        }

        let offset = Geo.localOffsetMeters(fromLat: hereLat, fromLon: hereLon,
                                           toLat: lat, toLon: lon)
        let distance = (offset.east * offset.east + offset.north * offset.north).squareRoot()
        guard distance >= minGoalDistanceM else {
            publishEvent("waypoints_nack", seq: seq, count: 0,
                         message: String(format:
                            "Target hanya %.1f m dari drone — di bawah jarak minimum %.0f m. "
                          + "Pada jarak sedekat itu drone langsung dianggap sudah sampai "
                          + "(radius terima %.0f m + galat GPS) dan tidak akan bergerak. "
                          + "Geser target lebih jauh.",
                          distance, minGoalDistanceM, waypointAcceptanceRadiusM))
            return
        }

        targetLat = lat
        targetLon = lon
        waypointSeq = seq

        // Auto-climb menang atas navigasi waypoint di controlTick. Kalau drone
        // sedang memanjat, perintah ini memang diterima — tapi baru dijalankan
        // setelah panjatnya selesai. Katakan apa adanya: ACK "navigasi dimulai"
        // padahal drone masih naik adalah sumber kebingungan yang persis sama
        // dengan kasus jarak terlalu dekat di atas.
        let prefix = climbInProgress
            ? "Waypoint diterima, MENUNGGU auto-climb selesai"
            : "Waypoint diterima & navigasi dimulai"
        publishEvent("waypoints_ack", seq: seq, count: 1,
                     message: String(format: "%@ — jarak %.1f m (GPS lat/lon).", prefix, distance))
    }

    // MARK: - Service

    private func handleServiceCall(_ json: [String: Any]) {
        let service = json["service"] as? String ?? ""
        let callId = json["id"] as? String ?? ""

        switch service {
        case RosBridgeProtocol.Service.takeoff:
            doTakeoff(callId: callId, service: service)
        case RosBridgeProtocol.Service.land:
            doLand(callId: callId, service: service)
        case RosBridgeProtocol.Service.resync:
            doResync(callId: callId, service: service)
        default:
            respond(service: service, callId: callId, success: false,
                    message: "Service tidak didukung oleh jembatan DJI.")
        }
    }

    private func doTakeoff(callId: String, service: String) {
        isControllingFlight = true
        let altitude = targetAltitudeM
        flightLink.startTakeoff { [weak self] success, message in
            guard let self = self else { return }
            self.queue.async {
                guard success else {
                    self.isControllingFlight = false
                    self.respond(service: service, callId: callId, success: false, message: message)
                    return
                }
                self.respond(service: service, callId: callId, success: true,
                             message: "Takeoff dimulai, auto-climb ke \(altitude) m.")
                // Auto-climb baru dinyalakan SETELAH takeoff diterima. DJI
                // startTakeoff() naik ke ketinggian tetapnya sendiri (~1.2 m
                // pada Spark) dan tidak menerima parameter altitude sama
                // sekali; sisa pendakian ke nilai yang diminta dashboard
                // dikerjakan loop kontrol lewat virtual stick.
                self.staleClimbStartedAt = nil
                self.climbInProgress = true
            }
        }
    }

    private func doLand(callId: String, service: String) {
        climbInProgress = false
        staleClimbStartedAt = nil
        targetLat = nil
        targetLon = nil
        flightLink.startLanding { [weak self] success, message in
            guard let self = self else { return }
            self.queue.async {
                self.respond(service: service, callId: callId, success: success, message: message)
            }
        }
    }

    /// Balasan resync: dashboard mem-PARSE `message` sebagai JSON dan
    /// memasukkannya ke ingestState() (lihat useRos.ts). Jadi isi `message` di
    /// sini BUKAN teks untuk manusia melainkan snapshot state.
    private func doResync(callId: String, service: String) {
        publishTelemetryNow()
        let snapshotJSON = RosBridgeProtocol.jsonString(buildStatePayload()) ?? "{}"
        respond(service: service, callId: callId, success: true, message: snapshotJSON)
    }

    private func respond(service: String, callId: String, success: Bool, message: String) {
        socket.send(RosBridgeProtocol.serviceResponse(
            service: service, id: callId, success: success, message: message))
    }

    // MARK: - Publikasi

    /// Event ACK/NACK/kedatangan ke /dashboard/state.
    ///
    /// `seq` WAJIB sama persis dengan yang dikirim dashboard. Dashboard
    /// mencocokkan seq untuk mengakhiri status "Menunggu ACK" (lihat efek
    /// rekonsiliasi di useRos.ts) — seq yang salah membuat badge itu
    /// menggantung selamanya walau perintahnya sebenarnya berhasil.
    private func publishEvent(_ event: String, seq: Int, count: Int, message: String) {
        let payload: [String: Any] = [
            "event": event,
            "seq": seq,
            "count": count,
            "message": message,
            "stamp_ms": Self.nowMillis(),
        ]
        if let frame = RosBridgeProtocol.publishJSONString(
            topic: RosBridgeProtocol.Topic.state, payload: payload) {
            socket.send(frame)
        }
        log("[\(event)] seq=\(seq): \(message)")
    }

    /// Laporkan ke dashboard SETIAP KALI kewenangan kendali berpindah.
    ///
    /// Ini pasangan dari field `controlReady` di telemetry: field itu memberi
    /// KEADAAN sekarang (untuk badge yang selalu terlihat), event ini memberi
    /// MOMEN dan ALASAN-nya (untuk banner + baris log). Tanpa keduanya,
    /// satu-satunya jejak hilangnya kewenangan ada di layar HP yang sedang
    /// dikantongi operator — dan itulah kenapa gejalanya selama ini hanya
    /// tampak sebagai "drone diam saja".
    private func reportControlAuthorityIfChanged() {
        let ready = flightLink.hasControlAuthority

        if ready {
            controlNotReadySince = nil
            guard lastReportedControlReady != true else { return }
            lastReportedControlReady = true
            publishEvent("control_ready", seq: 0, count: 0,
                         message: "Kewenangan kendali kembali — perintah dashboard berlaku lagi.")
            return
        }

        // Hilang. Tunggu dulu apakah benar-benar menetap sebelum berisik.
        if controlNotReadySince == nil { controlNotReadySince = Date() }
        guard let since = controlNotReadySince,
              Date().timeIntervalSince(since) >= controlLossReportDelay,
              lastReportedControlReady != false
        else { return }

        lastReportedControlReady = false
        publishEvent("control_lost", seq: 0, count: 0,
                     message: "PERINTAH DASHBOARD TIDAK BERLAKU: jembatan tidak sedang memegang "
                            + "kendali drone. Periksa sakelar mode remote (harus P), lepaskan "
                            + "stik RC, dan pastikan pesawat masih tersambung ke HP.")
    }

    /// Nilai yang dipakai field `controlReady`. Memakai hasil ber-histeresis
    /// bila sudah ada, dan nilai mentah hanya untuk laporan paling pertama.
    private func controlReadyForPublish() -> Bool {
        lastReportedControlReady ?? flightLink.hasControlAuthority
    }

    /// Snapshot state frekuensi rendah. TANPA field `event`, sehingga dashboard
    /// mengarahkannya ke ingestState() dan bukan ke ingestEvent().
    private func buildStatePayload() -> [String: Any] {
        let snapshot = flightLink.currentSnapshot()
        var payload: [String: Any] = [
            "mode": currentNavState(),
            "journey_status": currentJourneyStatus(),
            "rtlTriggered": false,
            "nearestObstacle": NSNull(),
            "vehicle": [
                "armed": snapshot.areMotorsOn,
                "navStateName": snapshot.flightModeString,
            ],
            "waypointSeq": waypointSeq,
        ]
        // Baterai HANYA disertakan bila benar-benar diketahui. Mengirim 0 saat
        // belum ada data akan tampil di dashboard sebagai baterai habis.
        //
        // Perhatikan satuannya: di jalur ini dashboard mengalikan `remaining`
        // dengan 100 (ingestState), sedangkan di jalur telemetry field
        // `battery` dipakai apa adanya sebagai persen. Dua konvensi berbeda
        // untuk angka yang sama — inilah tempat paling mudah tertukar.
        if let percent = snapshot.batteryPercent {
            var battery: [String: Any] = ["remaining": Double(percent) / 100.0]
            if let voltage = snapshot.voltageVolts {
                battery["voltage"] = RosBridgeProtocol.round2(voltage)
            }
            payload["battery"] = battery
        }
        return payload
    }

    private func publishStateNow() {
        guard let frame = RosBridgeProtocol.publishJSONString(
            topic: RosBridgeProtocol.Topic.state, payload: buildStatePayload()) else { return }
        socket.send(frame)
    }

    private func currentNavState() -> String {
        if climbInProgress { return "takeoff" }
        return targetLat != nil ? "auto" : "hold"
    }

    private func currentJourneyStatus() -> String {
        if climbInProgress { return "Climbing" }
        return targetLat != nil ? "Navigating to Target" : "Idle"
    }

    /// Skema field HARUS sama dengan publish_telemetry() di
    /// dashboard_bridge_node_px4.py dan publishTelemetryNow() di sisi Android —
    /// itulah yang membuat satu dashboard bisa dipakai untuk PX4, ArduPilot,
    /// Android, dan iOS tanpa perubahan kode.
    private func publishTelemetryNow() {
        let snapshot = flightLink.currentSnapshot()

        guard let lat = snapshot.latitude, let lon = snapshot.longitude else {
            // Belum ada fix GPS sama sekali — jangan terbitkan payload kosong
            // yang akan dibaca dashboard sebagai posisi (0,0) yang sah.
            return
        }

        let offset = flightLink.localOffset(for: snapshot)
        let speed = (snapshot.velocityEast * snapshot.velocityEast
                     + snapshot.velocityNorth * snapshot.velocityNorth).squareRoot()

        var payload: [String: Any] = [
            "stamp_ms": Self.nowMillis(),
            // x = timur, y = utara (ENU), relatif origin yang dikunci saat fix
            // GPS valid pertama.
            "x": RosBridgeProtocol.round3(offset.x),
            "y": RosBridgeProtocol.round3(offset.y),
            "z": RosBridgeProtocol.round3(snapshot.altitude),
            "alt": RosBridgeProtocol.round3(snapshot.altitude),
            // RADIAN — sama seperti sisi Android dan node PX4. Dashboard
            // memakai `heading` (derajat) untuk kompas HUD, dan `yaw` untuk
            // rotasi ikon.
            "yaw": RosBridgeProtocol.round4(snapshot.yawDegrees * .pi / 180.0),
            "heading": RosBridgeProtocol.round1(snapshot.headingDegrees),
            // BEDA DARI ANDROID: vx/vy mengikuti sumbu yang SAMA dengan x/y
            // (ENU), dan vz positif ke atas.
            //
            // Sisi Android meneruskan velocity DJI apa adanya, sehingga vx =
            // utara dan vy = timur — tertukar terhadap x = timur, y = utara di
            // payload yang sama, dan vz positif ke BAWAH berlawanan dengan
            // konvensi linear.z pada /cmd_vel. Tidak terlihat di dashboard
            // (yang memakai `speed`), tapi menghasilkan grafik yang salah kalau
            // vx/vy/vz dipakai untuk analisis di laporan.
            "vx": RosBridgeProtocol.round3(snapshot.velocityEast),
            "vy": RosBridgeProtocol.round3(snapshot.velocityNorth),
            "vz": RosBridgeProtocol.round3(snapshot.velocityUp),
            "speed": RosBridgeProtocol.round3(speed),
            "voltage": RosBridgeProtocol.round2(snapshot.voltageVolts ?? 0),
            "armed": snapshot.areMotorsOn,
            "flightMode": snapshot.flightModeString,
            "navState": currentNavState(),
            "journeyStatus": currentJourneyStatus(),
            "nearestObstacle": NSNull(),
            "pathIndex": 0,
            "pathLength": targetLat != nil ? 1 : 0,
            // BEDA DARI ANDROID: dilaporkan apa adanya, bukan hardcode true.
            // Lihat FlightSnapshot.gpsValid.
            "gpsValid": snapshot.gpsValid,
            "lat": RosBridgeProtocol.round7(lat),
            "lon": RosBridgeProtocol.round7(lon),
            // KEWENANGAN KENDALI. false berarti perintah dari dashboard (WASD,
            // Send Goal, takeoff) tidak akan menggerakkan drone sama sekali,
            // apa pun yang ditekan operator. Stack ArduPilot/PX4 tidak mengirim
            // field ini dan dashboard mempertahankan default true — lihat pola
            // yang sama pada armDisarmSupported di bawah.
            "controlReady": controlReadyForPublish(),
            // Dashboard MENYEMBUNYIKAN tombol ARM/DISARM saat ini false, karena
            // DJI tidak punya konsep arm terpisah — motor menyala sendiri saat
            // takeoff (lihat DroneController.tsx).
            "armDisarmSupported": false,
            // Jembatan ini tidak menyediakan RTH/Emergency Stop/Force Arm+
            // Takeoff/Auto Survey sebagai service, maupun peta simulasi Gazebo.
            // Dashboard menyembunyikan semuanya saat false, alih-alih
            // menampilkan tombol yang hanya akan timeout 5 detik.
            "advancedFeaturesSupported": false,
        ]
        // Di jalur telemetry, `battery` adalah PERSEN (0-100) apa adanya —
        // berbeda dari jalur /dashboard/state di atas.
        payload["battery"] = snapshot.batteryPercent.map { $0 as Any } ?? NSNull()

        if let frame = RosBridgeProtocol.publishJSONString(
            topic: RosBridgeProtocol.Topic.telemetry, payload: payload) {
            socket.send(frame)
        }
    }

    // MARK: - Loop kontrol

    /// Menggabungkan tiga sumber perintah dengan prioritas:
    ///   auto-climb  >  navigasi waypoint  >  manual /cmd_vel
    private func controlTick() {
        guard isRunning else { return }

        // JARING PENGAMAN KEWENANGAN — dijalankan sebelum apa pun yang lain.
        //
        // Selama jembatan hidup, ia HARUS memegang virtual stick. Bila SDK
        // memadamkannya (paling sering: link RC<->pesawat berkedip sesaat),
        // panggilan ini merebutnya kembali sendiri. Sebelum ini tidak ada apa
        // pun yang melakukannya, sehingga seluruh perintah dashboard dibuang
        // diam-diam sampai operator menekan Disconnect->Connect manual di app.
        // Murah: langsung no-op begitu kewenangan sudah di tangan.
        flightLink.ensureVirtualStickArmed()
        reportControlAuthorityIfChanged()

        let snapshot = flightLink.currentSnapshot()
        var forward = 0.0
        var right = 0.0
        var yawRate = 0.0
        var vertical = 0.0

        if climbInProgress {
            isControllingFlight = true
            // PENJAGA KESELAMATAN — jangan pernah memanjat memakai ketinggian
            // yang tidak tepercaya.
            //
            // FlightSnapshot() kosong berisi altitude = 0, dan angka itu tidak
            // bisa dibedakan dari "drone masih di tanah". Tanpa penjaga ini,
            // selama telemetry belum mengalir (paling nyata pada takeoff
            // PERTAMA setelah tersambung, saat delegate flight controller baru
            // dipasang) loop menyimpulkan drone belum sampai target lalu terus
            // memerintahkan naik 2 m/s — drone melewati target jauh sekali
            // sebelum pembacaan pertama tiba dan menghentikannya.
            if !snapshot.isFresh(maxAge: telemetryFreshnessTimeout) {
                // Menahan ketinggian adalah satu-satunya perintah yang aman
                // saat posisi tidak diketahui: berhenti naik, jangan pula
                // turun paksa (drone bisa saja sedang dekat tanah).
                vertical = 0
                if staleClimbStartedAt == nil { staleClimbStartedAt = Date() }
                if let since = staleClimbStartedAt,
                   Date().timeIntervalSince(since) >= climbStaleAbortSeconds {
                    // Telemetry tidak kunjung pulih. Membiarkan climbInProgress
                    // menyala berarti drone menggantung dalam mode terkendali
                    // tanpa umpan balik; lebih baik menyerahkan kendali dan
                    // memberi tahu operator secara eksplisit.
                    climbInProgress = false
                    staleClimbStartedAt = nil
                    publishEvent("takeoff_aborted", seq: 0, count: 0,
                                 message: "Auto-climb dihentikan: telemetry ketinggian "
                                        + "tidak tersedia. Kendalikan drone lewat remote fisik.")
                    log("Auto-climb dibatalkan — telemetry basi/absen.")
                }
            } else {
                staleClimbStartedAt = nil
                let diff = targetAltitudeM - snapshot.altitude
                if abs(diff) <= climbToleranceM {
                    climbInProgress = false
                } else {
                    // Melambat di bawah 1 m tersisa supaya tidak melampaui target
                    // lalu turun lagi (osilasi).
                    let rate = abs(diff) < 1.0 ? climbSlowRateMps : climbFastRateMps
                    vertical = (diff < 0 ? -1.0 : 1.0) * rate
                }
            }
        } else if let tLat = targetLat, let tLon = targetLon,
                  let lat = snapshot.latitude, let lon = snapshot.longitude,
                  // Alasan sama seperti auto-climb: posisi basi membuat drone
                  // mengejar tempat yang sudah ia tinggalkan. Bedanya di sini
                  // waypoint TIDAK dibatalkan — begitu telemetry pulih,
                  // navigasi lanjut sendiri dari posisi terbaru.
                  snapshot.isFresh(maxAge: telemetryFreshnessTimeout) {
            isControllingFlight = true
            let offset = Geo.localOffsetMeters(fromLat: lat, fromLon: lon, toLat: tLat, toLon: tLon)
            let distance = (offset.east * offset.east + offset.north * offset.north).squareRoot()

            if distance <= waypointAcceptanceRadiusM {
                targetLat = nil
                targetLon = nil
                // Satu-satunya sinyal KEDATANGAN yang dimiliki dashboard.
                // Posisi live saja tidak cukup: dashboard tidak tahu radius
                // terima yang dipakai jembatan.
                publishEvent("mission_complete", seq: waypointSeq, count: 1,
                             message: "Waypoint tercapai.")
            } else {
                let speedFraction = min(1.0, distance / 5.0)
                let cruise = waypointCruiseSpeedMps * max(0.3, speedFraction)
                let north = offset.north / distance * cruise
                let east = offset.east / distance * cruise
                // BEDA DARI ANDROID — dan ini perbaikan bug, bukan sekadar gaya.
                // Vektor di atas berada dalam kerangka BUMI, sedangkan virtual
                // stick disetel ke kerangka BADAN. Sisi Android mengirimkannya
                // tanpa konversi, sehingga arah terbangnya hanya benar ketika
                // hidung drone kebetulan menghadap utara. Lihat Geo.groundToBody().
                let body = Geo.groundToBody(north: north, east: east,
                                            yawDegrees: snapshot.yawDegrees)
                forward = body.forward
                right = body.right
            }
        } else {
            isControllingFlight = false
            // Perintah manual kedaluwarsa -> nol. Lihat manualCommandTimeout.
            let fresh = lastCmdVelAt.map { Date().timeIntervalSince($0) < manualCommandTimeout } ?? false
            if fresh {
                forward = cmdForward
                right = cmdRight
                yawRate = cmdYawRate
                vertical = cmdVertical
            }
        }

        flightLink.sendControl(forward: forward, right: right,
                               yawRate: yawRate, verticalRate: vertical)
    }

    // MARK: - Timer

    private func startTimers() {
        stopTimers()

        let telemetry = DispatchSource.makeTimerSource(queue: queue)
        telemetry.schedule(deadline: .now(), repeating: telemetryPeriod)
        telemetry.setEventHandler { [weak self] in self?.publishTelemetryNow() }
        telemetry.resume()
        telemetryTimer = telemetry

        let control = DispatchSource.makeTimerSource(queue: queue)
        control.schedule(deadline: .now(), repeating: controlPeriod)
        control.setEventHandler { [weak self] in self?.controlTick() }
        control.resume()
        controlTimer = control

        let state = DispatchSource.makeTimerSource(queue: queue)
        state.schedule(deadline: .now() + statePeriod, repeating: statePeriod)
        state.setEventHandler { [weak self] in self?.publishStateNow() }
        state.resume()
        stateTimer = state
    }

    private func stopTimers() {
        telemetryTimer?.cancel()
        telemetryTimer = nil
        controlTimer?.cancel()
        controlTimer = nil
        stateTimer?.cancel()
        stateTimer = nil
    }

    // MARK: - Util

    private static func nowMillis() -> Int {
        Int((Date().timeIntervalSince1970 * 1000.0).rounded())
    }

    /// Jepit ke rentang kontrak `/cmd_vel` (-1..1) sebelum dikalikan pengali
    /// kecepatan. Padanan `clamp(..., -1.0, 1.0)` di publish_velocity_setpoint()
    /// pada dashboard_bridge_node_px4.py.
    private static func clampUnit(_ value: Double) -> Double {
        min(max(value, -1.0), 1.0)
    }

    /// Angka dari JSON bisa datang sebagai NSNumber, Double, Int, atau String
    /// tergantung apa yang dikirim penerbit. Satu jalur konversi supaya tidak
    /// ada cast yang diam-diam menghasilkan 0.
    private func doubleValue(_ value: Any?) -> Double {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let number as Double: return number
        case let number as Int: return Double(number)
        case let text as String: return Double(text) ?? 0
        default: return 0
        }
    }

    private func log(_ message: String) {
        NSLog("[RosBridgeClient] %@", message)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.bridge(self, didLog: message)
        }
    }
}

// MARK: - RosBridgeSocketDelegate

extension RosBridgeClient: RosBridgeSocketDelegate {

    // Ketiga callback di bawah kini tiba di `socketQueue`, bukan lagi di
    // `queue`. Semua yang menyentuh state jembatan WAJIB dibungkus
    // `queue.async` — tanpa itu state yang sama disentuh dari dua antrean
    // sekaligus, dan balapan seperti itu tidak akan terlihat saat diuji di meja,
    // hanya di lapangan.
    func socketDidOpen(_ socket: RosBridgeSocket) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.isRunning = true
            self.advertiseAndSubscribe()
            self.startTimers()
            self.log("Tersambung ke rosbridge. Topik & service terdaftar.")
            DispatchQueue.main.async {
                self.delegate?.bridge(self, didChangeConnected: true)
            }
        }
    }

    func socket(_ socket: RosBridgeSocket, didReceiveText text: String) {
        queue.async { [weak self] in
            self?.handleIncoming(text: text)
        }
    }

    /// FAILSAFE LINK PUTUS.
    ///
    /// Kontrol kita berbasis virtual stick lewat WebSocket, BUKAN sinyal RC
    /// fisik. Dari sudut pandang pesawat tidak ada "RC yang hilang" saat
    /// WebSocket mati — datanya memang berhenti datang — jadi failsafe bawaan
    /// DJI belum tentu terpicu. Karena itu Return-To-Home dipanggil eksplisit di
    /// sini, TAPI hanya bila kita memang sedang mengendalikan penerbangan.
    /// Memicunya saat drone masih diam di darat hanya akan mengagetkan operator
    /// yang sedang menyiapkan alat.
    func socket(_ socket: RosBridgeSocket, didCloseWith reason: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let wasControlling = self.isControllingFlight
            self.isRunning = false
            self.isControllingFlight = false
            self.stopTimers()
            self.log("Koneksi rosbridge putus: \(reason)")

            DispatchQueue.main.async {
                self.delegate?.bridge(self, didChangeConnected: false)
            }

            guard wasControlling else { return }
            self.log("Link terputus saat kontrol aktif — memicu Return-To-Home otomatis.")
            self.flightLink.startGoHome { [weak self] success, message in
                self?.log(success ? message : "RTH otomatis GAGAL: \(message)")
            }
        }
    }
}
