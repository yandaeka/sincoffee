/* Layar barista: antrean live, ubah status, dan ketersediaan menu. */
(function () {
  const { api, esc, mmss, unlock, beep } = window.STAF;
  const LBL = { MENUNGGU: 'Menunggu', DIPROSES: 'Diproses', SIAP: 'Siap' };
  const BTN = { MENUNGGU: 'Mulai proses', DIPROSES: 'Tandai siap', SIAP: 'Sudah diambil' };
  let seen = null, skew = 0, busy = false, sound = false, last = [];
  const $ = id => document.getElementById(id);

  $('sound').addEventListener('click', () => {
    unlock(); sound = true; beep(880);
    $('sound').textContent = '🔔 Suara pesanan aktif'; $('sound').disabled = true;
    try { if ('Notification' in window && Notification.permission === 'default') Notification.requestPermission(); } catch (e) {}
  });

  function pemberitahuan(teks) {
    const c = $('conn');
    c.textContent = teks; c.style.background = 'var(--ok-soft, #DCFCE7)'; c.style.color = 'var(--ok, #166534)'; c.classList.add('on');
    clearTimeout(pemberitahuan.t);
    pemberitahuan.t = setTimeout(() => { c.classList.remove('on'); c.style.background = ''; c.style.color = ''; c.textContent = ''; }, 6000);
    try {
      if (document.hidden && 'Notification' in window && Notification.permission === 'granted') {
        new Notification('Sin Coffee', { body: teks, tag: 'pesanan-baru' });
      }
    } catch (e) {}
  }

  function opt(i) { return [i.suhu, i.manis].filter(Boolean).join(', '); }
  function draw(orders, selesai, fresh) {
    const by = { MENUNGGU: [], DIPROSES: [], SIAP: [] };
    orders.forEach(o => by[o.status_produksi] && by[o.status_produksi].push(o));
    $('aktif').textContent = orders.length + ' pesanan aktif';
    $('done').textContent = 'Selesai dalam 12 jam terakhir: ' + selesai + ' pesanan';
    $('cols').innerHTML = Object.keys(by).map(k => {
      const list = by[k];
      return `<div class="col"><div class="col-h"><span>${LBL[k]}</span><span class="count">${list.length}</span></div>` +
        (list.length ? list.map(o => {
          const ref = k === 'SIAP' ? +o.t_siap : +o.t_bayar;
          const notes = o.items.filter(i => i.catatan).map(i => `<div class="inote">${esc(i.nama)}: ${esc(i.catatan)}</div>`).join('');
          return `<article class="card k-${k} ${fresh.has(o.id) ? 'new' : ''}"><div class="card-top"><span class="card-no">${esc(o.nomor_pesanan.slice(-4))}</span><span class="age" data-ref="${ref}" data-warn="${k === 'MENUNGGU' ? 600 : 0}">${mmss(Date.now() / 1000 - skew - ref)}</span></div>
            <div class="card-meta">${esc(o.nama_pelanggan || 'Tanpa nama')} · ${esc(o.kode_meja || '')}${+o.bayar_terlambat ? ' · bayar terlambat' : ''}${+o.is_contoh ? ' · contoh' : ''}</div>
            <ul>${o.items.map(i => `<li>${i.qty}× ${esc(i.nama)}${opt(i) ? ` <small>(${esc(opt(i))})</small>` : ''}</li>`).join('')}</ul>${notes}
            <button class="btn ${k === 'SIAP' ? 'btn-g' : 'btn-p'}" style="min-height:46px" data-id="${o.id}" data-from="${k}">${BTN[k]}</button></article>`;
        }).join('') : `<div class="empty">Belum ada pesanan</div>`) + `</div>`;
    }).join('');
  }

  async function load() {
    try {
      const d = await api('queue');
      skew = Date.now() / 1000 - d.now;
      const ids = new Set(d.orders.map(o => o.id));
      const fresh = new Set(seen ? d.orders.filter(o => !seen.has(o.id)).map(o => o.id) : []);
      if (fresh.size && sound) {
        beep(660);
        const baru = d.orders.filter(o => fresh.has(o.id)).map(o => o.nomor_pesanan.slice(-4));
        pemberitahuan('Pesanan baru: ' + baru.join(', '));
      }
      seen = ids; last = d.orders;
      $('conn').classList.remove('on'); $('live').className = 'chip c-ok'; $('live').textContent = '● Online';
      document.querySelectorAll('#cols button').forEach(b => b.disabled = false);
      if (!busy) draw(d.orders, d.selesai, fresh);
    } catch (e) {
      if (e.message === 'login') return;
      $('conn').classList.add('on'); $('live').className = 'chip c-err'; $('live').textContent = '● Offline';
      document.querySelectorAll('#cols button').forEach(b => b.disabled = true);
    }
  }

  $('cols').addEventListener('click', async e => {
    const b = e.target.closest('button[data-id]'); if (!b || b.disabled) return;
    unlock(); busy = true; b.disabled = true; b.textContent = 'Menyimpan…';
    try { await api('advance', { id: b.dataset.id, dari: b.dataset.from }); }
    catch (err) { if (err.message !== 'login') alertBox(err.message); }
    busy = false; load();
  });
  function alertBox(msg) { const c = $('conn'); c.textContent = msg; c.classList.add('on'); setTimeout(() => { c.classList.remove('on'); c.textContent = 'Koneksi terputus. Menampilkan antrean terakhir, mencoba menyambung ulang…'; }, 3500); }

  async function loadMenu() {
    try { const d = await api('menu_admin');
      $('menu').innerHTML = d.menu.map(m => `<label><span>${esc(m.nama)}</span><input type="checkbox" data-mid="${m.id}" ${+m.tersedia ? 'checked' : ''} aria-label="${esc(m.nama)} tersedia"></label>`).join('');
    } catch (e) {}
  }
  $('menu').addEventListener('change', async e => {
    const c = e.target.closest('input[data-mid]'); if (!c) return;
    try { await api('toggle_menu', { id: +c.dataset.mid, tersedia: c.checked }); } catch (err) { c.checked = !c.checked; }
  });

  setInterval(() => document.querySelectorAll('.age[data-ref]').forEach(n => { const s = Date.now() / 1000 - skew - +n.dataset.ref; n.textContent = mmss(s); n.classList.toggle('late', +n.dataset.warn > 0 && s > +n.dataset.warn); }), 1000);
  setInterval(load, 3000);
  load(); loadMenu();
})();
