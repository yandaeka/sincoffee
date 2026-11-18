// Sin Coffee: buat QRIS Midtrans (Core API) untuk satu pesanan. Dipanggil dari halaman pelanggan.
// Nominal dan ID tagihan diambil dari database, bukan dari browser.
// Secrets: MIDTRANS_SERVER_KEY, MIDTRANS_BASE_URL
//   (sandbox: https://api.sandbox.midtrans.com, produksi: https://api.midtrans.com)
// Di Supabase, biarkan "Verify JWT" aktif (default) atau sesuai pengaturan halaman pelanggan.

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
const env = (k: string, wajib = true): string => {
  const v = Deno.env.get(k);
  if (!v && wajib) throw new Error('Secret ' + k + ' belum diisi di Supabase.');
  return v ?? '';
};

// Buat QRIS di Midtrans. Mengembalikan string QR (qr_string) dari respons Midtrans.
async function buatQris(ref: string, jumlah: number): Promise<string> {
  const auth = 'Basic ' + btoa(env('MIDTRANS_SERVER_KEY') + ':');
  const r = await fetch(env('MIDTRANS_BASE_URL') + '/v2/charge', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Accept: 'application/json', Authorization: auth },
    body: JSON.stringify({
      payment_type: 'qris',
      transaction_details: { order_id: ref, gross_amount: Math.round(jumlah) },
      qris: { acquirer: 'gopay' },
    }),
  });
  const d = await r.json().catch(() => ({}));
  if (!r.ok || !d.qr_string) {
    throw new Error('QRIS Midtrans gagal: ' + (d.status_message || d.error_message || r.status));
  }
  return d.qr_string as string;
}

const SRK = env('SUPABASE_SERVICE_ROLE_KEY');
async function rpc(fn: string, args: Record<string, unknown>) {
  const r = await fetch(`${env('SUPABASE_URL')}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', apikey: SRK, Authorization: 'Bearer ' + SRK },
    body: JSON.stringify(args),
  });
  return r.json();
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  try {
    const { pesanan_id } = await req.json().catch(() => ({}));
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(pesanan_id || '')) {
      return json({ ok: false, error: 'ID pesanan tidak valid.' }, 400);
    }
    const row = await rpc('svc_pembayaran_qris', { p_pesanan: pesanan_id });
    if (!row.ok) return json(row, 404);
    if (row.qr_string) return json({ ok: true, qr_string: row.qr_string });
    if (row.status !== 'PENDING') return json({ ok: false, error: 'Tagihan ini sudah tidak aktif.' }, 409);

    const qr = await buatQris(row.gateway_order_id, Number(row.jumlah));
    await rpc('svc_simpan_qris', { p_pembayaran_id: row.pembayaran_id, p_qr: qr });
    return json({ ok: true, qr_string: qr });
  } catch (e) {
    return json({ ok: false, error: String((e as Error).message || e) }, 500);
  }
});
