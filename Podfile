# Podfile — DroneStackBridge (iOS)
#
# Target minimum iOS 15.0. DJI MSDK 4.16.2 sendiri mendukung iOS 9.0+, jadi
# 15.0 dipilih karena kebutuhan sisi app (SwiftUI + async/await), bukan karena
# batasan SDK.
#
# Setelah `pod install`, BUKA .xcworkspace — bukan .xcodeproj. Membuka
# .xcodeproj membuat Xcode tidak melihat pod sama sekali dan `import DJISDK`
# gagal dengan "no such module".

platform :ios, '15.0'

# CDN, BUKAN 'https://github.com/CocoaPods/Specs.git' seperti di sample DJI.
# Sumber git memaksa CocoaPods meng-clone SELURUH repo spesifikasi (lebih dari
# 1 GB) sebelum pod pertama terpasang — di GitHub Actions itu memakan menit
# runner macOS yang mahal, setiap kali build. CDN mengambil hanya spesifikasi
# yang dibutuhkan; isi pod-nya sama persis.
source 'https://cdn.cocoapods.org/'

target 'DroneStackBridge' do
  # SDK utama. Versi ini sama dengan yang ada di folder Mobile-SDK-iOS-master
  # yang sudah didownload (lihat DJI-SDK-iOS.podspec di sana).
  pod 'DJI-SDK-iOS', '~> 4.16.2'

  # Basis data FlySafe/GEO. Bukan syarat mutlak untuk terbang, tapi disertakan
  # sample resmi DJI dan mencegah sebagian kegagalan registrasi di wilayah
  # dengan zona terbatas. Boleh dihapus kalau `pod install` bermasalah.
  pod 'DJIFlySafeDatabaseResource', '~> 01.00.01.18'

  # CATATAN: DJIWidget SENGAJA TIDAK dipakai.
  # Pod itu hanya diperlukan untuk decoding & menampilkan video feed. Jembatan
  # ini tidak menampilkan video sama sekali, jadi menambahkannya hanya
  # memperbesar app dan memperpanjang waktu build.
end

# DJISDK.framework tidak menyediakan slice arm64 untuk simulator, jadi build
# simulator akan gagal saat linking bila arsitektur ini tidak dikecualikan.
# Praktisnya tidak menghalangi apa pun: app ini WAJIB dijalankan di iPhone asli
# karena butuh koneksi ke drone.
post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['EXCLUDED_ARCHS[sdk=iphonesimulator*]'] = 'arm64'
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
    end
  end
end
