//
//  MediaSyncManager.swift
//  DroneStackBridge
//
//  PENGHUBUNG FOTO TAHAP 1 — memindahkan foto dari kartu microSD di dalam drone
//  ke penyimpanan iPhone, lewat gelombang radio DJI (tanpa mencabut kartu SD).
//
//  Port dari MediaSyncManager.java sisi Android. Perilakunya disamakan; yang
//  berbeda hanya API-nya, karena DJI iOS SDK mengalirkan berkas sebagai potongan
//  NSData (kita yang menulis ke disk), sedangkan versi Android menyerahkan
//  penulisan berkas ke SDK.
//
//  KARTU SD TETAP WAJIB TERPASANG. Kelas ini tidak menghapus kebutuhan itu:
//  DJI Spark selalu menulis foto ke kartu SD lebih dulu. Yang dihilangkan hanya
//  langkah cabut-colok fisiknya.
//
//  BATASAN PENTING — TIDAK BISA MENGUNDUH SAMBIL MEMOTRET
//  ------------------------------------------------------
//  MediaManager hanya bekerja setelah kamera dipindah ke mode MEDIA_DOWNLOAD
//  (atau playback pada produk ber-flat-camera-mode). Selama mode itu aktif,
//  kamera TIDAK bisa mengambil foto. Karena itu sinkronisasi dirancang sebagai
//  operasi SEKALI JALAN setelah misi selesai — bukan pengunduhan latar belakang
//  yang berjalan terus selama terbang. Mode kamera selalu dikembalikan ke
//  SHOOT_PHOTO setelah selesai, termasuk saat gagal di tengah jalan.
//

import Foundation
import DJISDK

/// Galat jalur foto. Pesannya ditulis untuk dibaca operator di lapangan, bukan
/// untuk dicocokkan oleh kode — jadi selalu sertakan langkah perbaikannya.
enum PhotoPipelineError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

final class MediaSyncManager {

    struct SyncResult {
        /// Berkas yang BARU diunduh pada pemanggilan ini.
        let newPhotos: [URL]
        /// SELURUH foto yang tersimpan di iPhone (termasuk sinkronisasi
        /// sebelumnya) — inilah yang diunggah, karena backend mensyaratkan
        /// minimal 4 foto per job.
        let allPhotos: [URL]
    }

    /// Nama subfolder di dalam Documents milik app.
    private let photoDirName = "drone_photos"

    /// Antrean khusus untuk callback unduhan DJI. Tidak memakai main queue
    /// supaya penulisan berkas belasan MB tidak membekukan UI.
    private let downloadQueue = DispatchQueue(label: "com.dronestack.mediasync")

    /// Berapa kali satu berkas dicoba sebelum dilewati.
    private let maxDownloadAttempts = 3

    /// Jeda sebelum mencoba ulang berkas yang gagal. Memberi waktu kamera
    /// menyelesaikan penulisan ke kartu SD dan sinyal radio pulih.
    private let retryDelaySeconds: TimeInterval = 2.0

    /// Jeda setelah kamera masuk mode unduh, sebelum daftar berkas dibaca.
    ///
    /// Foto yang BARU dipotret bisa belum selesai ditulis ke kartu SD saat
    /// perpindahan mode selesai. Membaca daftar terlalu cepat membuat berkas
    /// terakhir tidak terdaftar, atau terdaftar tetapi gagal diunduh karena
    /// masih ditulis — gejalanya "beberapa foto terakhir hilang".
    private let listSettleSeconds: TimeInterval = 2.0

    /// Sedang menyinkronkan foto — artinya kamera berada di mode unduh dan
    /// TIDAK bisa memotret.
    ///
    /// Sengaja `static`: kondisinya memang milik PERANGKAT, bukan milik satu
    /// instance kelas ini. Kamera drone cuma satu dan hanya bisa berada di satu
    /// mode pada satu waktu, jadi `DJIFlightLink.capturePhoto()` perlu
    /// membacanya tanpa harus dioper referensi objek ini — dua bagian app yang
    /// tidak saling kenal tapi memperebutkan sumber daya fisik yang sama.
    private(set) static var isSyncInProgress = false

    /// Cerminan per-instance dari status global di atas — satu sumber
    /// kebenaran, supaya keduanya tidak mungkin berbeda.
    var isSyncing: Bool { Self.isSyncInProgress }

    // MARK: - Lokasi berkas

