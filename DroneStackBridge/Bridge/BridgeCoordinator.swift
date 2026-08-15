//
//  BridgeCoordinator.swift
//  DroneStackBridge
//
//  Perekat antara UI (SwiftUI), DJI SDK, dan jembatan rosbridge.
//
//  Semua @Published di sini hanya boleh ditulis dari utas utama; delegate DJI
//  dan delegate jembatan sudah memastikan itu sebelum memanggil balik.
//

import Combine
import Foundation
import UIKit

@MainActor
final class BridgeCoordinator: ObservableObject {

    // Status untuk UI.
    @Published var sdkRegistered = false
    @Published var productConnected = false
    @Published var productModel = "-"
    @Published var bridgeConnected = false
    @Published var virtualStickActive = false
    @Published var statusLine = "Menunggu registrasi SDK..."
    @Published var logLines: [String] = []

    // Jalur foto (kartu SD drone -> iPhone -> backend FastAPI).
    @Published var photoSyncing = false
    @Published var storedPhotoCount = 0
    @Published var lastJobId: String?

    // Field yang bisa diedit operator.
    @Published var host: String = BridgeSettings.host
    @Published var port: String = String(BridgeSettings.port)

    private let flightLink = DJIFlightLink()
    private lazy var bridge = RosBridgeClient(flightLink: flightLink)
    private let photoBridge = PhotoPipelineBridge()

    /// Batas baris log yang disimpan. Log ini alat diagnosis di lapangan, bukan
    /// arsip — membiarkannya tumbuh tanpa batas selama penerbangan panjang hanya
    /// menghabiskan memori dan memperlambat render daftar.
    private let maxLogLines = 200

    init() {
        flightLink.delegate = self
        bridge.delegate = self
    }

    func onAppear() {
        flightLink.registerWithSDK()
        refreshStoredPhotoCount()
    }

    // MARK: - Aksi UI

    func connect() {
        let portValue = Int(port) ?? BridgeSettings.defaultPort
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)

        if let problem = BridgeSettings.validate(host: trimmedHost, port: portValue) {
            statusLine = problem
            append(log: problem)
            return
        }
        guard productConnected else {
            statusLine = "Drone belum tersambung ke iPhone."
            append(log: statusLine)
            return
        }

        BridgeSettings.host = trimmedHost
        BridgeSettings.port = portValue

        // Layar TIDAK BOLEH mati selama jembatan aktif: begitu iOS mengunci
        // layar, app masuk background, timer berhenti, dan pengiriman virtual
        // stick ikut berhenti — drone lalu hover sampai failsafe bekerja.
        UIApplication.shared.isIdleTimerDisabled = true

