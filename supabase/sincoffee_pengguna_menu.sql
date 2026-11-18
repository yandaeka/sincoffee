-- Sin Coffee QR Order v1.1
-- =====================================================================
-- FITUR OWNER: tambah & ubah menu, kelola pengguna (barista / owner).
-- Jalankan SETELAH sincoffee_supabase.sql.
-- Jika sincoffee_supabase.sql dijalankan ulang, jalankan file ini lagi.
-- =====================================================================

-- ---------- MENU ----------
CREATE OR REPLACE FUNCTION public.sc_menu_tambah(p_sesi TEXT, p_kategori TEXT, p_nama TEXT, p_deskripsi TEXT,
  p_pilihan_suhu TEXT, p_pilihan_manis BOOLEAN, p_harga INTEGER) RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER SET search_path = sincoffee, extensions AS $$
DECLARE u pengguna; v_g INTEGER; v_id INTEGER; v_urut INTEGER;
BEGIN
  u := staf(p_sesi, ARRAY['owner']);
  IF u.id IS NULL THEN RETURN err('Sesi habis atau bukan akun owner.', 401); END IF;
  v_g := COALESCE(u.gerai_id, (SELECT min(id) FROM gerai));
  IF trim(COALESCE(p_kategori, '')) = '' OR trim(COALESCE(p_nama, '')) = '' THEN RETURN err('Kategori dan nama menu wajib diisi.'); END IF;
  IF p_harga IS NULL OR p_harga < 0 THEN RETURN err('Harga tidak valid.'); END IF;
  SELECT COALESCE(max(urutan), 0) + 10 INTO v_urut FROM menu;
  INSERT INTO menu (kode, kategori, nama, deskripsi, pilihan_suhu, pilihan_manis, urutan, aktif)
  VALUES ('M' || upper(encode(gen_random_bytes(4), 'hex')), trim(p_kategori), trim(p_nama),
          NULLIF(trim(COALESCE(p_deskripsi, '')), ''), NULLIF(trim(COALESCE(p_pilihan_suhu, '')), ''),
          COALESCE(p_pilihan_manis, FALSE), v_urut, TRUE)
  RETURNING id INTO v_id;
  INSERT INTO menu_gerai (menu_id, gerai_id, harga, tersedia) VALUES (v_id, v_g, p_harga, TRUE);
  PERFORM catat(v_g, 'ADMIN', 'info', 'Menu baru: ' || trim(p_nama), 'oleh ' || u.nama);
  RETURN json_build_object('ok', true, 'id', v_id);
END $$;

CREATE OR REPLACE FUNCTION public.sc_menu_harga(p_sesi TEXT, p_menu_id INTEGER, p_harga INTEGER) RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER SET search_path = sincoffee, extensions AS $$
DECLARE u pengguna; v_g INTEGER; v_nama TEXT;
BEGIN
  u := staf(p_sesi, ARRAY['owner']);
  IF u.id IS NULL THEN RETURN err('Sesi habis atau bukan akun owner.', 401); END IF;
  v_g := COALESCE(u.gerai_id, (SELECT min(id) FROM gerai));
  IF p_harga IS NULL OR p_harga < 0 THEN RETURN err('Harga tidak valid.'); END IF;
  UPDATE menu_gerai SET harga = p_harga WHERE menu_id = p_menu_id AND gerai_id = v_g;
  IF NOT FOUND THEN RETURN err('Menu tidak ditemukan.', 404); END IF;
  SELECT nama INTO v_nama FROM menu WHERE id = p_menu_id;
  PERFORM catat(v_g, 'ADMIN', 'info', v_nama || ' harga diubah menjadi Rp ' || p_harga, 'oleh ' || u.nama);
  RETURN json_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION public.sc_menu_aktif(p_sesi TEXT, p_menu_id INTEGER, p_aktif BOOLEAN) RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER SET search_path = sincoffee, extensions AS $$
