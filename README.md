# ZackStore Production Package

Isi utama:
- `www/index.html` — frontend ZackStore
- `supabase/zackstore_supabase_migration.sql` — migration backend final
- `resources/icon.png` — icon Android 1254x1254 PNG
- `package.json` + `capacitor.config.ts` — Capacitor Android
- `.github/workflows/build-apk.yml` — build APK otomatis di GitHub Actions

## Urutan final
1. Pastikan Supabase project memakai URL dan publishable key yang benar di frontend.
2. Jalankan `supabase/zackstore_supabase_migration.sql` sekali di Supabase SQL Editor setelah fitur dianggap final.
3. Push isi folder ini ke repository GitHub.
4. Jalankan Actions `Build ZackStore APK`.
5. Ambil artifact `ZackStore-APK`.

Jangan masukkan Supabase service-role key ke frontend atau repository.
