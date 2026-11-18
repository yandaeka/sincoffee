/* Ringkasan owner */
(function () {
  const { api, esc, mmss, fmt, fmtS } = window.STAF;
  const $ = id => document.getElementById(id);
  const payChip = p => ({ LUNAS: '<span class="chip c-ok">Lunas</span>', BELUM_BAYAR: '<span class="chip c-info">Menunggu bayar</span>', GAGAL: '<span class="chip c-err">Gagal</span>', KEDALUWARSA: '<span class="chip c-mute">Kedaluwarsa</span>', DIBATALKAN: '<span class="chip c-mute">Dibatalkan</span>' })[p] || p;
  const prodChip = p => ({ MENUNGGU: '<span class="chip c-warn">Menunggu</span>', DIPROSES: '<span class="chip c-acc">Diproses</span>', SIAP: '<span class="chip c-ok">Siap</span>', SELESAI: '<span class="chip c-mute">Selesai</span>' })[p] || '<span class="hint">—</span>';
  const tagCls = { ok: 't-ok', warn: 't-warn', err: 't-err', info: '' };
  let resetArmed = false;

  function chart(rows) {
    const mx = Math.max(4, ...rows.map(r => r.n)), step = Math.ceil(mx / 4), top = step * 4;
    const W = 640, H = 210, L = 34, R = 8, T = 16, B = 28, pw = W - L - R, ph = H - T - B, bw = pw / rows.length;
    const y = v => T + ph - (v / top) * ph;
    let s = `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Jumlah pesanan lunas per jam, 12 jam terakhir">`;
    for (let v = 0; v <= top; v += step) s += `<line class="grid" x1="${L}" x2="${W - R}" y1="${y(v)}" y2="${y(v)}"/><text class="ax" x="${L - 8}" y="${y(v) + 4}" text-anchor="end">${v}</text>`;
    rows.forEach((r, i) => { const x = L + i * bw + bw * .18, w = bw * .64, cur = i === rows.length - 1;
      if (r.n > 0) s += `<rect class="bar ${cur ? 'cur' : ''}" x="${x}" y="${y(r.n)}" width="${w}" height="${y(0) - y(r.n)}" rx="3"/><text class="val" x="${x + w / 2}" y="${y(r.n) - 5}" text-anchor="middle">${r.n}</text>`;
      s += `<text class="ax" x="${x + w / 2}" y="${H - 8}" text-anchor="middle">${r.jam}</text>`; });
    return s + '</svg>';
  }

  async function load() {
    try {
      const d = await api('stats'), k = d.kpi;
      $('conn').classList.remove('on'); $('live').className = 'chip c-ok'; $('live').textContent = '● Live';
      $('kpis').innerHTML = `
        <div class="kpi"><span>Omzet lunas</span><b class="mono">${fmtS(k.omzet)}</b><small>${fmt(k.omzet)}</small></div>
        <div class="kpi"><span>Pesanan lunas</span><b class="mono">${k.lunas}</b><small>${k.menunggu_bayar} menunggu pembayaran</small></div>
        <div class="kpi"><span>Rata-rata per pesanan</span><b class="mono">${fmtS(k.rata)}</b><small>dari QR order</small></div>
        <div class="kpi"><span>Bayar sampai siap</span><b class="mono">${mmss(k.siap_detik)}</b><small>rata-rata menit:detik</small></div>
        <div class="kpi ${k.gagal ? 'alert' : ''}"><span>Gagal / kedaluwarsa</span><b class="mono">${k.gagal}</b><small>tidak masuk antrean</small></div>`;
      const q = { MENUNGGU: 0, DIPROSES: 0, SIAP: 0 }; let oldest = null;
      d.antrean.forEach(r => { q[r.s] = +r.n; if (r.s === 'MENUNGGU') oldest = +r.tertua; });
      $('queue').innerHTML = `<a class="qt q-w" href="barista.php"><b class="mono">${q.MENUNGGU}</b><span>Menunggu</span></a><a class="qt q-p" href="barista.php"><b class="mono">${q.DIPROSES}</b><span>Diproses</span></a><a class="qt q-s" href="barista.php"><b class="mono">${q.SIAP}</b><span>Siap diambil</span></a>`;
      $('oldest').innerHTML = oldest ? `Pesanan terlama menunggu <b class="mono">${mmss(d.now - oldest)}</b>` : 'Tidak ada pesanan yang menunggu.';
      $('chart').innerHTML = chart(d.per_jam);
      const mx = d.terlaris.length ? +d.terlaris[0].n : 1;
      $('top5').innerHTML = d.terlaris.length ? d.terlaris.map(t => `<div class="hb"><span>${esc(t.nama)}</span><span class="n mono">${t.n}</span><div class="track"><div class="fill" style="width:${(t.n / mx * 100).toFixed(1)}%"></div></div></div>`).join('') : '<p class="hint" style="margin:0">Belum ada pesanan lunas.</p>';
      const r = d.rekon, sel = r.sistem - r.gateway;
      $('recon').innerHTML = `<div><span>Total sistem</span><b class="mono">${fmtS(r.sistem)}</b></div><div><span>Total gateway</span><b class="mono">${fmtS(r.gateway)}</b></div><div><span>Webhook diterima</span><b class="mono">${r.webhook}</b></div><div><span>Duplikat / ditolak</span><b class="mono">${r.duplikat} / ${r.ditolak}</b></div>`;
      $('rstat').innerHTML = sel === 0 ? '<span class="chip c-ok">Cocok · selisih Rp 0</span>' : `<span class="chip c-err">Selisih ${fmt(sel)} · perlu dicek</span>`;
      $('log').innerHTML = d.log.map(l => `<li><time>${esc(l.waktu)}</time><span class="tag ${tagCls[l.tingkat] || ''}">${esc(l.tag)}</span><span class="msg">${esc(l.pesan)}${l.detail ? `<small>${esc(l.detail)}</small>` : ''}</span></li>`).join('') || '<li><span></span><span></span><span class="msg hint">Belum ada aktivitas.</span></li>';
      $('recent').innerHTML = d.terbaru.map(o => `<tr><td class="mono">${esc(o.nomor_pesanan)}${+o.is_contoh ? ' <span class="chip c-mute">contoh</span>' : ''}</td><td class="mono">${esc(o.jam)}</td><td>${esc(o.kode_meja || '')}</td><td>${esc(o.nama_pelanggan || '—')}</td><td class="r">${o.item || 0}</td><td class="r mono">${fmt(+o.total)}</td><td>${payChip(o.status_bayar)}</td><td>${prodChip(o.status_produksi)}</td></tr>`).join('') || '<tr><td colspan="8" class="hint">Belum ada pesanan. Scan QR meja untuk membuat pesanan pertama.</td></tr>';
    } catch (e) {
      if (e.message === 'login') return;
      $('conn').classList.add('on'); $('live').className = 'chip c-err'; $('live').textContent = '● Terputus';
    }
  }

  if ($('reset')) $('reset').addEventListener('click', async () => {
    const b = $('reset');
    if (!resetArmed) { resetArmed = true; b.textContent = 'Yakin? Tekan sekali lagi untuk menghapus semua pesanan'; setTimeout(() => { resetArmed = false; b.textContent = 'Reset data demo'; }, 5000); return; }
    resetArmed = false; b.disabled = true; b.textContent = 'Menghapus…';
    try { await api('reset', {}); } catch (e) {}
    b.disabled = false; b.textContent = 'Reset data demo'; load();
  });

  setInterval(load, 10000);
  load();
})();
