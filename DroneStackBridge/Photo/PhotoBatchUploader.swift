//
//  PhotoBatchUploader.swift
//  DroneStackBridge
//
//  PENGHUBUNG FOTO TAHAP 2 — mengirim foto dari iPhone ke backend FastAPI di
//  laptop (`POST /jobs/stitch`), yang lalu menjahitnya jadi orthophoto dan
//  mengklasifikasi kesiapan panen.
//
//  Port dari PhotoBatchUploader.java sisi Android.
//
//  MENGAPA SATU REQUEST BERISI BANYAK FOTO
//  ---------------------------------------
//  Backend MENOLAK job berisi kurang dari `minPhotos` foto ("Minimum 4 foto,
//  dapat N" — lihat submit_stitch_job() di backend_ai/api.py) karena stitching
//  mustahil dari satu gambar. Karena itu kelas ini mengunggah SATU BATCH dalam
//  SATU permintaan multipart. Pola satu-berkas-per-request akan selalu ditolak
//  HTTP 400 sebelum job apa pun terbentuk.
//

import Foundation

final class PhotoBatchUploader {

    /// Ambang minimum milik backend; dicek lebih dulu di sini supaya pesannya
    /// menjelaskan apa yang harus dilakukan operator, bukan sekadar HTTP 400.
    static let minPhotos = 4

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        // Batas waktu dilonggarkan jauh di atas bawaan: satu batch survei bisa
        // puluhan foto belasan MB lewat WiFi.
        //   timeoutIntervalForRequest  = jeda MENGANGGUR yang ditoleransi
        //   timeoutIntervalForResource = batas total seluruh transfer
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: configuration)
    }

    /// Unggah satu batch foto sebagai satu job stitching.
    ///
    /// - Parameters:
    ///   - serverIp: IP laptop yang menjalankan backend.
    ///   - port: port FastAPI, biasanya 8000.
    ///   - photos: daftar foto JPG; minimal `minPhotos`.
    func uploadBatch(
        serverIp: String,
        port: Int,
        photos: [URL],
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<(jobId: String, photoCount: Int), PhotoPipelineError>) -> Void
    ) {
        guard photos.count >= Self.minPhotos else {
            completion(.failure(.message(
                "Butuh minimal \(Self.minPhotos) foto untuk stitching, tersedia \(photos.count). "
                + "Ambil foto lagi lalu sinkronkan ulang.")))
            return
        }

        // Backend hanya menerima .jpg/.jpeg dan menolak SELURUH batch bila ada
        // satu berkas berekstensi lain, jadi disaring di sisi ini dulu.
        let valid = photos.filter { url in
            let lower = url.lastPathComponent.lowercased()
            let isJpeg = lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg")
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if !isJpeg { NSLog("[PhotoUpload] Lewati berkas non-JPG: %@", url.lastPathComponent) }
            return isJpeg && size > 0
        }

        guard valid.count >= Self.minPhotos else {
            completion(.failure(.message(
                "Hanya \(valid.count) foto JPG yang valid; backend butuh \(Self.minPhotos).")))
            return
        }

        let boundary = "----DroneStackBridge-\(UUID().uuidString)"
        let bodyURL: URL
        let totalBytes: Int
        do {
            (bodyURL, totalBytes) = try writeMultipartBody(photos: valid, boundary: boundary)
        } catch {
            completion(.failure(.message("Gagal menyiapkan data unggahan: \(error.localizedDescription)")))
            return
        }

        guard let url = URL(string: "http://\(serverIp):\(port)/jobs/stitch") else {
            try? FileManager.default.removeItem(at: bodyURL)
            completion(.failure(.message("Alamat backend tidak valid: \(serverIp):\(port)")))
            return
        }

        progress("Mengunggah \(valid.count) foto (\(totalBytes / (1024 * 1024)) MB) ke \(serverIp)...")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // uploadTask(with:fromFile:) MENGALIRKAN body dari disk. Memuat seluruh
        // batch ke memori lebih dulu berisiko kehabisan memori: 30 foto x 12 MB
        // sudah lebih dari 350 MB, dan iOS mematikan app jauh sebelum itu.
        let task = session.uploadTask(with: request, fromFile: bodyURL) { data, response, error in
            try? FileManager.default.removeItem(at: bodyURL)

            if let error = error {
                completion(.failure(.message(
                    "Tidak bisa menghubungi backend di \(url.absoluteString): \(error.localizedDescription)")))
                return
            }

            let bodyText = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            guard (200..<300).contains(status) else {
                // Detail dari FastAPI ikut ditampilkan; pesannya menjelaskan
                // sebab penolakan jauh lebih baik daripada kode statusnya.
                completion(.failure(.message(
                    "Backend menolak (HTTP \(status)): \(Self.extractDetail(bodyText))")))
                return
            }

            guard let jobId = Self.extractJobId(bodyText), !jobId.isEmpty else {
                completion(.failure(.message("Balasan backend tidak memuat job_id: \(bodyText)")))
                return
            }

            NSLog("[PhotoUpload] Job stitching dibuat: %@", jobId)
            completion(.success((jobId: jobId, photoCount: valid.count)))
        }
        task.resume()
    }

    // MARK: - Penyusunan body

    /// Tulis body multipart ke berkas sementara, membaca tiap foto per potongan
    /// supaya tidak ada berkas utuh yang pernah berada di memori sekaligus.
    private func writeMultipartBody(photos: [URL], boundary: String) throws -> (URL, Int) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString).multipart")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)

        let handle = try FileHandle(forWritingTo: tempURL)
        defer { try? handle.close() }

        var totalBytes = 0
        let newline = "\r\n"

        for photo in photos {
            let name = photo.lastPathComponent
            // Nama field "images" DIULANG untuk tiap berkas — inilah bentuk yang
            // dibaca FastAPI sebagai list[UploadFile] (images: list[UploadFile]).
            var header = "--\(boundary)\(newline)"
            header += "Content-Disposition: form-data; name=\"images\"; filename=\"\(name)\"\(newline)"
            header += "Content-Type: image/jpeg\(newline)\(newline)"
            try handle.write(contentsOf: Data(header.utf8))

            let reader = try FileHandle(forReadingFrom: photo)
            defer { try? reader.close() }
            while let chunk = try reader.read(upToCount: 1024 * 512), !chunk.isEmpty {
                try handle.write(contentsOf: chunk)
                totalBytes += chunk.count
            }

            try handle.write(contentsOf: Data(newline.utf8))
        }

        try handle.write(contentsOf: Data("--\(boundary)--\(newline)".utf8))
        return (tempURL, totalBytes)
    }

    // MARK: - Pembacaan balasan

    private static func extractJobId(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["job_id"] as? String
    }

    /// FastAPI membungkus pesan kesalahan di field "detail".
    private static func extractDetail(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = object["detail"] as? String,
              !detail.isEmpty
        else { return json }
        return detail
    }
}
