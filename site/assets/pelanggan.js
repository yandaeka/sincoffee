/* Halaman pelanggan: menu, keranjang, bayar QRIS, status pesanan. */
(function () {
  'use strict';
  const TOKEN = window.SC.token;
  const KEY_CART = 'sc_cart_' + TOKEN, KEY_ORDER = 'sc_order_' + TOKEN, KEY_NAME = 'sc_name', KEY_NOTIF = 'sc_notif';
  const TINT = { 'Aren Series': ['#F3E3CF', '#8A5A2B'], 'Americano Series': ['#E7E1DA', '#3B2A20'], 'Non Coffee': ['#E3EEDC', '#3F6B2A'], 'Camilan': ['#F6E8C8', '#8A6A12'] };
  const store = {
    get(k, d) { try { const v = localStorage.getItem(k); return v === null ? d : JSON.parse(v); } catch (e) { return d; } },
    set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) {} },
    del(k) { try { localStorage.removeItem(k); } catch (e) {} }
  };
  const S = { info: null, menu: [], cart: store.get(KEY_CART, []), name: store.get(KEY_NAME, ''), sheet: null, screen: 'menu', order: null,
    notif: store.get(KEY_NOTIF, false), push: null, busy: false, error: null, idem: null, lastProd: null, poll: null, cat: null };

  const el = document.getElementById('app');
  const fmt = n => 'Rp ' + Math.round(n).toLocaleString('id-ID');
  const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const pad = (n, l) => String(n).padStart(l, '0');
  const mmss = s => pad(Math.floor(Math.max(0, s) / 60), 2) + ':' + pad(Math.max(0, s) % 60, 2);
  const hhmm = d => d ? d.slice(11, 16).replace(':', '.') : '';
  const optText = i => [i.suhu, i.manis].filter(Boolean).join(', ');
  const rid = () => Array.from(crypto.getRandomValues(new Uint8Array(12)), b => b.toString(16).padStart(2, '0')).join('');

  // ---------- suara & notifikasi ----------
  let actx = null;
  function unlockAudio() { try { if (!actx) { const A = window.AudioContext || window.webkitAudioContext; actx = new A(); } if (actx.state === 'suspended') actx.resume(); } catch (e) {} }
  document.addEventListener('click', unlockAudio, { capture: true });
  function beep() {
    try { unlockAudio(); [0, .2, .4].forEach(t => { const o = actx.createOscillator(), g = actx.createGain(); o.frequency.value = 880; o.connect(g); g.connect(actx.destination);
      g.gain.setValueAtTime(.0001, actx.currentTime + t); g.gain.exponentialRampToValueAtTime(.25, actx.currentTime + t + .02); g.gain.exponentialRampToValueAtTime(.0001, actx.currentTime + t + .16); o.start(actx.currentTime + t); o.stop(actx.currentTime + t + .18); }); } catch (e) {}
    try { navigator.vibrate && navigator.vibrate([250, 120, 250]); } catch (e) {}
  }
  function notifySiap(o) {
    const msg = `Pesanan ${o.nomor.slice(-4)}${o.nama ? ' atas nama ' + o.nama : ''} siap diambil di bar.`;
    S.push = msg; beep();
    try { if (S.notif && 'Notification' in window && Notification.permission === 'granted') new Notification('Sin Coffee · Pesanan siap', { body: msg, tag: o.id }); } catch (e) {}
    setTimeout(() => { S.push = null; render(); }, 7000);
  }

  // ---------- ikon ----------
  const cup = c => `<svg viewBox="0 0 24 24" fill="none" stroke="${c}" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 8h12v6a5 5 0 0 1-5 5h-2a5 5 0 0 1-5-5V8z"/><path d="M17 10h1.5a2.5 2.5 0 0 1 0 5H17"/><path d="M8 3c0 1 1 1 1 2s-1 1-1 2M12 3c0 1 1 1 1 2s-1 1-1 2"/></svg>`;
  const bowl = c => `<svg viewBox="0 0 24 24" fill="none" stroke="${c}" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 11h18a9 9 0 0 1-18 0z"/><path d="M8 7l1-2M12 7V4M16 7l-1-2"/></svg>`;
  const thumb = m => { const t = TINT[m.kategori] || ['#EEE', '#555']; return `<span class="thumb" style="background:${t[0]}">${m.kategori === 'Camilan' ? bowl(t[1]) : cup(t[1])}</span>`; };
  const backI = `<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M15 18l-6-6 6-6"/></svg>`;
  const bellI = `<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/><path d="M10.3 21a1.94 1.94 0 0 0 3.4 0"/></svg>`;

  // QR tagihan. Di produksi: string QRIS dari gateway. Di demo: penanda tagihan (tidak bisa dibayar).
  function qrImg(text) {
    // Midtrans mengirim URL gambar QRIS. Tampilkan gambar itu langsung.
    if (/^https?:\/\//.test(text)) return `<img src="${esc(text)}" alt="QRIS untuk pembayaran" width="240" height="240" style="width:240px;height:240px;display:block;margin:0 auto">`;
    try { const q = qrcode(0, 'M'); q.addData(text); q.make(); return q.createSvgTag({ cellSize: 6, margin: 0, scalable: true }); }
    catch (e) { return '<div class="hint">QR tidak tersedia</div>'; }
  }

  const cartCount = () => S.cart.reduce((s, i) => s + i.qty, 0);
  const cartTotal = () => S.cart.reduce((s, i) => { const m = S.menu.find(x => x.id === i.menu_id); return s + (m ? m.harga : 0) * i.qty; }, 0);
  const saveCart = () => store.set(KEY_CART, S.cart);

  // ---------- tampilan ----------
  function vMenu() {
    const cats = [...new Set(S.menu.map(m => m.kategori))];
    if (!S.cat) S.cat = cats[0];
    let h = `<header class="phero pp"><small>${esc(S.info.gerai.nama)} · ${esc(S.info.gerai.alamat || '')}</small><h1>Halo, mau ngopi apa hari ini?</h1><div style="display:flex;gap:8px;flex-wrap:wrap;margin-top:4px"><span class="pill">${esc(S.info.meja)}</span><span class="pill">Bayar pakai QRIS</span></div></header>`;
    h += `<nav class="cats pp" aria-label="Kategori menu">${cats.map(c => `<button data-a="cat" data-c="${esc(c)}" aria-current="${S.cat === c}">${esc(c)}</button>`).join('')}</nav><div class="pp">`;
    cats.forEach((c, ci) => {
      h += `<h2 class="sec-h" id="cat-${ci}">${esc(c)}</h2>`;
      S.menu.filter(m => m.kategori === c).forEach(m => {
        const n = S.cart.filter(i => i.menu_id === m.id).reduce((s, i) => s + i.qty, 0);
        h += `<button class="mi ${m.tersedia ? '' : 'habis'}" data-a="open" data-id="${m.id}" ${m.tersedia ? '' : 'disabled'} aria-label="${esc(m.nama)}, ${fmt(m.harga)}">${thumb(m)}<span><b>${esc(m.nama)}</b><p>${esc(m.deskripsi || '')}</p><span class="price">${m.tersedia ? fmt(m.harga) : 'Habis'}</span></span>${!m.tersedia ? '' : n ? `<span class="inc">${n}</span>` : `<span class="add" aria-hidden="true">+</span>`}</button>`;
      });
    });
    h += `<p class="hint" style="text-align:center;padding-block:14px">Tidak perlu instal aplikasi.</p></div>`;
    if (cartCount()) h += `<div class="pfoot pp"><button class="btn btn-p btn-split" data-a="go" data-s="cart"><span>${cartCount()} item · Lihat pesanan</span><span class="mono">${fmt(cartTotal())}</span></button></div>`;
    return h;
  }
  function vSheet() {
    const s = S.sheet, m = S.menu.find(x => x.id === s.id);
    return `<div class="scrim" data-a="close-sheet"><div class="sheet pp" role="dialog" aria-modal="true" aria-label="${esc(m.nama)}"><div class="grab"></div><div class="stack">
      <div class="row"><div><h3 style="margin:0;font-size:21px;font-weight:800">${esc(m.nama)}</h3><small>${esc(m.deskripsi || '')}</small></div><span class="price" style="font-size:16px">${fmt(m.harga)}</span></div>
      ${m.suhu ? `<div><span class="lbl">Suhu</span><div class="opts">${m.suhu.map(t => `<button class="opt" data-a="opt" data-k="suhu" data-v="${esc(t)}" aria-pressed="${s.suhu === t}">${esc(t)}</button>`).join('')}</div></div>` : ''}
      ${m.manis ? `<div><span class="lbl">Tingkat manis</span><div class="opts">${['Normal', 'Kurang manis', 'Tanpa gula'].map(t => `<button class="opt" data-a="opt" data-k="manis" data-v="${t}" aria-pressed="${s.manis === t}">${t}</button>`).join('')}</div></div>` : ''}
      <div><label class="lbl" for="item-note">Catatan <span class="hint">(opsional)</span></label><textarea id="item-note" maxlength="120" placeholder="Contoh: es sedikit">${esc(s.catatan)}</textarea></div>
      <div class="row" style="align-items:center"><span class="lbl" style="margin:0">Jumlah</span><div class="qty"><button class="qb" data-a="sq" data-d="-1" aria-label="Kurangi">−</button><span class="mono" style="font-weight:700;min-width:22px;text-align:center">${s.qty}</span><button class="qb" data-a="sq" data-d="1" aria-label="Tambah">+</button></div></div>
      <button class="btn btn-p btn-split" data-a="add"><span>Tambah ke pesanan</span><span class="mono">${fmt(m.harga * s.qty)}</span></button></div></div></div>`;
  }
  function vCart() {
    let h = `<div class="pbar pp"><button class="iconbtn" data-a="go" data-s="menu" aria-label="Kembali ke menu">${backI}</button><h2>Pesanan kamu</h2></div><div class="pp stack">`;
    h += `<div class="pcard">`;
    S.cart.forEach((i, ix) => { const m = S.menu.find(x => x.id === i.menu_id) || { nama: '?', harga: 0 };
      h += `<div class="row"><div style="min-width:0"><b>${esc(m.nama)}</b><small>${esc(optText(i) || '—')}${i.catatan ? ' · ' + esc(i.catatan) : ''}</small><span class="price mono">${fmt(m.harga * i.qty)}</span></div><div class="qty"><button class="qb" data-a="cq" data-i="${ix}" data-d="-1" aria-label="Kurangi ${esc(m.nama)}">−</button><span class="mono" style="font-weight:700">${i.qty}</span><button class="qb" data-a="cq" data-i="${ix}" data-d="1" aria-label="Tambah ${esc(m.nama)}">+</button></div></div>`; });
    h += `<div class="total"><span>Total</span><span class="mono">${fmt(cartTotal())}</span></div></div>`;
    h += `<div><label class="lbl" for="cust-name">Nama untuk dipanggil</label><input type="text" id="cust-name" maxlength="40" placeholder="Contoh: Rina" value="${esc(S.name)}" autocomplete="given-name"><p class="hint" style="margin:6px 0 0">Barista memanggil nama dan nomor pesanan saat siap.</p></div>`;
    h += `<div><span class="lbl">Metode pembayaran</span><div class="paym"><span class="qris">QRIS</span><div><b style="font-size:14px">QRIS</b><div class="hint">GoPay, OVO, DANA, ShopeePay, m-banking</div></div></div></div>`;
    if (S.error) h += `<div class="banner b-err" role="alert">${esc(S.error)}</div>`;
    h += `<p class="hint" style="margin:0">${esc(S.info.meja)} · pesanan dibuat barista setelah pembayaran berhasil.</p></div>`;
    h += `<div class="pfoot pp"><button class="btn btn-p btn-split" data-a="checkout" ${S.busy ? 'disabled' : ''}><span>${S.busy ? 'Membuat pesanan…' : 'Bayar sekarang'}</span><span class="mono">${fmt(cartTotal())}</span></button></div>`;
    return h;
  }
  // Minta QRIS asli dari DOKU lewat Edge Function (satu permintaan berjalan dalam satu waktu)
  let qrSedangDiminta = false;
  async function ambilQris() {
    if (qrSedangDiminta || !S.order || !S.order.pembayaran || S.order.pembayaran.qr_string) return;
    qrSedangDiminta = true;
    try {
      const r = await fetch(SC_CONFIG.url.replace(/\/+$/, '') + '/functions/v1/midtrans-qris', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', apikey: SC_CONFIG.anonKey, Authorization: 'Bearer ' + SC_CONFIG.anonKey },
        body: JSON.stringify({ pesanan_id: S.order.id })
      });
      const d = await r.json().catch(() => ({}));
      if (d.ok && d.qr_string) { S.order.pembayaran.qr_string = d.qr_string; S.error = null; }
      else S.error = 'QRIS belum bisa dibuat (' + r.status + '): ' + (d.error || d.message || d.msg || 'tidak ada rincian dari server') + '. Coba lagi sebentar.';
      if (!(d.ok && d.qr_string)) S.qrGagalAt = Date.now();
    } catch (e) { S.error = 'Tidak bisa membuat QRIS: ' + (e.message || 'koneksi gagal') + '.'; S.qrGagalAt = Date.now(); }
    qrSedangDiminta = false;
    render();
  }

  // Simpan QRIS sebagai gambar PNG supaya pelanggan bisa upload dari galeri di aplikasi pembayaran
  function simpanQr(teks, nomor) {
    if (/^https?:\/\//.test(teks)) { window.open(teks, '_blank', 'noopener'); return; }
    try {
      const q = qrcode(0, 'M'); q.addData(teks); q.make();
      const img = new Image();
      img.onload = () => {
        const c = document.createElement('canvas');
        c.width = img.width; c.height = img.height;
        c.getContext('2d').drawImage(img, 0, 0);
        const a = document.createElement('a');
        a.download = 'QRIS-' + String(nomor || 'pesanan').replace(/[^A-Za-z0-9-]/g, '') + '.png';
        a.href = c.toDataURL('image/png');
        document.body.appendChild(a); a.click(); a.remove();
      };
      img.src = q.createDataURL(10, 4);
    } catch (e) { S.error = 'QR tidak bisa disimpan. Coba screenshot layar ini.'; render(); }
  }

  function vPay(o) {
    const p = o.pembayaran;
    let h = `<div class="pbar pp"><h2>Pembayaran</h2></div><div class="pp stack" style="text-align:center">`;
    h += `<div><div class="hint">Total pembayaran</div><div class="amount mono">${fmt(o.total)}</div><div class="hint mono">${esc(o.nomor)}</div></div>`;
    h += `<div class="qrwrap">${p.qr_string ? qrImg(p.qr_string) : '<div class="hint" style="padding:40px 0">Menyiapkan QRIS…</div>'}<span class="nm">SIN COFFEE · QRIS</span></div>`;
    if (!p.qr_string && o.status_bayar === 'BELUM_BAYAR' && (!S.qrGagalAt || Date.now() - S.qrGagalAt > 8000)) setTimeout(ambilQris, 0);
    if (p.qr_string) h += `<button class="btn btn-g" data-a="simpan-qr" style="margin-top:10px">Simpan QR ke galeri</button>`;
    h += `<span class="timer">Bayar dalam <span class="mono" id="sisa" data-end="${Date.now() + p.sisa_detik * 1000}">${mmss(p.sisa_detik)}</span></span>`;
    h += `<div class="wait" role="status"><span class="spin" aria-hidden="true"></span>${S.busy ? 'Mengecek status pembayaran…' : 'Menunggu pembayaran. Halaman ini berubah otomatis.'}</div>`;
    h += `<button class="btn btn-g" data-a="check" ${S.busy ? 'disabled' : ''}>Saya sudah bayar, cek status</button>`;
    if (S.error) h += `<div class="banner b-err" role="alert">${esc(S.error)}</div>`;
    h += `<button class="btn" data-a="cancel" style="min-height:44px;background:transparent;color:var(--muted);font-weight:600">Batalkan pesanan</button></div>`;
    return h;
  }
  const STEPS = [
    { k: 'LUNAS', t: 'Pembayaran berhasil', d: o => 'Lunas pukul ' + hhmm(o.dibayar_pada) },
    { k: 'MENUNGGU', t: 'Pesanan diterima barista', d: () => 'Masuk antrean' },
    { k: 'DIPROSES', t: 'Sedang dibuat', d: () => 'Barista sedang menyiapkan pesananmu' },
    { k: 'SIAP', t: 'Siap diambil', d: () => 'Ambil di bar, sebutkan nama dan nomor' },
    { k: 'SELESAI', t: 'Selesai', d: () => 'Selamat menikmati' }];
  function vStatus(o) {
    const label = { MENUNGGU: 'Dalam antrean', DIPROSES: 'Sedang dibuat', SIAP: 'Siap diambil', SELESAI: 'Selesai' }[o.status_produksi];
    let h = `<div class="pbar pp"><h2>Status pesanan</h2></div><div class="pp stack">`;
    h += `<div class="ticket ${o.status_produksi === 'SIAP' ? 'ready' : ''}"><small>Nomor pesanan${o.nama ? ' · ' + esc(o.nama) : ''}</small><span class="no">${esc(o.nomor.slice(-4))}</span><span class="full">${esc(o.nomor)} · ${esc(o.meja || '')}</span><span class="state" role="status">${label}</span></div>`;
    if (o.status_produksi === 'SIAP') h += `<div class="banner b-ok">Pesananmu siap. Ambil di bar dan sebutkan nomor ${esc(o.nomor.slice(-4))}.</div>`;
    if (o.status_produksi === 'SELESAI') h += `<div class="banner b-ok">Terima kasih sudah pesan di Sin Coffee.</div>`;
    if (o.terlambat) h += `<div class="banner b-warn">Pembayaran masuk setelah QR kedaluwarsa. Pesanan tetap dibuat.</div>`;
    const idx = STEPS.findIndex(s => s.k === o.status_produksi);
    h += `<div class="pcard"><div class="track">${STEPS.map((s, i) => { const done = i < idx || (i === idx && s.k === 'SELESAI'), cur = i === idx && !done;
      return `<div class="st ${done ? 'done' : cur ? 'now' : 'todo'}"><span class="dot">${done ? '✓' : i + 1}</span><div><b>${s.t}</b>${done || cur ? `<span>${s.d(o)}</span>` : ''}</div></div>`; }).join('')}</div></div>`;
    if (o.status_produksi !== 'SELESAI') h += `<div class="pcard notif"><span class="bell">${bellI}</span><div style="flex:1;min-width:0"><b style="font-size:14px">Kabari saya saat siap</b><div class="hint">${S.notif ? 'Aktif. Bunyi dan notifikasi muncul saat pesanan siap.' : 'Biarkan halaman ini terbuka. Kami bunyikan saat siap.'}</div></div><button class="switch" role="switch" aria-checked="${S.notif}" aria-label="Notifikasi pesanan siap" data-a="notif"></button></div>`;
    h += `<details class="pcard"><summary>Detail pesanan <span class="mono">${fmt(o.total)}</span></summary>${o.items.map(i => `<div class="row" style="margin-top:10px"><div><b style="font-size:14px">${i.qty}× ${esc(i.nama)}</b><small>${esc(optText(i) || '—')}${i.catatan ? ' · ' + esc(i.catatan) : ''}</small></div><span class="mono">${fmt(i.harga * i.qty)}</span></div>`).join('')}<div class="row" style="margin-top:10px"><small>Dibayar dengan QRIS</small><small class="mono">${esc(o.pembayaran ? o.pembayaran.gateway_order_id : '')}</small></div></details>`;
    if (o.status_produksi === 'SELESAI') h += `<button class="btn btn-p" data-a="again">Pesan lagi</button>`;
    return h + `</div>`;
  }
  function vFail(o) {
    return `<div class="pbar pp"><h2>Pembayaran</h2></div><div class="pp stack"><div class="banner b-err">${o.status_bayar === 'KEDALUWARSA' ? 'Waktu bayar habis. Pesananmu belum dibuat.' : 'Pembayaran gagal. Saldo kamu tidak terpotong.'}</div>
      <div class="pcard"><div class="row"><span>Total</span><b class="mono">${fmt(o.total)}</b></div><div class="row"><small>Nomor pesanan</small><small class="mono">${esc(o.nomor)}</small></div></div>
      ${S.error ? `<div class="banner b-err" role="alert">${esc(S.error)}</div>` : ''}
      <button class="btn btn-p" data-a="repay" ${S.busy ? 'disabled' : ''}>Coba bayar lagi</button><button class="btn btn-g" data-a="edit">Ubah pesanan</button></div>`;
  }

  function render() {
    let h = '';
    if (S.fatal) h = `<div class="err-screen"><h2 style="margin:0">QR tidak dikenali</h2><p class="hint">${esc(S.fatal)}</p></div>`;
    else if (!S.info) h = `<div class="err-screen"><span class="spin"></span></div>`;
    else if (S.screen === 'order' && S.order) {
      const o = S.order;
      if (o.status_bayar === 'LUNAS') h = vStatus(o);
      else if (o.status_bayar === 'GAGAL' || o.status_bayar === 'KEDALUWARSA') h = vFail(o);
      else h = vPay(o);
    } else if (S.screen === 'cart' && S.cart.length) h = vCart();
    else h = vMenu();
    if (S.sheet) h += vSheet();
    if (S.push) h += `<div class="push" role="alert"><span class="ic">SC</span><div><b>Sin Coffee · Pesanan siap</b><span>${esc(S.push)}</span></div></div>`;
    el.innerHTML = h;
    const n = document.getElementById('cust-name'); if (n) n.addEventListener('input', e => { S.name = e.target.value; store.set(KEY_NAME, S.name); });
    const t = document.getElementById('item-note'); if (t) t.addEventListener('input', e => { S.sheet.catatan = e.target.value; });
  }

  // ---------- alur ----------
  function setOrder(o) {
    const prev = S.lastProd;
    S.order = o; S.lastProd = o.status_produksi;
    if (prev && prev !== 'SIAP' && o.status_produksi === 'SIAP') notifySiap(o);
    if (o.status_bayar === 'DIBATALKAN') { store.del(KEY_ORDER); S.order = null; S.screen = 'cart'; return; }
    store.set(KEY_ORDER, o.id);
  }
  function startPoll() {
    stopPoll();
    S.poll = setInterval(async () => {
      if (!S.order || S.order.status_produksi === 'SELESAI') return stopPoll();
      try { const d = await SB.rpc('sc_status', { p_id: S.order.id }); setOrder(d.order); S.error = null; render(); }
      catch (e) { /* koneksi putus: coba lagi pada putaran berikutnya */ }
    }, 3000);
  }
  function stopPoll() { if (S.poll) { clearInterval(S.poll); S.poll = null; } }

  async function checkout() {
    if (S.busy) return;
    S.busy = true; S.error = null; render();
    if (!S.idem) S.idem = rid(); // kunci yang sama dipakai jika tombol ditekan lagi / jaringan putus
    try {
      const d = await SB.rpc('sc_order', { p_token: TOKEN, p_idem: S.idem, p_nama: S.name, p_items: S.cart });
      setOrder(d.order); S.screen = 'order'; S.lastProd = d.order.status_produksi; startPoll(); window.scrollTo(0, 0);
    } catch (e) { S.error = e.message; }
    S.busy = false; render();
  }

  document.addEventListener('click', async e => {
    const b = e.target.closest('[data-a]'); if (!b || b.disabled) return;
    const a = b.dataset.a;
    if (a === 'close-sheet') { if (e.target !== b) return; S.sheet = null; }
    else if (a === 'cat') { S.cat = b.dataset.c; render(); const cats = [...new Set(S.menu.map(m => m.kategori))]; const t = document.getElementById('cat-' + cats.indexOf(S.cat)); if (t) t.scrollIntoView({ behavior: 'smooth', block: 'start' }); return; }
    else if (a === 'open') { const m = S.menu.find(x => x.id === +b.dataset.id); S.sheet = { id: m.id, qty: 1, suhu: m.suhu ? m.suhu[0] : null, manis: m.manis ? 'Normal' : null, catatan: '' }; }
    else if (a === 'opt') { S.sheet[b.dataset.k] = b.dataset.v; }
    else if (a === 'sq') { S.sheet.qty = Math.max(1, Math.min(20, S.sheet.qty + +b.dataset.d)); }
    else if (a === 'add') {
      const s = S.sheet, manis = s.manis && s.manis !== 'Normal' ? s.manis : null, cat = (s.catatan || '').trim();
      const same = S.cart.find(i => i.menu_id === s.id && i.suhu === s.suhu && i.manis === manis && (i.catatan || '') === cat);
      if (same) same.qty += s.qty; else S.cart.push({ menu_id: s.id, qty: s.qty, suhu: s.suhu, manis, catatan: cat });
      S.sheet = null; S.idem = null; saveCart();
    }
    else if (a === 'go') { S.screen = b.dataset.s; S.error = null; window.scrollTo(0, 0); }
    else if (a === 'cq') { const i = S.cart[+b.dataset.i]; i.qty += +b.dataset.d; if (i.qty <= 0) S.cart.splice(+b.dataset.i, 1); S.idem = null; saveCart(); if (!S.cart.length) S.screen = 'menu'; }
    else if (a === 'checkout') { return checkout(); }
    else if (a === 'simpan-qr' && S.order && S.order.pembayaran) simpanQr(S.order.pembayaran.qr_string, S.order.nomor);
    else if (a === 'check' && S.order) { S.busy = true; render(); try { const d = await SB.rpc('sc_check', { p_id: S.order.id }); setOrder(d.order); } catch (err) { S.error = err.message; } setTimeout(() => { S.busy = false; render(); }, 800); return; }
    else if (a === 'sim' && S.order) { S.busy = true; render(); try { const d = await SB.rpc('sc_sim', { p_id: S.order.id, p_mode: b.dataset.m }); setOrder(d.order); S.error = null; if (b.dataset.m === 'fake') S.error = 'Simulasi: webhook palsu ditolak server. Status tidak berubah.'; if (b.dataset.m === 'lost') S.error = null; } catch (err) { S.error = err.message; } S.busy = false; render(); return; }
    else if (a === 'repay' && S.order) { S.busy = true; render(); try { const d = await SB.rpc('sc_repay', { p_id: S.order.id }); setOrder(d.order); S.error = null; startPoll(); } catch (err) { S.error = err.message; } S.busy = false; }
    else if (a === 'cancel' && S.order) { try { await SB.rpc('sc_cancel', { p_id: S.order.id }); } catch (err) {} store.del(KEY_ORDER); S.order = null; S.idem = null; S.screen = 'cart'; stopPoll(); }
    else if (a === 'edit') { store.del(KEY_ORDER); S.order = null; S.idem = null; S.screen = 'cart'; stopPoll(); }
    else if (a === 'notif') {
      S.notif = !S.notif; store.set(KEY_NOTIF, S.notif); unlockAudio();
      if (S.notif && 'Notification' in window && Notification.permission === 'default') { try { await Notification.requestPermission(); } catch (err) {} }
    }
    else if (a === 'again') { store.del(KEY_ORDER); S.cart = []; saveCart(); S.order = null; S.idem = null; S.screen = 'menu'; window.scrollTo(0, 0); }
    render();
  });
  document.addEventListener('keydown', e => { if (e.key === 'Escape' && S.sheet) { S.sheet = null; render(); } });
  setInterval(() => { const s = document.getElementById('sisa'); if (s) s.textContent = mmss(Math.round((+s.dataset.end - Date.now()) / 1000)); }, 1000);

  // ---------- mulai ----------
  (async function init() {
    try {
      const d = await SB.rpc('sc_menu', { p_token: TOKEN });
      S.info = d; S.menu = d.menu;
      S.cart = S.cart.filter(i => S.menu.some(m => m.id === i.menu_id));
      const saved = store.get(KEY_ORDER, null);
      if (saved) {
        try { const o = (await SB.rpc('sc_status', { p_id: saved })).order;
          if (o.status_produksi !== 'SELESAI' && o.status_bayar !== 'DIBATALKAN') { setOrder(o); S.screen = 'order'; S.lastProd = o.status_produksi; startPoll(); }
          else store.del(KEY_ORDER);
        } catch (e) { store.del(KEY_ORDER); }
      }
    } catch (e) { S.fatal = e.message; }
    render();
  })();
})();