        statusLine = "Mengaktifkan Virtual Stick..."
        // Urutannya sama dengan sisi Android: virtual stick dulu, WebSocket
        // belakangan. Menyambung lebih dulu berarti dashboard bisa mengirim
        // perintah pada saat app belum punya kewenangan menggerakkan drone.
        flightLink.enableVirtualStick { [weak self] success, message in
            Task { @MainActor in
                guard let self = self else { return }
                self.append(log: message)
                self.virtualStickActive = success
                guard success else {
                    self.statusLine = message
                    UIApplication.shared.isIdleTimerDisabled = false
                    return
                }
                self.statusLine = "Menyambung ke rosbridge..."
                self.bridge.start(host: trimmedHost, port: portValue)
            }
        }
    }

    func disconnect() {
        bridge.stop()
        flightLink.disableVirtualStick()
        virtualStickActive = false
        UIApplication.shared.isIdleTimerDisabled = false
        statusLine = "Jembatan dihentikan."
    }

    // MARK: - Jalur foto

    /// Unduh foto baru dari kartu SD drone ke iPhone, lalu unggah ke backend.
    ///
    /// SENGAJA tidak menuntut jembatan rosbridge aktif maupun Virtual Stick
    /// menyala — sinkronisasi foto hanya memerlukan KAMERA. Sisi Android
    /// menangani tombol ini sebelum penjaga `flightController == null` untuk
    /// alasan yang sama (lihat onClick() di VirtualStickView.java); kalau ikut
    /// lewat penjaga itu, tombolnya diam tanpa pesan justru pada kondisi di mana
    /// kameranya sebenarnya siap dipakai.
    func syncPhotos() {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = BridgeSettings.validate(
            host: trimmedHost, port: BridgeSettings.defaultBackendPort) {
            statusLine = problem
            append(log: problem)
            return
        }
        guard productConnected else {
            statusLine = "Drone belum tersambung — kamera tidak bisa dibaca."
            append(log: statusLine)
            return
        }
        guard !photoSyncing else { return }

        BridgeSettings.host = trimmedHost
        photoSyncing = true
        append(log: "Mulai sinkronisasi foto ke \(trimmedHost):\(BridgeSettings.defaultBackendPort)")

        photoBridge.syncAndUpload(
            serverIp: trimmedHost,
            port: BridgeSettings.defaultBackendPort,
            progress: { [weak self] message in
                guard let self = self else { return }
                self.statusLine = message
                self.append(log: message)
            },
            completion: { [weak self] result in
                guard let self = self else { return }
                self.photoSyncing = false
                self.refreshStoredPhotoCount()
                switch result {
                case .success(let outcome):
                    self.lastJobId = outcome.jobId
                    self.statusLine = "Terkirim: \(outcome.photoCount) foto. "
                        + "Job stitching: \(outcome.jobId)"
                    self.append(log: self.statusLine)
                case .failure(let error):
                    self.statusLine = "Sync gagal: \(error.localizedDescription)"
                    self.append(log: self.statusLine)
                }
            }
        )
    }

    /// Unggah ulang foto yang sudah ada di iPhone, tanpa menyentuh drone.
    /// Dipakai ketika sinkronisasi sudah berhasil tetapi unggahannya gagal
    /// (mis. laptop belum siap) — tidak perlu menghidupkan drone lagi.
    func reuploadStoredPhotos() {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = BridgeSettings.validate(
            host: trimmedHost, port: BridgeSettings.defaultBackendPort) {
            statusLine = problem
            append(log: problem)
            return
        }
        guard !photoSyncing else { return }

        photoSyncing = true
        append(log: "Mengunggah ulang foto tersimpan...")

        photoBridge.uploadStoredPhotos(
            serverIp: trimmedHost,
            port: BridgeSettings.defaultBackendPort,
            progress: { [weak self] message in
                guard let self = self else { return }
                self.statusLine = message
                self.append(log: message)
            },
            completion: { [weak self] result in
                guard let self = self else { return }
                self.photoSyncing = false
                switch result {
                case .success(let outcome):
                    self.lastJobId = outcome.jobId
                    self.statusLine = "Terkirim: \(outcome.photoCount) foto. "
                        + "Job stitching: \(outcome.jobId)"
                case .failure(let error):
                    self.statusLine = "Unggah gagal: \(error.localizedDescription)"
                }
                self.append(log: self.statusLine)
            }
        )
    }

    func refreshStoredPhotoCount() {
        storedPhotoCount = photoBridge.listStoredPhotos().count
    }

    // MARK: - Log

    fileprivate func append(log line: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        logLines.append("[\(stamp)] \(line)")
        if logLines.count > maxLogLines {
            logLines.removeFirst(logLines.count - maxLogLines)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

// MARK: - DJIFlightLinkDelegate

extension BridgeCoordinator: DJIFlightLinkDelegate {

    nonisolated func flightLink(_ link: DJIFlightLink, didLog message: String) {
        Task { @MainActor in
            self.append(log: message)
            self.statusLine = message
        }
    }

    nonisolated func flightLinkDidChangeAvailability(_ link: DJIFlightLink) {
        Task { @MainActor in
            self.sdkRegistered = link.isRegistered
            self.productConnected = link.isProductConnected
            self.productModel = link.productModel
        }
    }
}

// MARK: - RosBridgeClientDelegate

extension BridgeCoordinator: RosBridgeClientDelegate {

    nonisolated func bridge(_ bridge: RosBridgeClient, didLog message: String) {
        Task { @MainActor in
            self.append(log: message)
        }
    }

    nonisolated func bridge(_ bridge: RosBridgeClient, didChangeConnected connected: Bool) {
        Task { @MainActor in
            self.bridgeConnected = connected
            self.statusLine = connected
                ? "Jembatan AKTIF — dashboard sudah bisa mengendalikan drone."
                : "Jembatan terputus."
            if !connected {
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }
}
