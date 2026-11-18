-- =====================================================================
-- Sin Coffee v1.2: pembayaran QRIS lewat DOKU.
-- Jalankan SETELAH sincoffee_pengguna_menu.sql. Aman dijalankan ulang.
-- =====================================================================

-- Kolom untuk menyimpan string QRIS yang dibuat DOKU
ALTER TABLE sincoffee.pembayaran ADD COLUMN IF NOT EXISTS qr_string TEXT;

-- Tampilkan QR asli DOKU. Penanda demo hanya dipakai jika belum ada QR asli dan mode demo aktif.
CREATE OR REPLACE FUNCTION sincoffee.pesanan_json(p_id UUID) RETURNS JSON LANGUAGE sql STABLE AS $$
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
                     'qr_string', COALESCE(b.qr_string,
                        CASE WHEN sincoffee.cfg('mode_demo') = '1' THEN 'DEMO-QRIS|' || b.gateway_order_id || '|' || b.jumlah END))
                   FROM sincoffee.pembayaran b WHERE b.pesanan_id = p.id ORDER BY b.id DESC LIMIT 1)
  )
  FROM sincoffee.pesanan p LEFT JOIN sincoffee.meja_qr m ON m.id = p.meja_qr_id WHERE p.id = p_id
$$;

-- ---------- Fungsi khusus Edge Function (hanya service_role) ----------

CREATE OR REPLACE FUNCTION public.svc_pembayaran_qris(p_pesanan TEXT) RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER SET search_path = sincoffee, extensions AS $$
DECLARE o sincoffee.pesanan; b sincoffee.pembayaran;
BEGIN
  SELECT * INTO o FROM sincoffee.pesanan WHERE id = sincoffee.uuid_aman(p_pesanan);
  IF o.id IS NULL THEN RETURN json_build_object('ok', false, 'error', 'Pesanan tidak ditemukan.'); END IF;
  SELECT * INTO b FROM sincoffee.pembayaran WHERE pesanan_id = o.id ORDER BY id DESC LIMIT 1;
  IF b.id IS NULL THEN RETURN json_build_object('ok', false, 'error', 'Tagihan belum dibuat.'); END IF;
  RETURN json_build_object('ok', true, 'pembayaran_id', b.id, 'gateway_order_id', b.gateway_order_id,
    'jumlah', b.jumlah, 'status', b.status, 'kedaluwarsa_pada', b.kedaluwarsa_pada, 'qr_string', b.qr_string);
END $$;

CREATE OR REPLACE FUNCTION public.svc_simpan_qris(p_pembayaran_id INTEGER, p_qr TEXT) RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER SET search_path = sincoffee, extensions AS $$
BEGIN
  UPDATE sincoffee.pembayaran SET qr_string = p_qr
  WHERE id = p_pembayaran_id AND status = 'PENDING' AND qr_string IS NULL;
  RETURN json_build_object('ok', true);
END $$;

-- Notifikasi yang sudah diverifikasi Edge Function. Verifikasi ulang di sini memakai rahasia database.
CREATE OR REPLACE FUNCTION public.svc_notifikasi_doku(p_raw TEXT) RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = sincoffee, extensions AS $$
BEGIN
  RETURN sincoffee.proses_webhook(p_raw, sincoffee.tanda_tangan(p_raw), 'notifikasi-doku');
END $$;

REVOKE ALL ON FUNCTION public.svc_pembayaran_qris(TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.svc_simpan_qris(INTEGER, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.svc_notifikasi_doku(TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_pembayaran_qris(TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.svc_simpan_qris(INTEGER, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.svc_notifikasi_doku(TEXT) TO service_role;