DECLARE u pengguna; v_g INTEGER; v_nama TEXT;
BEGIN
  u := staf(p_sesi, ARRAY['owner']);
  IF u.id IS NULL THEN RETURN err('Sesi habis atau bukan akun owner.', 401); END IF;
  v_g := COALESCE(u.gerai_id, (SELECT min(id) FROM gerai));
  UPDATE menu SET aktif = p_aktif WHERE id = p_menu_id RETURNING nama INTO v_nama;
  IF NOT FOUND THEN RETURN err('Menu tidak ditemukan.', 404); END IF;
  PERFORM catat(v_g, 'ADMIN', 'info', v_nama || CASE WHEN p_aktif THEN ' diaktifkan' ELSE ' dinonaktifkan' END, 'oleh ' || u.nama);
  RETURN json_build_object('ok', true);
END $$;

-- ---------- PENGGUNA ----------
CREATE OR REPLACE FUNCTION public.sc_pengguna_daftar(p_sesi TEXT) RETURNS JSON
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = sincoffee, extensions AS $$
DECLARE u pengguna; v_g INTEGER;
BEGIN
  u := staf(p_sesi, ARRAY['owner']);
  IF u.id IS NULL THEN RETURN err('Sesi habis atau bukan akun owner.', 401); END IF;
  v_g := COALESCE(u.gerai_id, (SELECT min(id) FROM gerai));
  RETURN json_build_object('ok', true, 'id_saya', u.id, 'pengguna', (
    SELECT COALESCE(json_agg(json_build_object('id', p.id, 'nama', p.nama, 'peran', p.peran, 'aktif', p.aktif)
                             ORDER BY p.peran, p.nama), '[]'::json)
    FROM pengguna p WHERE p.gerai_id = v_g OR p.gerai_id IS NULL));
END $$;

CREATE OR REPLACE FUNCTION public.sc_pengguna_tambah(p_sesi TEXT, p_nama TEXT, p_peran TEXT, p_pin TEXT) RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER SET search_path = sincoffee, extensions AS $$
DECLARE u pengguna; v_g INTEGER; v_id INTEGER;
BEGIN
  u := staf(p_sesi, ARRAY['owner']);
  IF u.id IS NULL THEN RETURN err('Sesi habis atau bukan akun owner.', 401); END IF;
  v_g := COALESCE(u.gerai_id, (SELECT min(id) FROM gerai));
  IF trim(COALESCE(p_nama, '')) = '' THEN RETURN err('Nama wajib diisi.'); END IF;
  IF p_peran NOT IN ('barista', 'owner') THEN RETURN err('Peran harus barista atau owner.'); END IF;
  IF COALESCE(p_pin, '') !~ '^[0-9]{4,6}$' THEN RETURN err('PIN harus 4 sampai 6 angka.'); END IF;
  IF EXISTS (SELECT 1 FROM pengguna WHERE aktif AND peran = p_peran AND pin_hash = crypt(p_pin, pin_hash)) THEN
    RETURN err('PIN itu sudah dipakai akun lain dengan peran yang sama. Pilih PIN lain.');
  END IF;
  INSERT INTO pengguna (gerai_id, nama, peran, pin_hash, aktif)
  VALUES (v_g, trim(p_nama), p_peran, crypt(p_pin, gen_salt('bf')), TRUE) RETURNING id INTO v_id;
  PERFORM catat(v_g, 'ADMIN', 'info', 'Pengguna baru: ' || trim(p_nama) || ' (' || p_peran || ')', 'oleh ' || u.nama);
  RETURN json_build_object('ok', true, 'id', v_id);
END $$;

