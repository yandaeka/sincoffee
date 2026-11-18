-- =====================================================================
-- Sin Coffee QR Order · Versi Netlify + Supabase
-- Jalankan SEKALI di Supabase: SQL Editor > New query > tempel semua > Run.
--
-- Struktur:
--   schema "sincoffee"  : semua tabel + fungsi internal (TIDAK terbuka ke API publik)
--   schema "public"     : fungsi sc_* sebagai API yang dipanggil website
-- Website hanya memakai anon key dan hanya bisa memanggil fungsi sc_*.
-- Fungsi-fungsi itu yang memeriksa token QR, PIN staf, harga, dan status.
--
-- PERHATIAN: file ini menghapus data Sin Coffee lama (schema sincoffee dan
-- tabel versi sebelumnya di schema public) lalu membuat ulang.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- Bersihkan tabel dari percobaan versi PHP sebelumnya (jika pernah dijalankan)
DROP TABLE IF EXISTS public.outbox, public.rekonsiliasi, public.log_aktivitas, public.notifikasi,
  public.riwayat_status, public.webhook_event, public.pembayaran, public.pesanan_item, public.pesanan,
  public.nomor_urut, public.meja_qr, public.menu_gerai, public.menu, public.pengguna, public.gerai CASCADE;

-- Hapus fungsi API versi lama (jika file ini dijalankan ulang)
DO $$
DECLARE f RECORD;
BEGIN
  FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'public' AND p.proname LIKE 'sc\_%' LOOP
    EXECUTE format('DROP FUNCTION %s', f.sig);
  END LOOP;
END $$;

DROP SCHEMA IF EXISTS sincoffee CASCADE;
CREATE SCHEMA sincoffee;
REVOKE ALL ON SCHEMA sincoffee FROM PUBLIC;

SET search_path = sincoffee, public, extensions;

-- ---------------------------------------------------------------------
-- Pengaturan
-- ---------------------------------------------------------------------
CREATE TABLE sincoffee.pengaturan (
  kunci  TEXT PRIMARY KEY,
  nilai  TEXT NOT NULL
);
INSERT INTO sincoffee.pengaturan VALUES
  ('mode_demo', '1'),                         -- 1 = pembayaran simulasi
  ('batas_bayar_menit', '15'),
  ('cek_status_setelah_detik', '10'),          -- produksi: 120
  ('zona_waktu', 'Asia/Makassar'),             -- WITA, Palu
  ('webhook_secret', encode(extensions.gen_random_bytes(24), 'hex'));

