//
//  PhotoPipelineBridge.swift
//  DroneStackBridge
//
//  Penghubung lengkap: KARTU SD DRONE → iPhone → BACKEND DI LAPTOP.
//
//    [1] MediaSyncManager    unduh foto baru lewat radio DJI ke penyimpanan HP
//    [2] PhotoBatchUploader  unggah satu batch ke POST /jobs/stitch di laptop
//
//  Port dari PhotoPipelineBridge.java. Seperti versi Android, kelas ini hanya
//  merangkai keduanya dan memindahkan SELURUH callback ke thread utama:
//  callback DJI maupun URLSession tiba di thread latar, dan menyentuh @Published
//  dari sana membuat SwiftUI mengeluh (atau merusak state diam-diam). Penerjemahan
//  thread dilakukan sekali di sini alih-alih diulang di setiap pemanggil.
//
//  PRASYARAT YANG TIDAK DIURUS KELAS INI:
//   - Drone menyala, terhubung, dan kartu SD terpasang.
//   - Drone TIDAK sedang terbang/memotret — pengunduhan memindahkan kamera ke
//     mode unduh sehingga pemotretan berhenti sementara.
//   - iPhone dan laptop berada di jaringan yang sama.
//   - Info.plist mengizinkan lalu lintas cleartext (NSAllowsArbitraryLoads),
//     padanan `usesCleartextTraffic` di AndroidManifest.
//

import Foundation

final class PhotoPipelineBridge {

    private let syncManager = MediaSyncManager()
    private let uploader = PhotoBatchUploader()

    /// Folder foto drone di iPhone — berguna untuk ditampilkan di UI.
    var photoDirectory: URL { syncManager.photoDirectory() }

    func listStoredPhotos() -> [URL] { syncManager.listStoredPhotos() }

    var isSyncing: Bool { syncManager.isSyncing }

    /// Jalankan seluruh rantai: unduh foto baru, lalu unggah ke backend.
    ///
    /// Yang diunggah adalah SELURUH foto yang tersimpan di HP, bukan hanya yang
    /// baru diunduh. Stitching membutuhkan foto-foto yang saling bertampalan
    /// sebagai satu himpunan; mengirim hanya "yang baru" akan memecah satu
    /// survei menjadi beberapa job yang masing-masing terlalu sedikit.
    func syncAndUpload(
        serverIp: String,
        port: Int,
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<(jobId: String, photoCount: Int), PhotoPipelineError>) -> Void
    ) {
        let onProgress = mainQueue(progress)
        let onDone = mainQueue(completion)

        syncManager.syncNewPhotos(progress: onProgress) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                onDone(.failure(error))
            case .success(let sync):
                onProgress("Sinkronisasi selesai: \(sync.newPhotos.count) foto baru, "
                           + "\(sync.allPhotos.count) total di HP.")
                self.uploader.uploadBatch(
                    serverIp: serverIp, port: port, photos: sync.allPhotos,
                    progress: onProgress, completion: onDone)
            }
        }
    }

    /// Unggah foto yang SUDAH ada di HP tanpa menyentuh drone.
    ///
    /// Berguna saat sinkronisasi sebelumnya sudah dilakukan tetapi unggahan
    /// gagal (mis. laptop belum siap) — tidak perlu menghidupkan drone lagi.
    func uploadStoredPhotos(
        serverIp: String,
        port: Int,
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<(jobId: String, photoCount: Int), PhotoPipelineError>) -> Void
    ) {
        uploader.uploadBatch(
            serverIp: serverIp, port: port, photos: syncManager.listStoredPhotos(),
            progress: mainQueue(progress), completion: mainQueue(completion))
    }

    // MARK: - Util

    /// Bungkus closure supaya selalu dieksekusi di thread utama.
    private func mainQueue<T>(_ block: @escaping (T) -> Void) -> (T) -> Void {
        { value in
            if Thread.isMainThread {
                block(value)
            } else {
                DispatchQueue.main.async { block(value) }
            }
        }
    }
}
