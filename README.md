# ZackStore — Build APK dari HP

Project ini sudah disiapkan untuk dibuild memakai GitHub Actions, jadi tidak perlu PC/laptop untuk proses compile Android.

## Isi
- `www/index.html` — ZackStore UI + koneksi Supabase yang sudah dikonfigurasi.
- `package.json` — Capacitor 8.
- `capacitor.config.ts` — app id `com.zackstore.app`.
- `.github/workflows/build-apk.yml` — otomatis membuat APK debug di cloud.
- `supabase/zackstore_supabase_migration.sql` — migration tambahan Storage/paket.

## Build dari HP lewat GitHub
1. Buat repository baru di GitHub, misalnya `zackstore-app`.
2. Upload SEMUA isi folder project ini ke root repository (bukan folder pembungkus `ZackStore-CloudBuild`). Pastikan `package.json`, `capacitor.config.ts`, `www`, dan `.github` berada di root.
3. Buka tab **Actions** pada repository.
4. Pilih workflow **Build ZackStore APK**.
5. Tekan **Run workflow**. Workflow juga otomatis jalan setelah push ke branch `main`.
6. Tunggu sampai job selesai.
7. Buka hasil workflow → bagian **Artifacts** → download `ZackStore-debug-apk`.
8. Extract artifact ZIP lalu install `app-debug.apk` di Android.

## Catatan keamanan
- Publishable key Supabase boleh berada di frontend/APK.
- Jangan pernah memasukkan `service_role` atau secret key ke frontend/APK.
- Debug APK cocok untuk testing. Untuk rilis Play Store, perlu signing/release build.
