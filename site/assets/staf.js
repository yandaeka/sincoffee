/* Utilitas halaman staf: sesi, header, panggilan API */
window.STAF = (function () {
  const KEY = 'sc_sesi';
  const VERSI = '1.1';
  const page = location.pathname.split('/').pop() || 'index.html';
  const sesi = (() => { try { return localStorage.getItem(KEY) || ''; } catch (e) { return ''; } })();
  const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const pad = (n, l) => String(n).padStart(l, '0');
  const mmss = s => { s = Math.max(0, Math.round(s)); return pad(Math.floor(s / 60), 2) + ':' + pad(s % 60, 2); };
  const fmt = n => 'Rp ' + Math.round(+n).toLocaleString('id-ID');
  const fmtS = n => { n = +n; return n >= 1e6 ? 'Rp ' + (n / 1e6).toLocaleString('id-ID', { maximumFractionDigits: 1 }) + ' jt' : n >= 1e3 ? 'Rp ' + Math.round(n / 1e3) + ' rb' : 'Rp ' + n; };

  function keLogin() { location.href = 'login.html?ke=' + encodeURIComponent(page); }
  if (!sesi) keLogin();

  const MAP = {
    info: ['sc_info', () => ({})],
    queue: ['sc_queue', () => ({})],
    advance: ['sc_advance', b => ({ p_id: b.id, p_dari: b.dari })],
    menu_admin: ['sc_menu_admin', () => ({})],
    toggle_menu: ['sc_toggle_menu', b => ({ p_menu_id: +b.id, p_tersedia: !!b.tersedia })],
    stats: ['sc_stats', () => ({})],
    qr: ['sc_qr_list', () => ({})],
    reset: ['sc_reset', () => ({})],
    menu_semua: ['sc_menu_semua', () => ({})],
    menu_tambah: ['sc_menu_tambah', b => ({ p_kategori: b.kategori, p_nama: b.nama, p_deskripsi: b.deskripsi, p_pilihan_suhu: b.suhu, p_pilihan_manis: !!b.manis, p_harga: +b.harga })],
    menu_harga: ['sc_menu_harga', b => ({ p_menu_id: +b.id, p_harga: +b.harga })],
    menu_aktif: ['sc_menu_aktif', b => ({ p_menu_id: +b.id, p_aktif: !!b.aktif })],
    pengguna: ['sc_pengguna_daftar', () => ({})],
    pengguna_tambah: ['sc_pengguna_tambah', b => ({ p_nama: b.nama, p_peran: b.peran, p_pin: b.pin })],
    pengguna_aktif: ['sc_pengguna_aktif', b => ({ p_id: +b.id, p_aktif: !!b.aktif })],
    pengguna_pin: ['sc_pengguna_pin', b => ({ p_id: +b.id, p_pin: b.pin })]
  };
  async function api(a, body) {
    const [fn, f] = MAP[a];
    try { return await SB.rpc(fn, Object.assign({ p_sesi: sesi }, f(body || {}))); }
    catch (e) { if (e.code === 401) { keLogin(); throw new Error('login'); } throw e; }
  }

  async function header() {
    const el = document.getElementById('top'); if (!el) return null;
    try {
      const u = await api('info');
      const links = u.peran === 'owner' ? [['ringkasan.html', 'Ringkasan'], ['barista.html', 'Barista'], ['pengaturan.html', 'Pengaturan'], ['qr.html', 'QR meja']] : [['barista.html', 'Barista']];
      if (u.peran !== 'owner' && page !== 'barista.html') { location.href = 'barista.html'; return null; }
      el.innerHTML = `<div class="inner"><div class="brand"><span class="logo"><img src="assets/logo-sin.jpg" alt="Sin Coffee" width="36" height="36" style="width:36px;height:36px"></span><div><b>Sin Coffee · ${esc(u.gerai.kode)}</b><small>${esc(u.gerai.nama)}· v${VERSI}</small></div></div>
        <nav class="nav" aria-label="Menu staf">${links.map(([h, l]) => `<a href="${h}" ${h === page ? 'aria-current="page"' : ''}>${l}</a>`).join('')}</nav>
        <span class="who">${esc(u.nama)} · <a href="#" id="keluar">Keluar</a></span></div>`;
      document.getElementById('keluar').addEventListener('click', async ev => {
        ev.preventDefault();
        try { await SB.rpc('sc_logout', { p_sesi: sesi }); } catch (e) {}
        try { localStorage.removeItem(KEY); } catch (e) {}
        location.href = 'login.html';
      });
      return u;
    } catch (e) {
      if (e.message !== 'login') el.innerHTML = `<div class="inner"><div class="brand"><span class="logo"><img src="assets/logo-sin.jpg" alt="Sin Coffee" width="36" height="36" style="width:36px;height:36px"></span><b>Sin Coffee</b></div><span class="who">${esc(e.message)}</span></div>`;
      return null;
    }
  }

  let actx = null;
  function unlock() { try { if (!actx) { const A = window.AudioContext || window.webkitAudioContext; actx = new A(); } if (actx.state === 'suspended') actx.resume(); } catch (e) {} }
  function beep(f) {
    try {
      if (!actx) return;
      const nada = [f || 660, (f || 660) * 1.335, (f || 660) * 1.5];
      [0, .22, .6, .82].forEach((t, i) => {
        const o = actx.createOscillator(), g = actx.createGain();
        o.type = 'square'; o.frequency.value = nada[i % 3];
        o.connect(g); g.connect(actx.destination);
        const t0 = actx.currentTime + t;
        g.gain.setValueAtTime(.0001, t0); g.gain.exponentialRampToValueAtTime(.6, t0 + .02); g.gain.exponentialRampToValueAtTime(.0001, t0 + .18);
        o.start(t0); o.stop(t0 + .2);
      });
    } catch (e) {}
  }

  const ready = header();
  return { api, esc, mmss, fmt, fmtS, unlock, beep, pad, ready };
})();