CREATE OR REPLACE FUNCTION public.sc_pengguna_aktif(p_sesi TEXT, p_id INTEGER, p_aktif BOOLEAN) RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER SET search_path = sincoffee, extensions AS $$
DECLARE u pengguna; v_g INTEGER; v_target pengguna;
BEGIN
  u := staf(p_sesi, ARRAY['owner']);
  IF u.id IS NULL THEN RETURN err('Sesi habis atau bukan akun owner.', 401); END IF;
  v_g := COALESCE(u.gerai_id, (SELECT min(id) FROM gerai));
  SELECT * INTO v_target FROM pengguna WHERE id = p_id AND (gerai_id = v_g OR gerai_id IS NULL);
  IF NOT FOUND THEN RETURN err('Pengguna tidak ditemukan.', 404); END IF;
  IF NOT p_aktif AND v_target.id = u.id THEN RETURN err('Tidak bisa menonaktifkan akun sendiri.'); END IF;
  IF NOT p_aktif AND v_target.peran = 'owner' AND
     (SELECT count(*) FROM pengguna WHERE aktif AND peran = 'owner' AND (gerai_id = v_g OR gerai_id IS NULL)) <= 1 THEN
    RETURN err('Harus ada minimal satu akun owner yang aktif.');
  END IF;
  UPDATE pengguna SET aktif = p_aktif WHERE id = p_id;
  PERFORM catat(v_g, 'ADMIN', 'info', v_target.nama || CASE WHEN p_aktif THEN ' diaktifkan' ELSE ' dinonaktifkan' END, 'oleh ' || u.nama);
  RETURN json_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION public.sc_pengguna_pin(p_sesi TEXT, p_id INTEGER, p_pin TEXT) RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER SET search_path = sincoffee, extensions AS $$
DECLARE u pengguna; v_g INTEGER; v_target pengguna;
BEGIN
  u := staf(p_sesi, ARRAY['owner']);
  IF u.id IS NULL THEN RETURN err('Sesi habis atau bukan akun owner.', 401); END IF;
  v_g := COALESCE(u.gerai_id, (SELECT min(id) FROM gerai));
  IF COALESCE(p_pin, '') !~ '^[0-9]{4,6}$' THEN RETURN err('PIN harus 4 sampai 6 angka.'); END IF;
  SELECT * INTO v_target FROM pengguna WHERE id = p_id AND (gerai_id = v_g OR gerai_id IS NULL);
  IF NOT FOUND THEN RETURN err('Pengguna tidak ditemukan.', 404); END IF;
  IF EXISTS (SELECT 1 FROM pengguna WHERE id <> p_id AND aktif AND peran = v_target.peran AND pin_hash = crypt(p_pin, pin_hash)) THEN
    RETURN err('PIN itu sudah dipakai akun lain dengan peran yang sama. Pilih PIN lain.');
  END IF;
  UPDATE pengguna SET pin_hash = crypt(p_pin, gen_salt('bf')) WHERE id = p_id;
  PERFORM catat(v_g, 'ADMIN', 'info', 'PIN ' || v_target.nama || ' diganti', 'oleh ' || u.nama);
  RETURN json_build_object('ok', true);
END $$;

-- Hak akses: website (anon) hanya boleh memanggil fungsi sc_*
DO $$
DECLARE f RECORD;
BEGIN
  FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'public' AND p.proname LIKE 'sc\_%' LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO anon, authenticated', f.sig);
  END LOOP;
END $$;

-- Daftar semua menu (termasuk yang nonaktif) untuk halaman Pengaturan owner
CREATE OR REPLACE FUNCTION public.sc_menu_semua(p_sesi TEXT) RETURNS JSON
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = sincoffee, extensions AS $$
DECLARE u pengguna; v_g INTEGER;
BEGIN
  u := staf(p_sesi, ARRAY['owner']);
  IF u.id IS NULL THEN RETURN err('Sesi habis atau bukan akun owner.', 401); END IF;
  v_g := COALESCE(u.gerai_id, (SELECT min(id) FROM gerai));
  RETURN json_build_object('ok', true, 'menu', (
    SELECT COALESCE(json_agg(json_build_object('id', m.id, 'kategori', m.kategori, 'nama', m.nama,
             'harga', mg.harga, 'aktif', m.aktif, 'pilihan_suhu', m.pilihan_suhu, 'pilihan_manis', m.pilihan_manis)
             ORDER BY m.urutan, m.id), '[]'::json)
    FROM menu m LEFT JOIN menu_gerai mg ON mg.menu_id = m.id AND mg.gerai_id = v_g));
END $$;

REVOKE ALL ON FUNCTION public.sc_menu_semua(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.sc_menu_semua(TEXT) TO anon, authenticated;
