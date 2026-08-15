//
//  ContentView.swift
//  DroneStackBridge
//
//  Satu layar. App ini dipakai sambil memegang remote di lapangan, jadi
//  prioritasnya bukan kelengkapan fitur melainkan menjawab satu pertanyaan
//  dengan sekali lihat: "apakah jalurnya sudah tersambung sampai ujung?"
//

import SwiftUI

struct ContentView: View {

    @StateObject private var coordinator = BridgeCoordinator()

    var body: some View {
        NavigationView {
            Form {
                connectionSection
                statusSection
                actionSection
                photoSection
                logSection
            }
            .navigationTitle("drone-stack Bridge")
        }
        .navigationViewStyle(.stack)
        .onAppear { coordinator.onAppear() }
    }

    // MARK: - Bagian

    private var connectionSection: some View {
        Section("Laptop (rosbridge)") {
            HStack {
                Text("IP")
                    .frame(width: 44, alignment: .leading)
                TextField("192.168.1.10", text: $coordinator.host)
                    .keyboardType(.decimalPad)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .disabled(coordinator.bridgeConnected)
            }
            HStack {
                Text("Port")
                    .frame(width: 44, alignment: .leading)
                TextField("9090", text: $coordinator.port)
                    .keyboardType(.numberPad)
                    .disabled(coordinator.bridgeConnected)
            }
            Text("Jalankan `./scripts/start.sh --dji` di laptop, lalu isi IP yang "
                 + "ditampilkan skrip itu.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var statusSection: some View {
        Section("Status") {
            statusRow("Registrasi SDK", ok: coordinator.sdkRegistered)
            statusRow("Drone tersambung", ok: coordinator.productConnected,
                      detail: coordinator.productModel)
            statusRow("Virtual Stick", ok: coordinator.virtualStickActive)
            statusRow("Jembatan rosbridge", ok: coordinator.bridgeConnected)

            Text(coordinator.statusLine)
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actionSection: some View {
        Section {
            if coordinator.bridgeConnected {
                Button(role: .destructive) {
                    coordinator.disconnect()
                } label: {
                    Text("Putuskan Jembatan").frame(maxWidth: .infinity)
                }
            } else {
                Button {
                    coordinator.connect()
                } label: {
                    Text("Sambungkan Jembatan").frame(maxWidth: .infinity)
                }
                .disabled(!coordinator.productConnected)
            }
        } footer: {
            // Peringatan ini sengaja ada di layar utama, bukan di README yang
            // tidak akan dibaca ulang di lapangan.
            Text("Selama jembatan aktif, dashboard mengendalikan drone lewat "
                 + "virtual stick. Pegang terus remote fisik: menekan tombol "
                 + "pause/RTH di remote adalah cara tercepat mengambil alih.")
                .font(.caption)
        }
    }

    /// Jalur foto: kartu SD drone -> iPhone -> backend FastAPI (port 8000).
    ///
    /// IP-nya memakai ULANG field di bagian atas — rosbridge (9090) dan backend
    /// (8000) diasumsikan di mesin yang sama, persis seperti sisi Android.
    private var photoSection: some View {
        Section {
            Button {
                coordinator.syncPhotos()
            } label: {
                HStack {
                    if coordinator.photoSyncing {
                        ProgressView()
                        Text("Sync...").padding(.leading, 4)
                    } else {
                        Image(systemName: "photo.on.rectangle.angled")
                        Text("Sync Foto ke Backend")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            // Hanya butuh kamera — jembatan rosbridge tidak harus aktif.
            .disabled(coordinator.photoSyncing || !coordinator.productConnected)

            HStack {
                Text("Foto tersimpan di HP")
                Spacer()
                Text("\(coordinator.storedPhotoCount)")
                    .foregroundColor(.secondary)
            }
            .font(.caption)

            if coordinator.storedPhotoCount >= 4 {
                Button("Unggah Ulang Tanpa Drone") {
                    coordinator.reuploadStoredPhotos()
                }
                .font(.caption)
                .disabled(coordinator.photoSyncing)
            }

            if let jobId = coordinator.lastJobId {
                HStack {
                    Text("Job stitching")
                    Spacer()
                    Text(jobId)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .font(.caption)
            }
        } header: {
            Text("Foto (backend :\(String(BridgeSettings.defaultBackendPort)))")
        } footer: {
            Text("Pengunduhan memindahkan kamera ke mode unduh, jadi drone tidak "
                 + "bisa memotret selama proses ini — jalankan SETELAH misi selesai. "
                 + "Backend menolak job di bawah 4 foto.")
                .font(.caption)
        }
    }

    private var logSection: some View {
        Section("Log") {
            if coordinator.logLines.isEmpty {
                Text("Belum ada aktivitas.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                // Terbaru di atas: yang dicari operator saat ada masalah selalu
                // kejadian paling akhir.
                ForEach(Array(coordinator.logLines.reversed().enumerated()), id: \.offset) { item in
                    Text(item.element)
                        .font(.system(.caption, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Komponen kecil

    private func statusRow(_ title: String, ok: Bool, detail: String? = nil) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundColor(ok ? .green : .secondary)
            Text(title)
            Spacer()
            if let detail = detail, ok {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
