# Sin Coffee QR Order · Panduan Netlify + Supabase

Website berjalan di Netlify. Data, login staf, dan semua aturan pesanan ada di Supabase. Pembayaran masih **simulasi**.

Ada dua file:

| File | Untuk |
| --- | --- |
| `sincoffee_supabase.sql` | Dijalankan sekali di Supabase |
| `sincoffee-netlify.zip` | Diupload ke Netlify |

## 1. Pasang database di Supabase (sekali saja)

1. Buka project Supabase → **SQL Editor** → **New query**.
2. Buka `sincoffee_supabase.sql`, salin **seluruh** isinya, tempel, lalu tekan **Run**.
3. Pastikan hasilnya "Success". File ini sudah berisi menu, 12 meja, PIN staf, dan 30 pesanan contoh.

File ini juga menghapus tabel dari percobaan versi PHP sebelumnya, jadi aman dijalankan meskipun file sebelumnya sudah pernah dicoba.

## 2. Ambil kunci Supabase

Supabase → **Project Settings** → **API** (atau tombol **Connect**). Catat:

- **Project URL**, misalnya `https://abcdefghijkl.supabase.co`
- **anon public key** (teks panjang yang diawali `eyJ...`, atau `sb_publishable_...`)

Jangan pakai **service_role key**. Kunci itu rahasia dan tidak boleh ada di website.

## 3. Isi kunci, lalu upload ke Netlify

1. Ekstrak `sincoffee-netlify.zip`.
2. Buka `assets/config.js` dengan Notepad, lalu ganti dua baris berikut:
   ```js
   url: 'https://abcdefghijkl.supabase.co',
   anonKey: 'eyJhbGciOi...'
   ```
3. Simpan, lalu **zip ulang isi folder** (bukan foldernya). File `index.html` harus berada paling atas di dalam zip.
4. Netlify → **Add new site** → **Deploy manually**, lalu seret zip atau foldernya ke sana. Jika situs sudah ada: **Deploys** → seret ke kotak upload.

Penyebab 404 sebelumnya: zip berisi file PHP di dalam subfolder. Netlify tidak menjalankan PHP, dan `index.html` tidak ada di paling atas.

## 4. Halaman

| Alamat | Untuk | PIN demo |
| --- | --- | --- |
| `/` | Halaman awal, berisi link untuk staf | |
| `/index.html?t=TOKEN` | Pelanggan (dibuka dari QR meja) | |
| `/barista.html` | Layar barista | Barista `1234` |
| `/ringkasan.html` | Ringkasan owner | Owner `9999` |
| `/qr.html` | Cetak QR meja | Owner `9999` |

**QR meja:** buka `/qr.html` dari alamat Netlify Bapak, lalu Ctrl+P. QR otomatis berisi alamat Netlify itu.

**Penting:** setiap kali `sincoffee_supabase.sql` dijalankan ulang, token QR dibuat baru. Cetak ulang QR setelahnya.

## 5. Skenario demo di depan owner

1. Laptop: buka `/ringkasan.html` (PIN 9999).
2. Tablet atau tab kedua: buka `/barista.html` (PIN 1234), lalu tekan **Aktifkan suara pesanan baru**.
3. HP: scan QR Meja 5, pesan, isi nama, lalu **Bayar sekarang** → **Bayar berhasil** (kotak demo).
4. Barista: **Mulai proses** → **Tandai siap**. HP pelanggan berbunyi dan menampilkan "Pesanan siap".
5. Ringkasan: pesanan muncul di omzet, grafik, tabel, dan log.

Kasus tambahan: **Pembayaran gagal**, **Bayar, webhook hilang** (sistem cek sendiri dalam 10 detik), **Webhook palsu** (ditolak), menu habis (hilangkan centang di layar barista).

Setelah latihan, tekan **Reset data demo** di bawah Ringkasan.

## Mengganti PIN

Supabase → SQL Editor, jalankan (ganti `4821`):

```sql
UPDATE sincoffee.pengguna SET pin_hash = extensions.crypt('4821', extensions.gen_salt('bf')) WHERE peran = 'owner';
UPDATE sincoffee.pengguna SET pin_hash = extensions.crypt('5730', extensions.gen_salt('bf')) WHERE peran = 'barista';
```

## Mengubah menu dan harga

Supabase → Table Editor → pilih schema **sincoffee** → tabel `menu` (nama, kategori) dan `menu_gerai` (harga, tersedia).

## Keamanan

- Semua tabel berada di schema `sincoffee`, yang tidak terbuka ke API publik Supabase.
- Website hanya bisa memanggil fungsi `sc_*`. Fungsi-fungsi itu yang memeriksa token QR, PIN, harga, dan urutan status.
- Harga selalu dihitung ulang di database. Harga yang dikirim browser diabaikan.
- Login staf dibatasi: setelah 20 PIN salah dalam 10 menit, login dikunci sementara.

## Jika ada masalah

| Pesan | Penyebab |
| --- | --- |
| "Aplikasi belum diatur" | `assets/config.js` belum diisi |
| "Kunci Supabase salah" | anon key salah atau terpotong |
| "Fungsi database belum dipasang" | SQL belum dijalankan. Jika sudah, tunggu 1 menit lalu muat ulang |
| "QR meja tidak dikenali" | QR dicetak sebelum SQL dijalankan ulang. Cetak ulang dari `/qr.html` |
| Notifikasi HP tidak muncul | Izinkan notifikasi di browser HP. Bunyi dan banner tetap muncul selama halaman terbuka. Di iPhone, notifikasi sistem hanya jalan jika web ditambahkan ke Home Screen |

## Belum termasuk (sesuai ruang lingkup MVP)

Payment gateway asli, integrasi Accurate/GoFood/GrabFood, stok, dan absensi. Saat gateway dipilih, webhook-nya dipasang sebagai Supabase Edge Function yang memanggil fungsi `sincoffee.proses_webhook` yang sudah ada.
