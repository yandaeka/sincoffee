/* Halaman Pengaturan owner: menu dan pengguna */
(function () {
  var esc = STAF.esc;
  var fmt = function (n) { return 'Rp ' + Math.round(+n || 0).toLocaleString('id-ID'); };
  var conn = document.getElementById('conn');
  var msg = document.getElementById('msg');
  var meId = null;

  function pesan(teks, jenis) {
    msg.hidden = false;
    msg.className = 'banner ' + (jenis === 'err' ? 'b-err' : 'b-ok');
    msg.textContent = teks;
    clearTimeout(pesan.t);
    pesan.t = setTimeout(function () { msg.hidden = true; }, 4000);
  }
  function gagal(e) {
    if (e && e.message === 'login') return;
    pesan(e && e.message ? e.message : 'Terjadi kesalahan.', 'err');
  }
  function validPin(p) { return /^[0-9]{4,6}$/.test(p || ''); }

  // ---------- MENU ----------
  async function muatMenu() {
    var d = await STAF.api('menu_semua');
    var kategori = {};
    d.menu.forEach(function (m) { kategori[m.kategori] = 1; });
    document.getElementById('daftar-kategori').innerHTML = Object.keys(kategori).map(function (k) { return '<option value="' + esc(k) + '">'; }).join('');
    document.getElementById('jml-menu').textContent = d.menu.filter(function (m) { return m.aktif; }).length + ' aktif';
    document.getElementById('tbody-menu').innerHTML = d.menu.length ? d.menu.map(function (m) {
      return '<tr' + (m.aktif ? '' : ' style="opacity:.55"') + '>' +
        '<td>' + esc(m.kategori) + '</td>' +
        '<td>' + esc(m.nama) + '</td>' +
        '<td class="r"><input type="number" min="0" step="500" inputmode="numeric" value="' + Math.round(+m.harga || 0) + '" data-harga="' + m.id + '" style="width:110px;padding:6px 8px;border-radius:8px;border:1px solid var(--line);background:var(--surface);color:var(--ink)"> ' +
          '<button class="small-btn" type="button" data-simpan-harga="' + m.id + '">Simpan</button></td>' +
        '<td>' + (m.aktif ? '<span class="chip c-ok">Aktif</span>' : '<span class="chip c-mute">Nonaktif</span>') + '</td>' +
        '<td><button class="small-btn" type="button" data-aktif="' + m.id + '" data-nilai="' + (m.aktif ? '0' : '1') + '">' + (m.aktif ? 'Nonaktifkan' : 'Aktifkan') + '</button></td>' +
        '</tr>';
    }).join('') : '<tr><td colspan="5" class="hint">Belum ada menu.</td></tr>';
  }

  document.getElementById('tbody-menu').addEventListener('click', async function (ev) {
    var b = ev.target.closest('button'); if (!b) return;
    try {
      if (b.dataset.simpanHarga) {
        var inp = document.querySelector('[data-harga="' + b.dataset.simpanHarga + '"]');
        var harga = Math.round(+inp.value);
        if (!(harga >= 0)) throw new Error('Harga tidak valid.');
        await STAF.api('menu_harga', { id: b.dataset.simpanHarga, harga: harga });
        pesan('Harga disimpan.');
      } else if (b.dataset.aktif) {
        await STAF.api('menu_aktif', { id: b.dataset.aktif, aktif: b.dataset.nilai === '1' });
        pesan(b.dataset.nilai === '1' ? 'Menu diaktifkan.' : 'Menu dinonaktifkan.');
      }
      await muatMenu();
    } catch (e) { gagal(e); }
  });

  document.getElementById('form-menu').addEventListener('submit', async function (ev) {
    ev.preventDefault();
    var f = ev.target, v = Object.fromEntries(new FormData(f));
    try {
      var harga = Math.round(+v.harga);
      if (!(harga >= 0)) throw new Error('Harga tidak valid.');
      await STAF.api('menu_tambah', { kategori: v.kategori.trim(), nama: v.nama.trim(), deskripsi: (v.deskripsi || '').trim(), suhu: v.suhu, manis: !!f.manis.checked, harga: harga });
      f.reset(); f.manis.checked = true;
      pesan('Menu baru ditambahkan.');
      await muatMenu();
    } catch (e) { gagal(e); }
  });

  // ---------- PENGGUNA ----------
  async function muatPengguna() {
    var d = await STAF.api('pengguna');
    meId = d.id_saya;
    var peran = { owner: 'Owner', barista: 'Barista', admin: 'Admin' };
    document.getElementById('tbody-pengguna').innerHTML = d.pengguna.map(function (p) {
      var saya = p.id === meId;
      return '<tr' + (p.aktif ? '' : ' style="opacity:.55"') + '>' +
        '<td>' + esc(p.nama) + (saya ? ' <small class="hint">(akun Anda)</small>' : '') + '</td>' +
        '<td>' + esc(peran[p.peran] || p.peran) + '</td>' +
        '<td>' + (p.aktif ? '<span class="chip c-ok">Aktif</span>' : '<span class="chip c-mute">Nonaktif</span>') + '</td>' +
        '<td><input type="password" inputmode="numeric" maxlength="6" placeholder="PIN baru" data-pin-baru="' + p.id + '" style="width:110px;padding:6px 8px;border-radius:8px;border:1px solid var(--line);background:var(--surface);color:var(--ink)"> ' +
          '<button class="small-btn" type="button" data-ganti-pin="' + p.id + '">Ganti</button></td>' +
        '<td>' + (saya ? '' : '<button class="small-btn" type="button" data-pengguna-aktif="' + p.id + '" data-nilai="' + (p.aktif ? '0' : '1') + '">' + (p.aktif ? 'Nonaktifkan' : 'Aktifkan') + '</button>') + '</td>' +
        '</tr>';
    }).join('');
  }

  document.getElementById('tbody-pengguna').addEventListener('click', async function (ev) {
    var b = ev.target.closest('button'); if (!b) return;
    try {
      if (b.dataset.gantiPin) {
        var pin = document.querySelector('[data-pin-baru="' + b.dataset.gantiPin + '"]').value.trim();
        if (!validPin(pin)) throw new Error('PIN harus 4 sampai 6 angka.');
        await STAF.api('pengguna_pin', { id: b.dataset.gantiPin, pin: pin });
        pesan('PIN diganti.');
      } else if (b.dataset.penggunaAktif) {
        await STAF.api('pengguna_aktif', { id: b.dataset.penggunaAktif, aktif: b.dataset.nilai === '1' });
        pesan(b.dataset.nilai === '1' ? 'Akun diaktifkan.' : 'Akun dinonaktifkan.');
      }
      await muatPengguna();
    } catch (e) { gagal(e); }
  });

  document.getElementById('form-pengguna').addEventListener('submit', async function (ev) {
    ev.preventDefault();
    var f = ev.target, v = Object.fromEntries(new FormData(f));
    try {
      if (!validPin(v.pin)) throw new Error('PIN harus 4 sampai 6 angka.');
      await STAF.api('pengguna_tambah', { nama: v.nama.trim(), peran: v.peran, pin: v.pin.trim() });
      f.reset();
      pesan('Pengguna baru ditambahkan.');
      await muatPengguna();
    } catch (e) { gagal(e); }
  });

  // ---------- MULAI ----------
  (async function () {
    var u = await STAF.ready;
    if (!u) return;
    if (u.peran !== 'owner') { location.href = 'barista.html'; return; }
    try {
      await Promise.all([muatMenu(), muatPengguna()]);
    } catch (e) { if (e.message !== 'login') { conn.textContent = e.message; conn.style.display = 'block'; } }
  })();
})();
