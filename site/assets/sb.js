/* Panggilan ke fungsi database Supabase (RPC) */
window.SB = (function () {
  const C = window.SC_CONFIG || {};
  const siap = C.url && C.anonKey && !/^ISI_/.test(C.url) && !/^ISI_/.test(C.anonKey);
  const base = siap ? C.url.replace(/\/+$/, '') : '';

  async function rpc(fn, args) {
    if (!siap) { const e = new Error('Aplikasi belum diatur. Isi url dan anonKey di assets/config.js.'); e.code = 0; throw e; }
    let r;
    try {
      r = await fetch(base + '/rest/v1/rpc/' + fn, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', apikey: C.anonKey, Authorization: 'Bearer ' + C.anonKey },
        body: JSON.stringify(args || {})
      });
    } catch (e) { const er = new Error('Tidak ada koneksi ke server. Periksa internet.'); er.code = 0; er.network = true; throw er; }
    let d = null;
    try { d = await r.json(); } catch (e) { /* abaikan */ }
    if (!r.ok) {
      let msg = (d && (d.message || d.hint)) || 'Server mengalami gangguan.';
      if (r.status === 404 && d && d.code === 'PGRST202') msg = 'Fungsi database belum dipasang. Jalankan file SQL di Supabase.';
      if (r.status === 401) msg = 'Kunci Supabase salah. Periksa anonKey di assets/config.js.';
      const e = new Error(msg); e.code = r.status; throw e;
    }
    if (d && d.ok === false) { const e = new Error(d.error || 'Terjadi kesalahan.'); e.code = d.code || 400; throw e; }
    return d;
  }
  return { rpc, siap };
})();
