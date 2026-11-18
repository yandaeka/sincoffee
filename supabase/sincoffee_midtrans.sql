-- =====================================================================
-- Sin Coffee v1.3: pembayaran QRIS lewat Midtrans.
-- Jalankan SETELAH sincoffee_doku.sql. Aman dijalankan ulang.
-- =====================================================================

-- 1. QR pelanggan hanya berasal dari Midtrans. Teks DEMO-QRIS tidak lagi dipakai.
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
                     'qr_string', b.qr_string)
                   FROM sincoffee.pembayaran b WHERE b.pesanan_id = p.id ORDER BY b.id DESC LIMIT 1)
  )
  FROM sincoffee.pesanan p LEFT JOIN sincoffee.meja_qr m ON m.id = p.meja_qr_id WHERE p.id = p_id
$$;

-- 2. Pintu notifikasi Midtrans. Verifikasi signature_key dilakukan di Edge Function.
--    Di sini notifikasi diteruskan ke proses_webhook yang sudah ada (memakai tanda tangan internal).
CREATE OR REPLACE FUNCTION public.svc_notifikasi_midtrans(p_raw TEXT) RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = sincoffee, extensions AS $$
BEGIN
  RETURN sincoffee.proses_webhook(p_raw, sincoffee.tanda_tangan(p_raw), 'notifikasi-midtrans');
END $$;

REVOKE ALL ON FUNCTION public.svc_notifikasi_midtrans(TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.svc_notifikasi_midtrans(TEXT) TO service_role;