-- ---------------------------------------------------------------------
-- Master
-- ---------------------------------------------------------------------
CREATE TABLE sincoffee.gerai (
  id              SERIAL PRIMARY KEY,
  kode            VARCHAR(10)  NOT NULL UNIQUE,
  nama            VARCHAR(100) NOT NULL,
  alamat          VARCHAR(200),
  aktif           BOOLEAN      NOT NULL DEFAULT TRUE,
  kode_eksternal  VARCHAR(50),                 -- disiapkan untuk Accurate
  dibuat_pada     TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE sincoffee.pengguna (
  id          SERIAL PRIMARY KEY,
  gerai_id    INTEGER REFERENCES sincoffee.gerai(id),   -- NULL = semua gerai (owner)
  nama        VARCHAR(100) NOT NULL,
  peran       VARCHAR(10)  NOT NULL CHECK (peran IN ('owner','admin','barista')),
  pin_hash    TEXT         NOT NULL,
  aktif       BOOLEAN      NOT NULL DEFAULT TRUE,
  dibuat_pada TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE sincoffee.sesi_staf (
  token        TEXT PRIMARY KEY,
  pengguna_id  INTEGER NOT NULL REFERENCES sincoffee.pengguna(id) ON DELETE CASCADE,
  dibuat_pada  TIMESTAMPTZ NOT NULL DEFAULT now(),
  berlaku_sampai TIMESTAMPTZ NOT NULL
);

CREATE TABLE sincoffee.percobaan_login (
  id     SERIAL PRIMARY KEY,
  waktu  TIMESTAMPTZ NOT NULL DEFAULT now(),
  berhasil BOOLEAN NOT NULL
);

CREATE TABLE sincoffee.menu (
  id              SERIAL PRIMARY KEY,
  kode            VARCHAR(20)  NOT NULL UNIQUE,
  kategori        VARCHAR(50)  NOT NULL,
  nama            VARCHAR(100) NOT NULL,
  deskripsi       VARCHAR(200),
  pilihan_suhu    VARCHAR(50),                 -- dipisah koma, mis. Es,Panas
  pilihan_manis   BOOLEAN      NOT NULL DEFAULT FALSE,
  urutan          INTEGER      NOT NULL DEFAULT 0,
  aktif           BOOLEAN      NOT NULL DEFAULT TRUE,
  kode_eksternal  VARCHAR(50)                  -- kode barang di Accurate
);

CREATE TABLE sincoffee.menu_gerai (
  menu_id   INTEGER NOT NULL REFERENCES sincoffee.menu(id),
  gerai_id  INTEGER NOT NULL REFERENCES sincoffee.gerai(id),
  harga     INTEGER NOT NULL CHECK (harga >= 0),
  tersedia  BOOLEAN NOT NULL DEFAULT TRUE,
  PRIMARY KEY (menu_id, gerai_id)
);

CREATE TABLE sincoffee.meja_qr (
  id         SERIAL PRIMARY KEY,
  gerai_id   INTEGER     NOT NULL REFERENCES sincoffee.gerai(id),
  kode_meja  VARCHAR(20) NOT NULL,
  token      CHAR(32)    NOT NULL UNIQUE,      -- acak, isi QR
  aktif      BOOLEAN     NOT NULL DEFAULT TRUE,
  UNIQUE (gerai_id, kode_meja)
);

CREATE TABLE sincoffee.nomor_urut (
  gerai_id  INTEGER NOT NULL,
  tanggal   DATE    NOT NULL,
  terakhir  INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (gerai_id, tanggal)
);

-- ---------------------------------------------------------------------
-- Transaksi
-- ---------------------------------------------------------------------
CREATE TABLE sincoffee.pesanan (
  id                UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  nomor_pesanan     VARCHAR(30)  NOT NULL,      -- mis. PLU01-1029-0042
  gerai_id          INTEGER      NOT NULL REFERENCES sincoffee.gerai(id),
  meja_qr_id        INTEGER      REFERENCES sincoffee.meja_qr(id),
  nama_pelanggan    VARCHAR(60),
  status_bayar      VARCHAR(12)  NOT NULL DEFAULT 'BELUM_BAYAR'
                    CHECK (status_bayar IN ('BELUM_BAYAR','LUNAS','GAGAL','KEDALUWARSA','DIBATALKAN')),
  status_produksi   VARCHAR(10)  CHECK (status_produksi IN ('MENUNGGU','DIPROSES','SIAP','SELESAI')),
  total             INTEGER      NOT NULL CHECK (total >= 0),
  kunci_idempotensi VARCHAR(64)  NOT NULL UNIQUE,
  bayar_terlambat   BOOLEAN      NOT NULL DEFAULT FALSE,
  is_contoh         BOOLEAN      NOT NULL DEFAULT FALSE,
  dibuat_pada       TIMESTAMPTZ  NOT NULL DEFAULT now(),
  dibayar_pada      TIMESTAMPTZ,
  siap_pada         TIMESTAMPTZ,
  selesai_pada      TIMESTAMPTZ,
  UNIQUE (gerai_id, nomor_pesanan)
);
CREATE INDEX ON sincoffee.pesanan (gerai_id, status_bayar, status_produksi);
CREATE INDEX ON sincoffee.pesanan (gerai_id, dibuat_pada);

CREATE TABLE sincoffee.pesanan_item (
  id          SERIAL PRIMARY KEY,
  pesanan_id  UUID         NOT NULL REFERENCES sincoffee.pesanan(id) ON DELETE CASCADE,
  menu_id     INTEGER      NOT NULL REFERENCES sincoffee.menu(id),
  nama        VARCHAR(100) NOT NULL,            -- snapshot saat pesan
  harga       INTEGER      NOT NULL,            -- snapshot saat pesan
  qty         INTEGER      NOT NULL CHECK (qty > 0),
  suhu        VARCHAR(20),
  manis       VARCHAR(20),
  catatan     VARCHAR(200)
);
CREATE INDEX ON sincoffee.pesanan_item (pesanan_id);

CREATE TABLE sincoffee.pembayaran (
  id                SERIAL PRIMARY KEY,
  pesanan_id        UUID        NOT NULL REFERENCES sincoffee.pesanan(id) ON DELETE CASCADE,
  gateway           VARCHAR(20) NOT NULL DEFAULT 'SIMULASI',
  gateway_order_id  VARCHAR(64) NOT NULL UNIQUE,
  metode            VARCHAR(20) NOT NULL DEFAULT 'QRIS',
  jumlah            INTEGER     NOT NULL,
  status            VARCHAR(12) NOT NULL DEFAULT 'PENDING'
                    CHECK (status IN ('PENDING','LUNAS','GAGAL','KEDALUWARSA','DIBATALKAN')),
  status_gateway    VARCHAR(20) NOT NULL DEFAULT 'pending',   -- hasil cek status ke gateway
  kedaluwarsa_pada  TIMESTAMPTZ NOT NULL,
  dibayar_pada      TIMESTAMPTZ,
  dibuat_pada       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ON sincoffee.pembayaran (pesanan_id);

CREATE TABLE sincoffee.webhook_event (
  id                  SERIAL PRIMARY KEY,
  gateway             VARCHAR(20) NOT NULL,
  event_id            VARCHAR(64) UNIQUE,       -- NULL untuk event bertanda tangan tidak valid
  gateway_order_id    VARCHAR(64),
  payload             TEXT        NOT NULL,
  tanda_tangan_valid  BOOLEAN     NOT NULL,
  hasil               VARCHAR(40),
  diterima_pada       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE sincoffee.riwayat_status (
  id          SERIAL PRIMARY KEY,
  pesanan_id  UUID        NOT NULL REFERENCES sincoffee.pesanan(id) ON DELETE CASCADE,
  jenis       VARCHAR(10) NOT NULL CHECK (jenis IN ('bayar','produksi')),
  dari        VARCHAR(20),
  ke          VARCHAR(20) NOT NULL,
  oleh        VARCHAR(60) NOT NULL,
  waktu       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE sincoffee.notifikasi (
  id               SERIAL PRIMARY KEY,
  pesanan_id       UUID        NOT NULL REFERENCES sincoffee.pesanan(id) ON DELETE CASCADE,
  kanal            VARCHAR(20) NOT NULL,
  status           VARCHAR(10) NOT NULL DEFAULT 'ANTRE' CHECK (status IN ('ANTRE','TERKIRIM','GAGAL')),
  percobaan        INTEGER     NOT NULL DEFAULT 0,
  kirim_berikutnya TIMESTAMPTZ,
  error_terakhir   VARCHAR(200),
  dibuat_pada      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE sincoffee.log_aktivitas (
  id        SERIAL PRIMARY KEY,
  gerai_id  INTEGER,
  tag       VARCHAR(12)  NOT NULL,
  tingkat   VARCHAR(5)   NOT NULL DEFAULT 'info' CHECK (tingkat IN ('info','ok','warn','err')),
  pesan     VARCHAR(255) NOT NULL,
  detail    VARCHAR(255),
  waktu     TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE sincoffee.rekonsiliasi (
  id             SERIAL PRIMARY KEY,
  gerai_id       INTEGER NOT NULL,
  tanggal        DATE    NOT NULL,
  total_sistem   BIGINT  NOT NULL,
  total_gateway  BIGINT  NOT NULL,
  selisih        BIGINT  NOT NULL,
  status         VARCHAR(10) NOT NULL CHECK (status IN ('BERSIH','PERLU_CEK')),
  dibuat_pada    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (gerai_id, tanggal)
);

-- Antrean event untuk integrasi berikutnya (Accurate). Belum dipakai di MVP.
CREATE TABLE sincoffee.outbox (
  id             SERIAL PRIMARY KEY,
  jenis          VARCHAR(40) NOT NULL,
  payload        JSONB       NOT NULL,
  dibuat_pada    TIMESTAMPTZ NOT NULL DEFAULT now(),
  terkirim_pada  TIMESTAMPTZ
);

-- =====================================================================
-- FUNGSI INTERNAL (schema sincoffee, tidak bisa dipanggil dari website)
-- =====================================================================
CREATE FUNCTION sincoffee.cfg(k TEXT) RETURNS TEXT LANGUAGE sql STABLE AS
$$ SELECT nilai FROM sincoffee.pengaturan WHERE kunci = k $$;

CREATE FUNCTION sincoffee.tz() RETURNS TEXT LANGUAGE sql STABLE AS
$$ SELECT COALESCE(sincoffee.cfg('zona_waktu'), 'Asia/Makassar') $$;

CREATE FUNCTION sincoffee.lokal(t TIMESTAMPTZ, fmt TEXT) RETURNS TEXT LANGUAGE sql STABLE AS
$$ SELECT CASE WHEN t IS NULL THEN NULL ELSE to_char(t AT TIME ZONE sincoffee.tz(), fmt) END $$;

CREATE FUNCTION sincoffee.catat(p_gerai INTEGER, p_tag TEXT, p_tingkat TEXT, p_pesan TEXT, p_detail TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE sql AS $$
  INSERT INTO sincoffee.log_aktivitas (gerai_id, tag, tingkat, pesan, detail)
  VALUES (p_gerai, p_tag, p_tingkat, left(p_pesan, 255), left(p_detail, 255));
$$;

CREATE FUNCTION sincoffee.riwayat(p_id UUID, p_jenis TEXT, p_dari TEXT, p_ke TEXT, p_oleh TEXT)
RETURNS VOID LANGUAGE sql AS $$
  INSERT INTO sincoffee.riwayat_status (pesanan_id, jenis, dari, ke, oleh) VALUES (p_id, p_jenis, p_dari, p_ke, p_oleh);
$$;

CREATE FUNCTION sincoffee.rp(n BIGINT) RETURNS TEXT LANGUAGE sql IMMUTABLE AS
$$ SELECT 'Rp ' || replace(to_char(n, 'FM999G999G999'), ',', '.') $$;

CREATE FUNCTION sincoffee.err(msg TEXT, code INTEGER DEFAULT 400) RETURNS JSON LANGUAGE sql IMMUTABLE AS
$$ SELECT json_build_object('ok', false, 'error', msg, 'code', code) $$;

-- Sesi staf: kembalikan pengguna jika token valid dan perannya sesuai
CREATE FUNCTION sincoffee.staf(p_sesi TEXT, p_peran TEXT[]) RETURNS sincoffee.pengguna
LANGUAGE sql STABLE AS $$
  SELECT u.* FROM sincoffee.sesi_staf s JOIN sincoffee.pengguna u ON u.id = s.pengguna_id
  WHERE s.token = p_sesi AND s.berlaku_sampai > now() AND u.aktif AND u.peran = ANY(p_peran)
$$;

CREATE FUNCTION sincoffee.next_nomor(p_gerai INTEGER) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE v_n INTEGER; v_kode TEXT; v_tgl DATE := (now() AT TIME ZONE sincoffee.tz())::date;
BEGIN
  INSERT INTO sincoffee.nomor_urut AS nu (gerai_id, tanggal, terakhir) VALUES (p_gerai, v_tgl, 1)
  ON CONFLICT (gerai_id, tanggal) DO UPDATE SET terakhir = nu.terakhir + 1
  RETURNING terakhir INTO v_n;
  SELECT kode INTO v_kode FROM sincoffee.gerai WHERE id = p_gerai;
  RETURN v_kode || '-' || to_char(v_tgl, 'MMDD') || '-' || lpad(v_n::text, 4, '0');
END $$;

CREATE FUNCTION sincoffee.buat_tagihan(p_id UUID) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE o sincoffee.pesanan; v_gw TEXT;
BEGIN
  SELECT * INTO o FROM sincoffee.pesanan WHERE id = p_id;
  v_gw := 'SC-' || right(o.nomor_pesanan, 4) || '-' || upper(encode(extensions.gen_random_bytes(3), 'hex'));
  INSERT INTO sincoffee.pembayaran (pesanan_id, gateway_order_id, jumlah, kedaluwarsa_pada)
  VALUES (o.id, v_gw, o.total, now() + make_interval(mins => sincoffee.cfg('batas_bayar_menit')::int));
  PERFORM sincoffee.catat(o.gerai_id, 'API', 'info', 'Tagihan QRIS dibuat untuk ' || o.nomor_pesanan,
    'gateway_order_id=' || v_gw || ' · ' || sincoffee.rp(o.total));
END $$;

CREATE FUNCTION sincoffee.tanda_tangan(p_raw TEXT) RETURNS TEXT LANGUAGE sql STABLE AS
$$ SELECT encode(extensions.hmac(p_raw, sincoffee.cfg('webhook_secret'), 'sha256'), 'hex') $$;

-- Terapkan status dari gateway. Status hanya boleh maju.
CREATE FUNCTION sincoffee.terapkan_status(p_gw TEXT, p_status TEXT, p_jumlah INTEGER, p_sumber TEXT)
RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE b RECORD; v_tag TEXT := CASE WHEN p_sumber = 'cek' THEN 'API' ELSE 'WEBHOOK' END; v_late BOOLEAN;
BEGIN
  SELECT pb.*, p.nomor_pesanan, p.status_bayar, p.gerai_id INTO b
  FROM sincoffee.pembayaran pb JOIN sincoffee.pesanan p ON p.id = pb.pesanan_id
  WHERE pb.gateway_order_id = p_gw FOR UPDATE;
  IF NOT FOUND THEN
    PERFORM sincoffee.catat(NULL, 'WEBHOOK', 'err', 'Webhook untuk tagihan yang tidak dikenal.', 'gateway_order_id=' || p_gw);
    RETURN 'tidak_dikenal';
  END IF;
  IF p_jumlah IS DISTINCT FROM b.jumlah THEN
    PERFORM sincoffee.catat(b.gerai_id, 'WEBHOOK', 'err', 'Jumlah tidak cocok untuk ' || b.nomor_pesanan || '. Perlu dicek manual.',
      'diterima=' || COALESCE(p_jumlah::text, '-') || ', tagihan=' || b.jumlah);
    RETURN 'jumlah_beda';
  END IF;

  IF p_status = 'settlement' THEN
    IF b.status_bayar = 'LUNAS' THEN
      PERFORM sincoffee.catat(b.gerai_id, v_tag, 'warn', b.nomor_pesanan || ' sudah lunas. Tidak ada perubahan.');
      RETURN 'sudah_lunas';
    END IF;
    IF b.status_bayar NOT IN ('BELUM_BAYAR', 'KEDALUWARSA') THEN RETURN 'diabaikan'; END IF;
    v_late := b.status_bayar = 'KEDALUWARSA';
    UPDATE sincoffee.pembayaran SET status = 'LUNAS', status_gateway = 'settlement', dibayar_pada = now() WHERE id = b.id;
    UPDATE sincoffee.pesanan SET status_bayar = 'LUNAS', status_produksi = 'MENUNGGU', dibayar_pada = now(), bayar_terlambat = v_late
      WHERE id = b.pesanan_id;
    PERFORM sincoffee.riwayat(b.pesanan_id, 'bayar', b.status_bayar, 'LUNAS', p_sumber);
    PERFORM sincoffee.riwayat(b.pesanan_id, 'produksi', NULL, 'MENUNGGU', p_sumber);
    PERFORM sincoffee.catat(b.gerai_id, v_tag, 'ok',
      b.nomor_pesanan || ' lunas' || CASE WHEN v_late THEN ' (dibayar setelah kedaluwarsa)' ELSE '' END || '. Masuk antrean barista.',
      CASE WHEN p_sumber = 'cek' THEN 'sumber: cek status ke gateway' ELSE 'tanda tangan valid · jumlah cocok' END);
    RETURN 'lunas';
  ELSIF p_status IN ('deny', 'failure') THEN
    IF b.status_bayar <> 'BELUM_BAYAR' THEN
      PERFORM sincoffee.catat(b.gerai_id, v_tag, 'warn', 'Status "' || p_status || '" untuk ' || b.nomor_pesanan || ' diabaikan karena status hanya boleh maju.');
      RETURN 'diabaikan';
    END IF;
    UPDATE sincoffee.pembayaran SET status = 'GAGAL', status_gateway = 'deny' WHERE id = b.id;
    UPDATE sincoffee.pesanan SET status_bayar = 'GAGAL' WHERE id = b.pesanan_id;
    PERFORM sincoffee.riwayat(b.pesanan_id, 'bayar', 'BELUM_BAYAR', 'GAGAL', p_sumber);
    PERFORM sincoffee.catat(b.gerai_id, v_tag, 'err', 'Pembayaran ' || b.nomor_pesanan || ' ditolak. Pelanggan diminta bayar ulang.');
    RETURN 'gagal';
  ELSIF p_status = 'expire' THEN
    IF b.status_bayar <> 'BELUM_BAYAR' THEN RETURN 'diabaikan'; END IF;
    UPDATE sincoffee.pembayaran SET status = 'KEDALUWARSA', status_gateway = 'expire' WHERE id = b.id;
    UPDATE sincoffee.pesanan SET status_bayar = 'KEDALUWARSA' WHERE id = b.pesanan_id;
    PERFORM sincoffee.riwayat(b.pesanan_id, 'bayar', 'BELUM_BAYAR', 'KEDALUWARSA', p_sumber);
    PERFORM sincoffee.catat(b.gerai_id, v_tag, 'warn', 'QR untuk ' || b.nomor_pesanan || ' kedaluwarsa.');
    RETURN 'kedaluwarsa';
  END IF;
  RETURN 'pending';
END $$;

-- Proses webhook: verifikasi tanda tangan + idempotensi (event_id unik).
-- Dipakai simulasi sekarang, dan nanti oleh Edge Function webhook gateway asli.
CREATE FUNCTION sincoffee.proses_webhook(p_raw TEXT, p_sig TEXT, p_sumber TEXT DEFAULT 'webhook')
RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE d JSONB; v_event TEXT; v_gw TEXT; v_id INTEGER; v_hasil TEXT;
BEGIN
  BEGIN d := p_raw::jsonb; EXCEPTION WHEN others THEN d := NULL; END;
  v_event := d->>'event_id'; v_gw := d->>'gateway_order_id';
  IF p_sig IS NULL OR p_sig <> sincoffee.tanda_tangan(p_raw) OR v_event IS NULL OR v_gw IS NULL THEN
    INSERT INTO sincoffee.webhook_event (gateway, event_id, gateway_order_id, payload, tanda_tangan_valid, hasil)
    VALUES ('SIMULASI', NULL, v_gw, left(p_raw, 4000), FALSE, 'ditolak');
    PERFORM sincoffee.catat(NULL, 'WEBHOOK', 'err', 'Webhook ditolak: tanda tangan tidak valid. Status pesanan tidak berubah.',
      CASE WHEN v_gw IS NOT NULL THEN 'gateway_order_id=' || v_gw END);
    RETURN 'ditolak';
  END IF;
  INSERT INTO sincoffee.webhook_event (gateway, event_id, gateway_order_id, payload, tanda_tangan_valid)
  VALUES ('SIMULASI', v_event, v_gw, left(p_raw, 4000), TRUE)
  ON CONFLICT (event_id) DO NOTHING RETURNING id INTO v_id;
  IF v_id IS NULL THEN
    PERFORM sincoffee.catat(NULL, 'WEBHOOK', 'warn', 'Webhook duplikat diabaikan. Tidak ada pesanan ganda.', 'event_id=' || v_event);
    RETURN 'duplikat';
  END IF;
  v_hasil := sincoffee.terapkan_status(v_gw, d->>'status', (d->>'amount')::int, p_sumber);
  UPDATE sincoffee.webhook_event SET hasil = v_hasil WHERE id = v_id;
  RETURN v_hasil;
END $$;

-- Tagihan kedaluwarsa, atau webhook belum datang -> cek status ke gateway (simulasi)
CREATE FUNCTION sincoffee.rapikan(p_id UUID) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE o sincoffee.pesanan; b sincoffee.pembayaran;
BEGIN
  SELECT * INTO o FROM sincoffee.pesanan WHERE id = p_id;
  IF NOT FOUND OR o.status_bayar <> 'BELUM_BAYAR' THEN RETURN; END IF;
  SELECT * INTO b FROM sincoffee.pembayaran WHERE pesanan_id = p_id ORDER BY id DESC LIMIT 1;
  IF NOT FOUND OR b.status <> 'PENDING' THEN RETURN; END IF;
  IF b.status_gateway = 'settlement' AND now() - b.dibuat_pada >= make_interval(secs => sincoffee.cfg('cek_status_setelah_detik')::int) THEN
    PERFORM sincoffee.catat(o.gerai_id, 'API', 'info', 'Webhook belum datang untuk ' || o.nomor_pesanan || '. Cek status langsung ke gateway.',
      'GET status ' || b.gateway_order_id || ' -> settlement');
    PERFORM sincoffee.terapkan_status(b.gateway_order_id, 'settlement', b.jumlah, 'cek');
  ELSIF b.kedaluwarsa_pada <= now() THEN
    PERFORM sincoffee.terapkan_status(b.gateway_order_id, 'expire', b.jumlah, 'sistem');
  END IF;
END $$;

CREATE FUNCTION sincoffee.pesanan_json(p_id UUID) RETURNS JSON LANGUAGE sql STABLE AS $$
  SELECT json_build_object(
    'id', p.id, 'nomor', p.nomor_pesanan, 'meja', m.kode_meja, 'nama', p.nama_pelanggan,
    'status_bayar', p.status_bayar, 'status_produksi', p.status_produksi, 'total', p.total,
    'terlambat', p.bayar_terlambat,
    'dibayar_pada', sincoffee.lokal(p.dibayar_pada, 'YYYY-MM-DD HH24:MI:SS'),
    'siap_pada', sincoffee.lokal(p.siap_pada, 'YYYY-MM-DD HH24:MI:SS'),
    'items', (SELECT COALESCE(json_agg(json_build_object('nama', i.nama, 'harga', i.harga, 'qty', i.qty, 'suhu', i.suhu, 'manis', i.manis, 'catatan', i.catatan) ORDER BY i.id), '[]')
              FROM sincoffee.pesanan_item i WHERE i.pesanan_id = p.id),
    'pembayaran', (SELECT json_build_object('gateway_order_id', b.gateway_order_id, 'status', b.status,
                     'sisa_detik', GREATEST(0, floor(extract(epoch FROM b.kedaluwarsa_pada - now())))::int,
                     'qr_string', 'DEMO-QRIS|' || b.gateway_order_id || '|' || b.jumlah)
                   FROM sincoffee.pembayaran b WHERE b.pesanan_id = p.id ORDER BY b.id DESC LIMIT 1)
  )
  FROM sincoffee.pesanan p LEFT JOIN sincoffee.meja_qr m ON m.id = p.meja_qr_id WHERE p.id = p_id
$$;

CREATE FUNCTION sincoffee.uuid_aman(p TEXT) RETURNS UUID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN RETURN p::uuid; EXCEPTION WHEN others THEN RETURN NULL; END $$;

-- =====================================================================
-- API PUBLIK (dipanggil website lewat /rest/v1/rpc/<nama>)
-- Semua SECURITY DEFINER: berjalan dengan hak pemilik, bukan hak pengunjung.
-- =====================================================================

-- ---------- PELANGGAN ----------
CREATE FUNCTION public.sc_menu(p_token TEXT) RETURNS JSON
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = sincoffee, extensions AS $$
DECLARE m RECORD;
BEGIN
  SELECT q.id, q.kode_meja, q.gerai_id, g.kode, g.nama, g.alamat INTO m
  FROM meja_qr q JOIN gerai g ON g.id = q.gerai_id WHERE q.token = p_token AND q.aktif AND g.aktif;
  IF NOT FOUND THEN RETURN err('QR meja tidak dikenali. Minta bantuan barista.', 404); END IF;
  RETURN json_build_object('ok', true,
    'gerai', json_build_object('kode', m.kode, 'nama', m.nama, 'alamat', m.alamat),
    'meja', m.kode_meja, 'mode_demo', cfg('mode_demo') = '1',
    'menu', (SELECT COALESCE(json_agg(json_build_object(
                'id', mn.id, 'kategori', mn.kategori, 'nama', mn.nama, 'deskripsi', mn.deskripsi,
                'suhu', CASE WHEN mn.pilihan_suhu IS NULL THEN NULL ELSE string_to_array(mn.pilihan_suhu, ',') END,
                'manis', mn.pilihan_manis, 'harga', mg.harga, 'tersedia', mg.tersedia) ORDER BY mn.urutan, mn.id), '[]')
             FROM menu mn JOIN menu_gerai mg ON mg.menu_id = mn.id AND mg.gerai_id = m.gerai_id WHERE mn.aktif));
END $$;

CREATE FUNCTION public.sc_order(p_token TEXT, p_idem TEXT, p_nama TEXT, p_items JSONB) RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER SET search_path = sincoffee, extensions AS $$
DECLARE v_idem TEXT := regexp_replace(COALESCE(p_idem, ''), '[^a-zA-Z0-9_-]', '', 'g');
        v_id UUID; q RECORD; it JSONB; mn RECORD; v_total INTEGER := 0; v_qty INTEGER;
        v_suhu TEXT; v_manis TEXT; v_nomor TEXT; v_nama TEXT := NULLIF(left(trim(COALESCE(p_nama, '')), 40), '');
BEGIN
  IF length(v_idem) < 10 THEN RETURN err('Permintaan tidak lengkap. Muat ulang halaman.'); END IF;
  SELECT id INTO v_id FROM pesanan WHERE kunci_idempotensi = v_idem;
  IF FOUND THEN
    PERFORM catat(NULL, 'API', 'warn', 'Permintaan pesan ganda. Pesanan yang sudah ada dikembalikan.', 'kunci_idempotensi=' || v_idem);
    RETURN json_build_object('ok', true, 'order', pesanan_json(v_id), 'ulang', true);
  END IF;
  SELECT * INTO q FROM meja_qr WHERE token = p_token AND aktif;
  IF NOT FOUND THEN RETURN err('QR meja tidak dikenali.', 404); END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 OR jsonb_array_length(p_items) > 30 THEN
    RETURN err('Keranjang kosong atau terlalu banyak item.');
  END IF;

  -- Validasi semua item dulu. Harga selalu diambil dari database.
  FOR it IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    SELECT mm.id, mm.nama, mm.pilihan_suhu, mm.pilihan_manis, mg.harga, mg.tersedia INTO mn
    FROM menu mm JOIN menu_gerai mg ON mg.menu_id = mm.id AND mg.gerai_id = q.gerai_id
    WHERE mm.id = (it->>'menu_id')::int AND mm.aktif;
    IF NOT FOUND THEN RETURN err('Ada menu yang tidak ditemukan. Muat ulang menu.'); END IF;
    IF NOT mn.tersedia THEN RETURN err(mn.nama || ' sedang habis. Hapus dari pesanan untuk lanjut.'); END IF;
    v_total := v_total + mn.harga * LEAST(20, GREATEST(1, COALESCE((it->>'qty')::int, 1)));
  END LOOP;

  v_nomor := next_nomor(q.gerai_id);
  BEGIN
    INSERT INTO pesanan (nomor_pesanan, gerai_id, meja_qr_id, nama_pelanggan, total, kunci_idempotensi)
    VALUES (v_nomor, q.gerai_id, q.id, v_nama, v_total, v_idem) RETURNING id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    SELECT id INTO v_id FROM pesanan WHERE kunci_idempotensi = v_idem;
    RETURN json_build_object('ok', true, 'order', pesanan_json(v_id), 'ulang', true);
  END;

  FOR it IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    SELECT mm.id, mm.nama, mm.pilihan_suhu, mm.pilihan_manis, mg.harga INTO mn
    FROM menu mm JOIN menu_gerai mg ON mg.menu_id = mm.id AND mg.gerai_id = q.gerai_id WHERE mm.id = (it->>'menu_id')::int;
    v_qty := LEAST(20, GREATEST(1, COALESCE((it->>'qty')::int, 1)));
    v_suhu := CASE WHEN mn.pilihan_suhu IS NULL THEN NULL
                   WHEN (it->>'suhu') = ANY(string_to_array(mn.pilihan_suhu, ',')) THEN it->>'suhu'
                   ELSE split_part(mn.pilihan_suhu, ',', 1) END;
    v_manis := CASE WHEN mn.pilihan_manis AND (it->>'manis') IN ('Kurang manis', 'Tanpa gula') THEN it->>'manis' END;
    INSERT INTO pesanan_item (pesanan_id, menu_id, nama, harga, qty, suhu, manis, catatan)
    VALUES (v_id, mn.id, mn.nama, mn.harga, v_qty, v_suhu, v_manis, NULLIF(left(trim(COALESCE(it->>'catatan', '')), 120), ''));
  END LOOP;

  PERFORM riwayat(v_id, 'bayar', NULL, 'BELUM_BAYAR', 'pelanggan');
  PERFORM catat(q.gerai_id, 'API', 'info', 'Pesanan ' || v_nomor || ' dibuat dari ' || q.kode_meja, 'total dihitung server = ' || rp(v_total));
  PERFORM buat_tagihan(v_id);
  RETURN json_build_object('ok', true, 'order', pesanan_json(v_id));
END $$;

CREATE FUNCTION public.sc_status(p_id TEXT) RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER SET search_path = sincoffee, extensions AS $$
DECLARE v_id UUID := uuid_aman(p_id);
BEGIN
  IF v_id IS NULL OR NOT EXISTS (SELECT 1 FROM pesanan WHERE id = v_id) THEN RETURN err('Pesanan tidak ditemukan.', 404); END IF;
  PERFORM rapikan(v_id);
  RETURN json_build_object('ok', true, 'order', pesanan_json(v_id));
END $$;

CREATE FUNCTION public.sc_check(p_id TEXT) RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER SET search_path = sincoffee, extensions AS $$
DECLARE v_id UUID := uuid_aman(p_id); b pembayaran; o pesanan;
BEGIN
  SELECT * INTO o FROM pesanan WHERE id = v_id;
  IF NOT FOUND THEN RETURN err('Pesanan tidak ditemukan.', 404); END IF;
  SELECT * INTO b FROM pembayaran WHERE pesanan_id = v_id ORDER BY id DESC LIMIT 1;
  IF FOUND AND b.status = 'PENDING' THEN
    PERFORM catat(o.gerai_id, 'API', 'info', 'Pelanggan menekan cek status untuk ' || o.nomor_pesanan || '.', 'GET status ' || b.gateway_order_id || ' -> ' || b.status_gateway);
    IF b.status_gateway = 'settlement' THEN PERFORM terapkan_status(b.gateway_order_id, 'settlement', b.jumlah, 'cek'); END IF;
  END IF;
  RETURN json_build_object('ok', true, 'order', pesanan_json(v_id));
END $$;

CREATE FUNCTION public.sc_repay(p_id TEXT) RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER SET search_path = sincoffee, extensions AS $$
DECLARE v_id UUID := uuid_aman(p_id); o pesanan;
BEGIN
  SELECT * INTO o FROM pesanan WHERE id = v_id FOR UPDATE;
  IF NOT FOUND THEN RETURN err('Pesanan tidak ditemukan.', 404); END IF;
  IF o.status_bayar NOT IN ('GAGAL', 'KEDALUWARSA') THEN RETURN err('Pesanan ini tidak perlu dibayar ulang.'); END IF;
  UPDATE pesanan SET status_bayar = 'BELUM_BAYAR' WHERE id = v_id;
  PERFORM riwayat(v_id, 'bayar', o.status_bayar, 'BELUM_BAYAR', 'pelanggan');
  PERFORM buat_tagihan(v_id);
  RETURN json_build_object('ok', true, 'order', pesanan_json(v_id));
END $$;

CREATE FUNCTION public.sc_cancel(p_id TEXT) RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER SET search_path = sincoffee, extensions AS $$
DECLARE v_id UUID := uuid_aman(p_id); v_gerai INTEGER;
BEGIN
  UPDATE pesanan SET status_bayar = 'DIBATALKAN' WHERE id = v_id AND status_bayar IN ('BELUM_BAYAR', 'GAGAL', 'KEDALUWARSA')
  RETURNING gerai_id INTO v_gerai;
  IF FOUND THEN
    UPDATE pembayaran SET status = 'DIBATALKAN' WHERE pesanan_id = v_id AND status = 'PENDING';
    PERFORM riwayat(v_id, 'bayar', NULL, 'DIBATALKAN', 'pelanggan');
    PERFORM catat(v_gerai, 'API', 'warn', 'Pelanggan membatalkan pesanan sebelum membayar.');
  END IF;
  RETURN json_build_object('ok', true);
END $$;

-- Simulasi gateway (hanya mode demo): membuat webhook bertanda tangan lalu
-- memprosesnya lewat fungsi yang sama dengan webhook asli.
CREATE FUNCTION public.sc_sim(p_id TEXT, p_mode TEXT) RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER SET search_path = sincoffee, extensions AS $$
DECLARE v_id UUID := uuid_aman(p_id); b pembayaran; v_raw TEXT; v_hasil TEXT[] := '{}'; v_gerai INTEGER;
BEGIN
  IF cfg('mode_demo') <> '1' THEN RETURN err('Simulasi hanya tersedia di mode demo.', 403); END IF;
  SELECT * INTO b FROM pembayaran WHERE pesanan_id = v_id ORDER BY id DESC LIMIT 1;
  IF NOT FOUND THEN RETURN err('Tagihan tidak ditemukan.', 404); END IF;
  SELECT gerai_id INTO v_gerai FROM pesanan WHERE id = v_id;
  IF p_mode IN ('ok', 'fail', 'fake') THEN
    v_raw := json_build_object('event_id', 'evt_' || encode(gen_random_bytes(8), 'hex'), 'gateway_order_id', b.gateway_order_id,
               'status', CASE WHEN p_mode = 'fail' THEN 'deny' ELSE 'settlement' END, 'amount', b.jumlah, 'waktu', now())::text;
    IF p_mode = 'fake' THEN
      v_hasil := v_hasil || proses_webhook(v_raw, 'tanda-tangan-palsu');
    ELSE
      v_hasil := v_hasil || proses_webhook(v_raw, tanda_tangan(v_raw));
      -- Gateway biasanya mengirim ulang webhook yang sama
      IF p_mode = 'ok' THEN v_hasil := v_hasil || proses_webhook(v_raw, tanda_tangan(v_raw)); END IF;
    END IF;
  ELSIF p_mode = 'lost' THEN
    UPDATE pembayaran SET status_gateway = 'settlement' WHERE id = b.id AND status = 'PENDING';
    PERFORM catat(v_gerai, 'GATEWAY', 'warn', 'Pelanggan sudah bayar, tetapi webhook tidak terkirim.', 'sistem akan cek status otomatis');
    v_hasil := v_hasil || 'webhook_hilang'::text;
  ELSE
    RETURN err('Mode simulasi tidak dikenal.');
  END IF;
  RETURN json_build_object('ok', true, 'hasil', v_hasil, 'order', pesanan_json(v_id));
END $$;

-- ---------- STAF ----------
CREATE FUNCTION public.sc_login(p_peran TEXT, p_pin TEXT) RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER SET search_path = sincoffee, extensions AS $$
DECLARE u pengguna; v_token TEXT;
BEGIN
  IF (SELECT count(*) FROM percobaan_login WHERE NOT berhasil AND waktu > now() - interval '10 minutes') >= 20 THEN
    RETURN err('Terlalu banyak percobaan. Coba lagi 10 menit lagi.', 429);
  END IF;
  SELECT * INTO u FROM pengguna WHERE aktif AND peran = p_peran AND pin_hash = crypt(COALESCE(p_pin, ''), pin_hash) LIMIT 1;
  IF NOT FOUND THEN
    INSERT INTO percobaan_login (berhasil) VALUES (FALSE);
    PERFORM pg_sleep(0.4);
    RETURN err('PIN salah.', 401);
  END IF;
  INSERT INTO percobaan_login (berhasil) VALUES (TRUE);
  DELETE FROM sesi_staf WHERE berlaku_sampai < now();
  v_token := encode(gen_random_bytes(24), 'hex');
  INSERT INTO sesi_staf (token, pengguna_id, berlaku_sampai) VALUES (v_token, u.id, now() + interval '16 hours');
  RETURN json_build_object('ok', true, 'token', v_token, 'nama', u.nama, 'peran', u.peran);
END $$;

CREATE FUNCTION public.sc_logout(p_sesi TEXT) RETURNS JSON
LANGUAGE sql SECURITY DEFINER SET search_path = sincoffee AS $$
  DELETE FROM sesi_staf WHERE token = p_sesi; SELECT json_build_object('ok', true);
$$;

CREATE FUNCTION public.sc_info(p_sesi TEXT) RETURNS JSON
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = sincoffee, extensions AS $$
DECLARE u pengguna; g gerai;
BEGIN
  u := staf(p_sesi, ARRAY['owner', 'admin', 'barista']);
  IF u.id IS NULL THEN RETURN err('Sesi habis. Silakan masuk lagi.', 401); END IF;
  SELECT * INTO g FROM gerai WHERE id = COALESCE(u.gerai_id, (SELECT min(id) FROM gerai));
  RETURN json_build_object('ok', true, 'nama', u.nama, 'peran', u.peran, 'mode_demo', cfg('mode_demo') = '1',
    'gerai', json_build_object('id', g.id, 'kode', g.kode, 'nama', g.nama, 'alamat', g.alamat));
END $$;

CREATE FUNCTION public.sc_queue(p_sesi TEXT) RETURNS JSON
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = sincoffee, extensions AS $$
DECLARE u pengguna; v_g INTEGER;
BEGIN
  u := staf(p_sesi, ARRAY['owner', 'admin', 'barista']);
  IF u.id IS NULL THEN RETURN err('Sesi habis. Silakan masuk lagi.', 401); END IF;
  v_g := COALESCE(u.gerai_id, (SELECT min(id) FROM gerai));
  RETURN json_build_object('ok', true, 'now', floor(extract(epoch FROM now()))::bigint,
    'selesai', (SELECT count(*) FROM pesanan WHERE gerai_id = v_g AND status_produksi = 'SELESAI' AND selesai_pada >= now() - interval '12 hours'),
    'orders', (SELECT COALESCE(json_agg(x ORDER BY x.t_bayar), '[]') FROM (
       SELECT p.id, p.nomor_pesanan, p.nama_pelanggan, p.status_produksi, p.bayar_terlambat, p.is_contoh, m.kode_meja,
              floor(extract(epoch FROM p.dibayar_pada))::bigint AS t_bayar, floor(extract(epoch FROM p.siap_pada))::bigint AS t_siap,
              (SELECT json_agg(json_build_object('nama', i.nama, 'qty', i.qty, 'suhu', i.suhu, 'manis', i.manis, 'catatan', i.catatan) ORDER BY i.id)
                 FROM pesanan_item i WHERE i.pesanan_id = p.id) AS items
       FROM pesanan p LEFT JOIN meja_qr m ON m.id = p.meja_qr_id
       WHERE p.gerai_id = v_g AND p.status_bayar = 'LUNAS' AND p.status_produksi IN ('MENUNGGU', 'DIPROSES', 'SIAP')) x));
END $$;

CREATE FUNCTION public.sc_advance(p_sesi TEXT, p_id TEXT, p_dari TEXT) RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER SET search_path = sincoffee, extensions AS $$
DECLARE u pengguna; v_id UUID := uuid_aman(p_id); v_next TEXT; o pesanan;
BEGIN
  u := staf(p_sesi, ARRAY['owner', 'admin', 'barista']);
  IF u.id IS NULL THEN RETURN err('Sesi habis. Silakan masuk lagi.', 401); END IF;
  v_next := CASE p_dari WHEN 'MENUNGGU' THEN 'DIPROSES' WHEN 'DIPROSES' THEN 'SIAP' WHEN 'SIAP' THEN 'SELESAI' END;
  IF v_next IS NULL THEN RETURN err('Status tidak valid.'); END IF;
  -- Syarat status_produksi = p_dari mencegah klik ganda dari dua tablet
  UPDATE pesanan SET status_produksi = v_next,
         siap_pada = CASE WHEN v_next = 'SIAP' THEN now() ELSE siap_pada END,
         selesai_pada = CASE WHEN v_next = 'SELESAI' THEN now() ELSE selesai_pada END
  WHERE id = v_id AND status_produksi = p_dari AND status_bayar = 'LUNAS'
    AND (u.gerai_id IS NULL OR gerai_id = u.gerai_id)
  RETURNING * INTO o;
  IF NOT FOUND THEN RETURN err('Status pesanan sudah berubah di perangkat lain. Layar dimuat ulang.', 409); END IF;
  PERFORM riwayat(v_id, 'produksi', p_dari, v_next, u.nama);
  PERFORM catat(o.gerai_id, 'BARISTA', 'info', o.nomor_pesanan || ': ' || initcap(lower(p_dari)) || ' → ' || initcap(lower(v_next)), 'oleh ' || u.nama);
  IF v_next = 'SIAP' AND NOT o.is_contoh THEN
    INSERT INTO notifikasi (pesanan_id, kanal, status, percobaan) VALUES (v_id, 'browser', 'TERKIRIM', 1);
    PERFORM catat(o.gerai_id, 'NOTIF', 'ok', 'Notifikasi "pesanan siap" dikirim ke HP pelanggan ' || o.nomor_pesanan || '.');
  END IF;
  RETURN json_build_object('ok', true);
END $$;

CREATE FUNCTION public.sc_menu_admin(p_sesi TEXT) RETURNS JSON
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = sincoffee, extensions AS $$
DECLARE u pengguna; v_g INTEGER;
BEGIN
  u := staf(p_sesi, ARRAY['owner', 'admin', 'barista']);
  IF u.id IS NULL THEN RETURN err('Sesi habis. Silakan masuk lagi.', 401); END IF;
  v_g := COALESCE(u.gerai_id, (SELECT min(id) FROM gerai));
  RETURN json_build_object('ok', true, 'menu', (SELECT COALESCE(json_agg(json_build_object('id', m.id, 'kategori', m.kategori, 'nama', m.nama, 'harga', mg.harga, 'tersedia', mg.tersedia) ORDER BY m.urutan), '[]')
    FROM menu m JOIN menu_gerai mg ON mg.menu_id = m.id AND mg.gerai_id = v_g WHERE m.aktif));
END $$;

CREATE FUNCTION public.sc_toggle_menu(p_sesi TEXT, p_menu_id INTEGER, p_tersedia BOOLEAN) RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER SET search_path = sincoffee, extensions AS $$
DECLARE u pengguna; v_g INTEGER; v_nama TEXT;
BEGIN
  u := staf(p_sesi, ARRAY['owner', 'admin', 'barista']);
  IF u.id IS NULL THEN RETURN err('Sesi habis. Silakan masuk lagi.', 401); END IF;
  v_g := COALESCE(u.gerai_id, (SELECT min(id) FROM gerai));
  UPDATE menu_gerai SET tersedia = p_tersedia WHERE menu_id = p_menu_id AND gerai_id = v_g;
  SELECT nama INTO v_nama FROM menu WHERE id = p_menu_id;
  PERFORM catat(v_g, 'ADMIN', 'info', v_nama || ' ditandai ' || CASE WHEN p_tersedia THEN 'tersedia' ELSE 'habis' END || '.', 'oleh ' || u.nama);
  RETURN json_build_object('ok', true);
END $$;

CREATE FUNCTION public.sc_stats(p_sesi TEXT) RETURNS JSON
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = sincoffee, extensions AS $$
DECLARE u pengguna; v_g INTEGER; v_sejak TIMESTAMPTZ := now() - interval '12 hours'; k RECORD; v_tz TEXT := tz();
BEGIN
  u := staf(p_sesi, ARRAY['owner']);
  IF u.id IS NULL THEN RETURN err('Sesi habis atau bukan akun owner. Silakan masuk sebagai owner.', 401); END IF;
  v_g := COALESCE(u.gerai_id, (SELECT min(id) FROM gerai));
  SELECT count(*) AS n, COALESCE(sum(total), 0) AS omzet,
         COALESCE(avg(extract(epoch FROM siap_pada - dibayar_pada)) FILTER (WHERE siap_pada IS NOT NULL), 0) AS siap
    INTO k FROM pesanan WHERE gerai_id = v_g AND status_bayar = 'LUNAS' AND dibayar_pada >= v_sejak;
  RETURN json_build_object('ok', true, 'now', floor(extract(epoch FROM now()))::bigint,
    'kpi', json_build_object('omzet', k.omzet, 'lunas', k.n, 'rata', CASE WHEN k.n > 0 THEN round(k.omzet::numeric / k.n) ELSE 0 END,
      'siap_detik', round(k.siap),
      'gagal', (SELECT count(*) FROM pesanan WHERE gerai_id = v_g AND dibuat_pada >= v_sejak AND status_bayar IN ('GAGAL', 'KEDALUWARSA')),
      'menunggu_bayar', (SELECT count(*) FROM pesanan WHERE gerai_id = v_g AND dibuat_pada >= v_sejak AND status_bayar = 'BELUM_BAYAR')),
    'antrean', (SELECT COALESCE(json_agg(json_build_object('s', s, 'n', n, 'tertua', tertua)), '[]') FROM (
        SELECT status_produksi AS s, count(*) AS n, floor(extract(epoch FROM min(dibayar_pada)))::bigint AS tertua
        FROM pesanan WHERE gerai_id = v_g AND status_bayar = 'LUNAS' AND status_produksi IN ('MENUNGGU', 'DIPROSES', 'SIAP')
        GROUP BY status_produksi) a),
    'per_jam', (SELECT json_agg(json_build_object('jam', to_char(h, 'HH24'), 'n',
        (SELECT count(*) FROM pesanan p WHERE p.gerai_id = v_g AND p.status_bayar = 'LUNAS'
           AND date_trunc('hour', p.dibayar_pada AT TIME ZONE v_tz) = h)) ORDER BY h)
      FROM generate_series(date_trunc('hour', now() AT TIME ZONE v_tz) - interval '11 hours', date_trunc('hour', now() AT TIME ZONE v_tz), interval '1 hour') AS h),
    'terlaris', (SELECT COALESCE(json_agg(json_build_object('nama', nama, 'n', n) ORDER BY n DESC), '[]') FROM (
        SELECT i.nama, sum(i.qty) AS n FROM pesanan_item i JOIN pesanan p ON p.id = i.pesanan_id
        WHERE p.gerai_id = v_g AND p.status_bayar = 'LUNAS' AND p.dibayar_pada >= v_sejak
        GROUP BY i.nama ORDER BY sum(i.qty) DESC LIMIT 5) t),
    'rekon', json_build_object('sistem', k.omzet,
        'gateway', (SELECT COALESCE(sum(b.jumlah), 0) FROM pembayaran b JOIN pesanan p ON p.id = b.pesanan_id
                    WHERE p.gerai_id = v_g AND b.status = 'LUNAS' AND b.dibayar_pada >= v_sejak),
        'webhook', (SELECT count(*) FROM webhook_event WHERE diterima_pada >= v_sejak),
        'ditolak', (SELECT count(*) FROM webhook_event WHERE diterima_pada >= v_sejak AND NOT tanda_tangan_valid),
        'duplikat', (SELECT count(*) FROM log_aktivitas WHERE tag = 'WEBHOOK' AND pesan LIKE 'Webhook duplikat%' AND waktu >= v_sejak)),
    'terbaru', (SELECT COALESCE(json_agg(r ORDER BY r.dibuat_pada DESC), '[]') FROM (
        SELECT p.nomor_pesanan, lokal(p.dibuat_pada, 'HH24.MI') AS jam, m.kode_meja, p.nama_pelanggan, p.total,
               p.status_bayar, p.status_produksi, p.is_contoh, p.dibuat_pada,
               (SELECT COALESCE(sum(qty), 0) FROM pesanan_item WHERE pesanan_id = p.id) AS item
        FROM pesanan p LEFT JOIN meja_qr m ON m.id = p.meja_qr_id WHERE p.gerai_id = v_g ORDER BY p.dibuat_pada DESC LIMIT 12) r),
    'log', (SELECT COALESCE(json_agg(json_build_object('tag', tag, 'tingkat', tingkat, 'pesan', pesan, 'detail', detail, 'waktu', lokal(waktu, 'HH24:MI:SS')) ORDER BY id DESC), '[]')
            FROM (SELECT * FROM log_aktivitas WHERE gerai_id = v_g OR gerai_id IS NULL ORDER BY id DESC LIMIT 40) l));
END $$;

CREATE FUNCTION public.sc_qr_list(p_sesi TEXT) RETURNS JSON
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = sincoffee, extensions AS $$
DECLARE u pengguna; v_g INTEGER;
BEGIN
  u := staf(p_sesi, ARRAY['owner']);
  IF u.id IS NULL THEN RETURN err('Sesi habis atau bukan akun owner.', 401); END IF;
  v_g := COALESCE(u.gerai_id, (SELECT min(id) FROM gerai));
  RETURN json_build_object('ok', true,
    'gerai', (SELECT json_build_object('kode', kode, 'nama', nama, 'alamat', alamat) FROM gerai WHERE id = v_g),
    'meja', (SELECT COALESCE(json_agg(json_build_object('kode_meja', kode_meja, 'token', token) ORDER BY id), '[]') FROM meja_qr WHERE gerai_id = v_g AND aktif));
END $$;

CREATE FUNCTION public.sc_reset(p_sesi TEXT) RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER SET search_path = sincoffee, extensions AS $$
DECLARE u pengguna;
BEGIN
  u := staf(p_sesi, ARRAY['owner']);
  IF u.id IS NULL THEN RETURN err('Sesi habis atau bukan akun owner.', 401); END IF;
  DELETE FROM pesanan WHERE TRUE;
  DELETE FROM webhook_event WHERE TRUE;
  DELETE FROM nomor_urut WHERE TRUE;
  DELETE FROM log_aktivitas WHERE TRUE;
  PERFORM catat(NULL, 'SISTEM', 'info', 'Data demo direset oleh ' || u.nama || '.');
  RETURN json_build_object('ok', true);
END $$;

-- ---------------------------------------------------------------------
-- Hak akses: website (anon) hanya boleh memanggil fungsi sc_*
-- ---------------------------------------------------------------------
DO $$
DECLARE f RECORD;
BEGIN
  FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'public' AND p.proname LIKE 'sc\_%' LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO anon, authenticated', f.sig);
  END LOOP;
END $$;

-- =====================================================================
-- DATA AWAL
-- =====================================================================
INSERT INTO sincoffee.gerai (kode, nama, alamat) VALUES
 ('PLU01', 'Sin Coffee Pusat', 'Jl. H. Hayun, Besusu Barat, Palu Timur');

-- PIN demo: barista 1234, owner 9999. GANTI sebelum dipakai sungguhan:
--   UPDATE sincoffee.pengguna SET pin_hash = extensions.crypt('PIN-BARU', extensions.gen_salt('bf')) WHERE peran = 'owner';
INSERT INTO sincoffee.pengguna (gerai_id, nama, peran, pin_hash) VALUES
 (1,    'Barista PLU01', 'barista', extensions.crypt('1234', extensions.gen_salt('bf'))),
 (NULL, 'Owner',         'owner',   extensions.crypt('9999', extensions.gen_salt('bf')));

-- Harga contoh. Sesuaikan dengan harga asli.
INSERT INTO sincoffee.menu (kode, kategori, nama, deskripsi, pilihan_suhu, pilihan_manis, urutan) VALUES
 ('KSA', 'Aren Series',      'Kopi Susu Aren',  'Espresso, susu segar, gula aren',  'Es,Panas', TRUE,  10),
 ('ARL', 'Aren Series',      'Aren Latte',      'Latte lembut dengan sirup aren',   'Es,Panas', TRUE,  20),
 ('AME', 'Americano Series', 'Americano',       'Espresso dan air, tanpa susu',     'Es,Panas', FALSE, 30),
 ('AMA', 'Americano Series', 'Aren Americano',  'Americano dengan manis aren',      'Es',       TRUE,  40),
 ('REG', 'Non Coffee',       'Regal Chocolate', 'Cokelat dengan remahan biskuit',   'Es,Panas', TRUE,  50),
 ('MAT', 'Non Coffee',       'Matcha Latte',    'Matcha dan susu segar',            'Es,Panas', TRUE,  60),
 ('SKG', 'Camilan',          'Singkong Goreng', 'Renyah, cocok teman ngopi',        NULL,       FALSE, 70),
 ('KCG', 'Camilan',          'Kacang Goreng',   'Gurih, porsi berbagi',             NULL,       FALSE, 80);

INSERT INTO sincoffee.menu_gerai (menu_id, gerai_id, harga)
SELECT id, 1, CASE kode WHEN 'KSA' THEN 18000 WHEN 'ARL' THEN 22000 WHEN 'AME' THEN 15000 WHEN 'AMA' THEN 17000
                        WHEN 'REG' THEN 22000 WHEN 'MAT' THEN 24000 WHEN 'SKG' THEN 12000 ELSE 10000 END
FROM sincoffee.menu;

-- Token QR acak per meja (dibuat otomatis, 12 meja)
INSERT INTO sincoffee.meja_qr (gerai_id, kode_meja, token)
SELECT 1, 'Meja ' || n, encode(extensions.gen_random_bytes(16), 'hex') FROM generate_series(1, 12) AS n;

-- =====================================================================
-- DATA CONTOH (opsional tapi disarankan untuk demo):
-- 30 pesanan selesai dalam 12 jam terakhir agar Ringkasan tidak kosong.
-- Hapus kapan saja lewat tombol "Reset data demo" di Ringkasan.
-- =====================================================================
DO $$
DECLARE i INT; m INT; v_id UUID; v_tot INT; v_pay INT; v_siap INT; v_done INT; v_meja INT;
        names TEXT[] := ARRAY['Rina','Fajar','Dewi','Andi','Sari','Rizal','Nur','Yusuf','Ayu','Hendra','Mita','Bayu'];
        mid INT; k INT; j INT; v_tgl TEXT := to_char(now() AT TIME ZONE 'Asia/Makassar', 'MMDD');
BEGIN
  PERFORM setseed(0.1029);
  FOR i IN 1..30 LOOP
    m := (720 - i * 23 + floor(random() * 10))::int;           -- menit lalu, menyebar 12 jam
    v_pay := 30 + floor(random() * 60)::int; v_siap := v_pay + 180 + floor(random() * 360)::int; v_done := v_siap + 40 + floor(random() * 200)::int;
    v_meja := 1 + floor(random() * 12)::int;
    INSERT INTO sincoffee.pesanan (nomor_pesanan, gerai_id, meja_qr_id, nama_pelanggan, status_bayar, status_produksi, total, kunci_idempotensi, is_contoh,
                                   dibuat_pada, dibayar_pada, siap_pada, selesai_pada)
    VALUES ('PLU01-' || v_tgl || '-' || lpad(i::text, 4, '0'), 1, (SELECT id FROM sincoffee.meja_qr WHERE kode_meja = 'Meja ' || v_meja),
            names[1 + floor(random() * 12)::int], 'LUNAS', 'SELESAI', 0, 'contoh-' || i, TRUE,
            now() - make_interval(secs => m * 60), now() - make_interval(secs => m * 60 - v_pay),
            now() - make_interval(secs => m * 60 - v_siap), now() - make_interval(secs => GREATEST(m * 60 - v_done, 5)))
    RETURNING id INTO v_id;
    k := 1 + floor(random() * 2.4)::int;
    FOR j IN 1..k LOOP
      mid := (ARRAY[1,1,1,1,2,2,3,3,4,5,5,6,7,7,8])[1 + floor(random() * 15)::int];
      CONTINUE WHEN EXISTS (SELECT 1 FROM sincoffee.pesanan_item WHERE pesanan_id = v_id AND menu_id = mid);
      INSERT INTO sincoffee.pesanan_item (pesanan_id, menu_id, nama, harga, qty, suhu, manis)
      SELECT v_id, mn.id, mn.nama, mg.harga, CASE WHEN random() < 0.2 THEN 2 ELSE 1 END,
             CASE WHEN mn.pilihan_suhu IS NOT NULL THEN COALESCE(NULLIF(split_part(mn.pilihan_suhu, ',', 1 + floor(random() * 2)::int), ''), split_part(mn.pilihan_suhu, ',', 1)) END,
             CASE WHEN mn.pilihan_manis AND random() < 0.25 THEN 'Kurang manis' END
      FROM sincoffee.menu mn JOIN sincoffee.menu_gerai mg ON mg.menu_id = mn.id AND mg.gerai_id = 1 WHERE mn.id = mid;
    END LOOP;
    SELECT sum(harga * qty) INTO v_tot FROM sincoffee.pesanan_item WHERE pesanan_id = v_id;
    UPDATE sincoffee.pesanan SET total = v_tot WHERE id = v_id;
    INSERT INTO sincoffee.pembayaran (pesanan_id, gateway_order_id, jumlah, status, status_gateway, kedaluwarsa_pada, dibayar_pada, dibuat_pada)
    VALUES (v_id, 'CONTOH-' || v_tgl || '-' || lpad(i::text, 4, '0'), v_tot, 'LUNAS', 'settlement',
            now() - make_interval(secs => m * 60 - 900), now() - make_interval(secs => m * 60 - v_pay), now() - make_interval(secs => m * 60));
  END LOOP;
  INSERT INTO sincoffee.nomor_urut VALUES (1, (now() AT TIME ZONE 'Asia/Makassar')::date, 30);
  INSERT INTO sincoffee.log_aktivitas (gerai_id, tag, tingkat, pesan) VALUES (1, 'SISTEM', 'info', 'Data contoh dimuat: 30 pesanan selesai.');
END $$;

-- Selesai. Cek: SELECT public.sc_menu((SELECT token FROM sincoffee.meja_qr LIMIT 1));

-- Minta Supabase memuat ulang daftar fungsi API
NOTIFY pgrst, 'reload schema';
