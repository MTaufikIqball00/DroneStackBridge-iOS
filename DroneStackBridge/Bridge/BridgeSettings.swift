//
//  BridgeSettings.swift
//  DroneStackBridge
//
//  Alamat rosbridge yang tersimpan antar-sesi.
//
//  Disimpan karena IP laptop berubah cukup sering di lingkungan pengujian ini
//  (WSL2 memberi IP baru setiap kali direstart), dan mengetik ulang alamat di
//  lapangan — sambil memegang drone — adalah cara termudah salah ketik.
//

import Foundation

enum BridgeSettings {

    private enum Key {
        static let host = "bridge.host"
        static let port = "bridge.port"
    }

    /// Port default rosbridge_server pada drone-stack (lihat scripts/start.sh).
    static let defaultPort = 9090

    /// Port FastAPI `backend_ai` — pasangan dari 9090 milik rosbridge.
    ///
    /// Di-hardcode seperti `BACKEND_PORT` di sisi Android (VirtualStickView.java):
    /// rosbridge dan FastAPI diasumsikan berjalan di mesin yang SAMA, hanya beda
    /// port, sehingga IP laptop yang diketik operator sekali dipakai untuk
    /// keduanya — tidak perlu ditanyakan dua kali di lapangan.
    static let defaultBackendPort = 8000

    static var host: String {
        get { UserDefaults.standard.string(forKey: Key.host) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Key.host) }
    }

    static var port: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: Key.port)
            return stored > 0 ? stored : defaultPort
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.port) }
    }

    /// Validasi ringan sebelum mencoba menyambung — pesan yang jelas di sini
    /// jauh lebih berguna daripada timeout WebSocket 10 detik tanpa penjelasan.
    static func validate(host: String, port: Int) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Alamat IP laptop belum diisi."
        }
        if trimmed.contains("://") {
            return "Isi IP saja tanpa 'ws://' (contoh: 192.168.1.10)."
        }
        if port <= 0 || port > 65535 {
            return "Port harus antara 1 dan 65535."
        }
        return nil
    }
}
