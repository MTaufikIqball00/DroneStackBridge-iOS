//
//  Geo.swift
//  DroneStackBridge
//
//  Konversi geodetik sederhana (flat-earth approximation).
//
//  Rumusnya SENGAJA sama persis dengan yang dipakai sisi Android
//  (RosBridgeClient.java) dan sisi ROS (geodesy.py): satu derajat lintang =
//  111195 m, dan satu derajat bujur menyusut mengikuti cos(lintang). Untuk
//  jarak lapangan (< beberapa km) galat pendekatan ini jauh di bawah galat GPS
//  Spark itu sendiri, jadi tidak ada alasan memakai Vincenty/haversine penuh —
//  yang penting KEDUA SISI memakai rumus yang sama supaya x/y yang dihitung app
//  dan yang dihitung dashboard tidak pernah berbeda.
//

import Foundation

enum Geo {
    /// Meter per derajat lintang. Konstanta yang sama dipakai di
    /// RosBridgeClient.java (METERS_PER_DEG_LAT) dan geodesy.py.
    static let metersPerDegreeLatitude = 111_195.0

    /// Meter per derajat bujur pada suatu lintang — menyusut mengikuti cos(lat).
    static func metersPerDegreeLongitude(atLatitude latitudeDeg: Double) -> Double {
        metersPerDegreeLatitude * cos(latitudeDeg * .pi / 180.0)
    }

    /// Offset lokal dari titik A ke titik B dalam meter.
    ///
    /// Mengembalikan komponen ENU (east, north) — BUKAN (x, y) mentah — supaya
    /// pemanggil tidak bisa keliru menukar sumbu tanpa sadar. Inilah kekeliruan
    /// yang paling mahal di kelas kode ini: menukar utara/timur berarti drone
    /// terbang 90 derajat meleset dari target.
    static func localOffsetMeters(
        fromLat: Double,
        fromLon: Double,
        toLat: Double,
        toLon: Double
    ) -> (east: Double, north: Double) {
        let north = (toLat - fromLat) * metersPerDegreeLatitude
        let east = (toLon - fromLon) * metersPerDegreeLongitude(atLatitude: fromLat)
        return (east: east, north: north)
    }

    /// Validasi koordinat.
    ///
    /// Menolak (0,0) — "Null Island" — karena pada praktiknya nilai itu hampir
    /// selalu berarti "GPS belum fix", bukan lokasi sungguhan di Teluk Guinea.
    /// Tanpa penyaring ini, drone yang belum dapat fix akan melaporkan posisi
    /// valid ke dashboard dan seluruh jejak terbang menumpuk di titik nol.
    static func isValidLatLon(_ lat: Double?, _ lon: Double?) -> Bool {
        guard let lat = lat, let lon = lon else { return false }
        guard lat.isFinite, lon.isFinite else { return false }
        guard lat >= -90.0, lat <= 90.0, lon >= -180.0, lon <= 180.0 else { return false }
        return !(abs(lat) < 1e-7 && abs(lon) < 1e-7)
    }

    /// Putar vektor kecepatan dari kerangka BUMI (utara/timur) ke kerangka BADAN
    /// pesawat (depan/kanan), memakai yaw drone saat ini.
    ///
    /// KENAPA INI ADA — dan kenapa versi Android tidak punya:
    /// RosBridgeClient.java menyetel `FlightCoordinateSystem.BODY` lalu
    /// mengirimkan komponen utara/timur apa adanya ke virtual stick (lihat
    /// controlTick() di file itu, yang bahkan menyisakan komentar "TODO lapangan:
    /// verifikasi arah pitch/roll benar"). Itu hanya benar ketika hidung drone
    /// kebetulan menghadap UTARA. Kalau hidung menghadap timur, perintah "maju ke
    /// utara" membuat drone terbang ke timur — meleset 90 derajat, dan makin jauh
    /// waypoint-nya makin besar simpangannya.
    ///
    /// Rotasi standar: yaw dihitung dari utara, positif searah jarum jam.
    ///   depan =  utara*cos(yaw) + timur*sin(yaw)
    ///   kanan = -utara*sin(yaw) + timur*cos(yaw)
    ///
    /// Uji cepat: hidung menghadap timur (yaw = 90°), target di utara
    /// (utara=1, timur=0) -> depan = 0, kanan = -1. Benar: target ada di
    /// sebelah KIRI drone.
    static func groundToBody(
        north: Double,
        east: Double,
        yawDegrees: Double
    ) -> (forward: Double, right: Double) {
        let yawRad = yawDegrees * .pi / 180.0
        let c = cos(yawRad)
        let s = sin(yawRad)
        return (forward: north * c + east * s, right: -north * s + east * c)
    }
}
