# Sin Coffee · QR Order

- `site/` : website (pelanggan, barista, owner, Pengaturan, cetak QR). Dipublikasikan ke Netlify.
- `supabase/` : SQL dan Edge Functions untuk Supabase. Dijalankan manual di Supabase.

Secret (Server Key Midtrans, dll.) TIDAK disimpan di repo. Isi lewat dashboard Supabase.

## Urutan SQL di Supabase
1. `sincoffee_supabase.sql`
2. `sincoffee_menu_sin_coffee.sql`
3. `sincoffee_pengguna_menu.sql`
4. `sincoffee_doku.sql` (sudah pernah dijalankan)
5. `sincoffee_midtrans.sql`

## Deploy
Setiap push ke branch `main` otomatis dipublikasikan oleh Netlify (setelah repo dihubungkan di Netlify).
