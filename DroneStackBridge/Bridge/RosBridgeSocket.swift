//
//  RosBridgeSocket.swift
//  DroneStackBridge
//
//  Pembungkus tipis di atas URLSessionWebSocketTask.
//
//  KENAPA TIDAK PAKAI LIBRARY (Starscream dkk):
//  URLSessionWebSocketTask sudah tersedia sejak iOS 13 dan target minimum app
//  ini iOS 15, jadi menambah dependensi pihak ketiga hanya menambah satu hal
//  lagi yang bisa gagal saat `pod install` di komputer lain — tanpa memberi
//  kemampuan yang kita butuhkan. Sisi Android memakai java-websocket karena
//  Android memang tidak punya padanan bawaan.
//

import Foundation

protocol RosBridgeSocketDelegate: AnyObject {
    func socketDidOpen(_ socket: RosBridgeSocket)
    func socket(_ socket: RosBridgeSocket, didReceiveText text: String)
    /// Dipanggil TEPAT SEKALI per sesi koneksi, apa pun penyebab putusnya
    /// (ditutup server, error jaringan, atau ditutup kita sendiri).
    func socket(_ socket: RosBridgeSocket, didCloseWith reason: String)
}

final class RosBridgeSocket: NSObject {

    weak var delegate: RosBridgeSocketDelegate?

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var pingTimer: DispatchSourceTimer?

    /// Semua mutasi state socket terjadi di antrean ini, termasuk callback yang
    /// diteruskan ke delegate. Jadi RosBridgeClient tidak perlu mengunci apa pun
    /// untuk state yang disentuh dari jalur socket.
    private let queue: DispatchQueue

    /// Penjaga agar `didCloseWith` tidak pernah dipanggil dua kali. URLSession
    /// bisa melaporkan putusnya koneksi lewat TIGA jalur berbeda sekaligus
    /// (delegate didCloseWith, delegate didCompleteWithError, dan error pada
    /// receive loop). Tanpa penjaga ini, satu kali putus memicu failsafe
    /// Return-To-Home berkali-kali.
    private var closeReported = false
    private(set) var isOpen = false

    private let pingIntervalSeconds = 10.0

    init(queue: DispatchQueue) {
        self.queue = queue
        super.init()
    }

    // MARK: - Lifecycle

    func connect(host: String, port: Int) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.teardown(reason: nil)
            self.closeReported = false

            var components = URLComponents()
            components.scheme = "ws"
            components.host = host
            components.port = port

            guard let url = components.url else {
                self.reportClose("Alamat tidak valid: \(host):\(port)")
                return
            }

            let configuration = URLSessionConfiguration.default
            // Jangan biarkan iOS diam-diam menunggu jaringan "yang lebih baik":
            // kalau IP-nya salah kita ingin tahu cepat, bukan menggantung.
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = 10

            let session = URLSession(
                configuration: configuration,
                delegate: self,
                delegateQueue: nil
            )
            let task = session.webSocketTask(with: url)
            self.session = session
            self.task = task
            task.resume()
            self.receiveNext()
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            self?.teardown(reason: "Ditutup oleh pengguna.")
        }
    }

    // MARK: - Kirim

    /// Kirim satu objek JSON. Fire-and-forget: kegagalan satu pesan telemetry
    /// tidak boleh menghentikan penerbangan, tapi kegagalan transport (socket
    /// mati) tetap dilaporkan lewat jalur close.
    func send(_ object: [String: Any]) {
        guard let text = RosBridgeProtocol.jsonString(object) else {
            NSLog("[RosBridgeSocket] Gagal serialisasi pesan, dilewati.")
            return
        }
        send(text: text)
    }

    func send(text: String) {
        queue.async { [weak self] in
            guard let self = self, let task = self.task, self.isOpen else { return }
            task.send(.string(text)) { [weak self] error in
                guard let error = error else { return }
                self?.queue.async {
                    self?.reportClose("Gagal mengirim: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Terima

    private func receiveNext() {
        guard let task = task else { return }
        task.receive { [weak self] result in
            guard let self = self else { return }
            self.queue.async {
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.delegate?.socket(self, didReceiveText: text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.delegate?.socket(self, didReceiveText: text)
                        }
                    @unknown default:
                        break
                    }
                    self.receiveNext()
                case .failure(let error):
                    self.reportClose("Koneksi terputus: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Keep-alive

    private func startPing() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pingIntervalSeconds, repeating: pingIntervalSeconds)
        timer.setEventHandler { [weak self] in
            guard let self = self, let task = self.task, self.isOpen else { return }
            task.sendPing { [weak self] error in
                guard let error = error else { return }
                self?.queue.async {
                    self?.reportClose("Ping gagal: \(error.localizedDescription)")
                }
            }
        }
        timer.resume()
        pingTimer = timer
    }

    // MARK: - Pembersihan

    private func teardown(reason: String?) {
        pingTimer?.cancel()
        pingTimer = nil
        isOpen = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        if let reason = reason {
            reportClose(reason)
        }
    }

    private func reportClose(_ reason: String) {
        guard !closeReported else { return }
        closeReported = true
        isOpen = false
        pingTimer?.cancel()
        pingTimer = nil
        delegate?.socket(self, didCloseWith: reason)
    }
}

// MARK: - URLSessionWebSocketDelegate

extension RosBridgeSocket: URLSessionWebSocketDelegate {

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.isOpen = true
            self.startPing()
            self.delegate?.socketDidOpen(self)
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let detail = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        queue.async { [weak self] in
            self?.reportClose(
                detail.isEmpty
                    ? "Server menutup koneksi (code \(closeCode.rawValue))."
                    : "Server menutup koneksi: \(detail)"
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        queue.async { [weak self] in
            self?.reportClose(
                error.map { "Koneksi gagal: \($0.localizedDescription)" }
                    ?? "Koneksi berakhir."
            )
        }
    }
}
