//
//  RosBridgeProtocol.swift
//  DroneStackBridge
//
//  Pembentuk pesan protokol rosbridge_suite (WebSocket + JSON).
//
//  Protokol ini yang dipakai roslibjs di dashboard (frontend/lib/rosClient.ts)
//  dan roslibpy — jadi app ini TIDAK butuh library ROS apa pun, cukup WebSocket
//  biasa plus JSON. Semua op yang dipakai jembatan ini ada lima:
//
//    advertise         -> kita jadi PUBLISHER sebuah topik
//    subscribe         -> kita jadi SUBSCRIBER sebuah topik
//    publish           -> kirim satu pesan ke topik yang sudah di-advertise
//    advertise_service -> kita jadi SERVICE SERVER
//    service_response  -> balasan atas satu call_service yang masuk
//

import Foundation

enum RosBridgeProtocol {

    // MARK: - Tipe pesan ROS 2

    /// Format ROS 2 (`std_msgs/msg/String`), BUKAN format ROS 1
    /// (`std_msgs/String`). Dashboard memakai penamaan ROS 2 di seluruh
    /// rosClient.ts, dan rosbridge tidak menormalkan keduanya.
    enum MessageType {
        static let string = "std_msgs/msg/String"
        static let float32 = "std_msgs/msg/Float32"
        static let twist = "geometry_msgs/msg/Twist"
        static let trigger = "std_srvs/srv/Trigger"
    }

    // MARK: - Nama topik & service (kontrak dashboard)

    enum Topic {
        /// Kita PUBLISH: telemetry padat. Dibaca useRos.ts -> ingestTelemetry().
        static let telemetry = "/dashboard/telemetry"
        /// Kita PUBLISH: state frekuensi rendah DAN event ACK.
        static let state = "/dashboard/state"
        /// Kita SUBSCRIBE: kontrol manual dari keyboard dashboard, 10Hz.
        static let cmdVel = "/cmd_vel"
        /// Kita SUBSCRIBE: daftar waypoint (dibungkus JSON di dalam String).
        static let waypoints = "/dashboard/waypoints"
        /// Kita SUBSCRIBE: altitude takeoff, dipublish TEPAT SEBELUM /takeoff.
        static let takeoffAltitude = "/dashboard/takeoff_altitude"
    }

    enum Service {
        static let takeoff = "/takeoff"
        static let land = "/land"
        static let resync = "/dashboard/resync"
    }

    // MARK: - Pembentuk op

    static func advertise(topic: String, type: String) -> [String: Any] {
        ["op": "advertise", "topic": topic, "type": type]
    }

    static func subscribe(topic: String, type: String) -> [String: Any] {
        // `type` WAJIB disertakan. Tanpa itu rosbridge mencoba menebak tipe dari
        // topik yang sudah ada di ROS graph, lalu menolak subscription dengan
        // "Cannot infer topic type ... as it is not yet advertised".
        //
        // Di mode --dji TIDAK ADA node Python yang berjalan (lihat
        // scripts/start.sh), jadi ketiga topik yang kita subscribe belum pernah
        // ada di graph saat app menyambung — tanpa `type`, subscription-nya
        // SELALU gagal dan app tidak pernah menerima waypoint maupun altitude,
        // meski /takeoff dan /land tetap jalan (keduanya service dengan tipe
        // eksplisit). Persis jebakan yang sudah didokumentasikan di
        // RosBridgeClient.java.
        ["op": "subscribe", "topic": topic, "type": type]
    }

    static func advertiseService(service: String, type: String) -> [String: Any] {
        ["op": "advertise_service", "type": type, "service": service]
    }

    static func publish(topic: String, msg: [String: Any]) -> [String: Any] {
        ["op": "publish", "topic": topic, "msg": msg]
    }

    /// Publish `std_msgs/msg/String` yang ISINYA adalah JSON — pola yang dipakai
    /// seluruh kontrak dashboard (satu topik String, payload JSON di dalamnya).
    static func publishJSONString(topic: String, payload: [String: Any]) -> [String: Any]? {
        guard let encoded = jsonString(payload) else { return nil }
        return publish(topic: topic, msg: ["data": encoded])
    }

    static func serviceResponse(
        service: String,
        id: String,
        success: Bool,
        message: String
    ) -> [String: Any] {
        [
            "op": "service_response",
            "service": service,
            "id": id,
            "values": ["success": success, "message": message],
            "result": true,
        ]
    }

    // MARK: - Serialisasi

    /// Serialisasi JSON yang AMAN terhadap NaN/Infinity.
    ///
    /// JSONSerialization MELEMPAR EXCEPTION untuk Double non-finite, dan nilai
    /// seperti itu benar-benar muncul dari SDK (mis. altitude sebelum sensor
    /// siap, atau pembagian oleh jarak nol). Kalau tidak disaring, satu NaN
    /// membuat SELURUH pesan telemetry gagal terkirim — gejalanya di dashboard
    /// identik dengan "app tidak terhubung", padahal socketnya sehat.
    static func jsonString(_ object: [String: Any]) -> String? {
        let sanitized = sanitize(object)
        guard JSONSerialization.isValidJSONObject(sanitized),
              let data = try? JSONSerialization.data(withJSONObject: sanitized)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func sanitize(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            return dict.mapValues { sanitize($0) }
        case let array as [Any]:
            return array.map { sanitize($0) }
        case let number as Double:
            return number.isFinite ? number : 0.0
        case let number as Float:
            return number.isFinite ? Double(number) : 0.0
        default:
            return value
        }
    }

    // MARK: - Pembulatan (paritas dengan sisi Android)

    static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
    static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
    static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
    static func round4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
    /// 7 desimal ~ 1 cm di ekuator. Lebih dari ini hanya mengirim derau GPS.
    static func round7(_ v: Double) -> Double { (v * 10_000_000).rounded() / 10_000_000 }
}