    /// Folder tempat foto drone disimpan di iPhone. Dibuat bila belum ada.
    ///
    /// Memakai Documents milik app — di iOS tidak ada persoalan scoped storage
    /// seperti Android 10+, dan folder ini ikut ter-backup serta bisa dibuka
    /// lewat Files.app bila `UIFileSharingEnabled` dinyalakan.
    func photoDirectory() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(photoDirName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                NSLog("[MediaSync] Gagal membuat folder foto: %@", error.localizedDescription)
            }
        }
        return dir
    }

    /// Semua foto drone yang tersimpan di iPhone, terurut menurut nama.
    func listStoredPhotos() -> [URL] {
        let dir = photoDirectory()
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .filter { isJPEG(fileName: $0.lastPathComponent) && fileSize(of: $0) > 0 }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Sinkronisasi

    /// Unduh semua foto yang belum ada di iPhone.
    ///
    /// Aman dipanggil berulang: berkas yang namanya sudah ada di folder tujuan
    /// dilewati, sehingga tidak ada pengunduhan ganda antar-sesi terbang.
    func syncNewPhotos(
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<SyncResult, PhotoPipelineError>) -> Void
    ) {
        guard !isSyncing else {
            completion(.failure(.message("Sinkronisasi sedang berjalan.")))
            return
        }
        guard let camera = currentCamera() else {
            completion(.failure(.message(
                "Kamera drone tidak tersedia. Pastikan drone menyala dan terhubung.")))
            return
        }
        guard let mediaManager = camera.mediaManager else {
            completion(.failure(.message("MediaManager tidak didukung produk ini.")))
            return
        }

        Self.isSyncInProgress = true
        progress("Memindahkan kamera ke mode unduh...")

        // Dua jalur berbeda tergantung produk: Spark memakai setMode klasik,
        // produk yang lebih baru memakai enterPlayback().
        let afterModeChange: (Error?) -> Void = { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.finish(camera: camera, completion: completion, error: .message(
                    "Gagal masuk mode unduh: \(error.localizedDescription)"))
                return
            }
            self.refreshAndDownload(
                camera: camera, mediaManager: mediaManager,
                progress: progress, completion: completion)
        }

        if camera.isFlatCameraModeSupported() {
            camera.enterPlayback(completion: afterModeChange)
        } else {
            camera.setMode(.mediaDownload, withCompletion: afterModeChange)
        }
    }

    private func refreshAndDownload(
        camera: DJICamera,
        mediaManager: DJIMediaManager,
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<SyncResult, PhotoPipelineError>) -> Void
    ) {
        progress("Menunggu kamera selesai menulis ke kartu SD...")

        // Jeda sebelum membaca daftar — lihat listSettleSeconds.
        downloadQueue.asyncAfter(deadline: .now() + listSettleSeconds) { [weak self] in
            guard let self = self else { return }
            progress("Membaca daftar foto di kartu SD drone...")

            mediaManager.refreshFileList(of: .sdCard) { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    self.finish(camera: camera, completion: completion, error: .message(
                        "Gagal membaca kartu SD: \(error.localizedDescription)"))
                    return
                }

                let files = mediaManager.sdCardFileListSnapshot() ?? []
                let destDir = self.photoDirectory()

                // Buang video/RAW/panorama, dan lewati yang sudah ada di iPhone.
                // `fileName` bertipe String non-optional di SDK iOS (berbeda dari
                // sisi Android yang bisa mengembalikan null), jadi tidak di-bind
                // dengan `guard let`.
                let pending = files.filter { file in
                    let name = file.fileName
                    guard self.isJPEG(fileName: name) else { return false }
                    return !self.alreadyDownloaded(name: name, in: destDir)
                }

                guard !pending.isEmpty else {
                    progress("Tidak ada foto baru.")
                    self.finish(camera: camera, completion: completion, newPhotos: [])
                    return
                }

                progress("Mengunduh \(pending.count) foto baru...")
                self.downloadSequentially(
                    queue: pending, index: 0, total: pending.count,
                    destDir: destDir, downloaded: [],
                    camera: camera, progress: progress, completion: completion)
            }
        }
    }

    /// Unduh satu per satu secara berantai.
    ///
    /// Sengaja SEKUENSIAL, bukan paralel: seluruh berkas mengalir lewat satu
    /// kanal radio yang sama, jadi permintaan berbarengan hanya memperebutkan
    /// bandwidth yang sama dan memperbesar peluang gagal di tengah.
    private func downloadSequentially(
        queue pending: [DJIMediaFile],
        index: Int,
        total: Int,
        destDir: URL,
        downloaded: [URL],
        camera: DJICamera,
        attempt: Int = 1,
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<SyncResult, PhotoPipelineError>) -> Void
    ) {
        guard index < pending.count else {
            finish(camera: camera, completion: completion, newPhotos: downloaded)
            return
        }

        let file = pending[index]
        let name = file.fileName
        let suffix = attempt > 1 ? " (percobaan \(attempt))" : ""
        progress("Mengunduh \(index + 1)/\(total): \(name)\(suffix)")

        download(file: file, named: name, to: destDir) { [weak self] savedURL in
            guard let self = self else { return }

            if let savedURL = savedURL {
                var next = downloaded
                next.append(savedURL)
                self.downloadSequentially(
                    queue: pending, index: index + 1, total: total,
                    destDir: destDir, downloaded: next,
                    camera: camera, attempt: 1,
                    progress: progress, completion: completion)
                return
            }

            // COBA LAGI sebelum menyerah. Transfer lewat radio DJI kerap gagal
            // sesaat karena gangguan sinyal, dan berkas yang baru saja dipotret
            // kadang belum selesai ditulis kamera ke kartu SD saat daftar
            // diambil. Keduanya pulih sendiri pada percobaan berikutnya —
            // menyerah di percobaan pertama membuang foto yang sebenarnya
            // masih bisa diambil.
            if attempt < self.maxDownloadAttempts {
                progress("Gagal \(name), mencoba lagi...")
                self.downloadQueue.asyncAfter(deadline: .now() + self.retryDelaySeconds) {
                    self.downloadSequentially(
                        queue: pending, index: index, total: total,
                        destDir: destDir, downloaded: downloaded,
                        camera: camera, attempt: attempt + 1,
                        progress: progress, completion: completion)
                }
                return
            }

            // Sudah kehabisan percobaan. Satu berkas gagal tidak membatalkan
            // sisanya — lebih baik membawa pulang sebagian foto daripada tidak
            // sama sekali.
            progress("Lewati \(name) (gagal setelah \(self.maxDownloadAttempts) percobaan).")
            self.downloadSequentially(
                queue: pending, index: index + 1, total: total,
                destDir: destDir, downloaded: downloaded,
                camera: camera, attempt: 1,
                progress: progress, completion: completion)
        }
    }

    /// Unduh SATU berkas.
    ///
    /// Potongan data dikumpulkan di memori lalu ditulis SEKALI saat lengkap —
    /// bukan ditulis bertahap ke berkas tujuan. Alasannya penting: kalau
    /// unduhan putus di tengah, penulisan bertahap meninggalkan berkas
    /// separuh jadi yang berukuran > 0, dan `alreadyDownloaded()` akan
    /// menganggapnya sudah lengkap pada sinkronisasi berikutnya — foto rusak
    /// itu lalu ikut terkirim ke backend dan menggagalkan stitching.
    private func download(
        file: DJIMediaFile,
        named name: String,
        to destDir: URL,
        completion: @escaping (URL?) -> Void
    ) {
        var buffer = Data()
        var settled = false

        // Di ObjC selektornya `-fetchFileDataWithOffset:updateQueue:updateBlock:`
        // (terverifikasi dari header framework). Importer Swift mengubahnya DUA
        // kali: kata "File" dibuang dari nama dasar karena mengulang nama kelas
        // pemiliknya (DJIMediaFile), dan label `updateQueue:` dipendekkan jadi
        // `update:` karena tipe parameternya sudah menyebut antrean.
        // Hasil akhirnya `fetchData(withOffset:update:updateBlock:)` — tidak bisa
        // ditebak dari dokumentasi, yang hanya memuat nama ObjC.
        file.fetchData(withOffset: 0, update: downloadQueue) { data, isComplete, error in
            guard !settled else { return }

            if let error = error {
                settled = true
                NSLog("[MediaSync] Gagal mengunduh %@: %@", name, error.localizedDescription)
                completion(nil)
                return
            }

            if let data = data {
                buffer.append(data)
            }

            guard isComplete else { return }
            settled = true

            let target = destDir.appendingPathComponent(name)
            do {
                try buffer.write(to: target, options: .atomic)
                completion(target)
            } catch {
                NSLog("[MediaSync] Gagal menulis %@: %@", name, error.localizedDescription)
                completion(nil)
            }
        }
    }

    // MARK: - Penutup

    private func finish(
        camera: DJICamera,
        completion: @escaping (Result<SyncResult, PhotoPipelineError>) -> Void,
        newPhotos: [URL] = [],
        error: PhotoPipelineError? = nil
    ) {
        restoreShootMode(camera: camera)
        Self.isSyncInProgress = false
        if let error = error {
            completion(.failure(error))
        } else {
            completion(.success(SyncResult(newPhotos: newPhotos, allPhotos: listStoredPhotos())))
        }
    }

    /// Kembalikan kamera ke mode potret, apa pun hasil sinkronisasinya.
    /// Tanpa ini drone tertinggal dalam mode unduh dan tombol shutter diam saja
    /// pada penerbangan berikutnya — gejala yang sangat membingungkan di lapangan.
    private func restoreShootMode(camera: DJICamera) {
        let noop: (Error?) -> Void = { error in
            if let error = error {
                NSLog("[MediaSync] Gagal mengembalikan mode kamera: %@", error.localizedDescription)
            }
        }
        if camera.isFlatCameraModeSupported() {
            camera.exitPlayback(completion: noop)
        } else {
            camera.setMode(.shootPhoto, withCompletion: noop)
        }
    }

    // MARK: - Util

    private func currentCamera() -> DJICamera? {
        (DJISDKManager.product() as? DJIAircraft)?.camera
    }

    /// Disaring berdasarkan NAMA BERKAS, bukan `mediaType`, supaya cocok persis
    /// dengan yang diterima backend — backend menolak seluruh batch bila ada
    /// satu berkas berekstensi lain.
    private func isJPEG(fileName: String) -> Bool {
        let lower = fileName.lowercased()
        return lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg")
    }

    private func alreadyDownloaded(name: String, in dir: URL) -> Bool {
        let target = dir.appendingPathComponent(name)
        // Berkas berukuran 0 dianggap belum lengkap sehingga diunduh ulang.
        return FileManager.default.fileExists(atPath: target.path) && fileSize(of: target) > 0
    }

    private func fileSize(of url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }
}
