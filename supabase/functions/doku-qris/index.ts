// Sin Coffee: buat QRIS DOKU untuk satu pesanan. Dipanggil dari halaman pelanggan.
// Harga dan nominal diambil dari database, bukan dari browser.
// Secrets: DOKU_CLIENT_ID, DOKU_SECRET_KEY, DOKU_PRIVATE_KEY, DOKU_MERCHANT_ID, DOKU_TERMINAL_ID,
//          DOKU_BASE_URL, DOKU_TOKEN_URL, DOKU_POSTAL_CODE (opsional)

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const enc = new TextEncoder();
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
const env = (k: string, wajib = true): string => {
  const v = Deno.env.get(k);
  if (!v && wajib) throw new Error('Secret ' + k + ' belum diisi di Supabase.');
  return v ?? '';
};
const b64 = (buf: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(buf)));
async function sha256Hex(s: string) {
  const h = new Uint8Array(await crypto.subtle.digest('SHA-256', enc.encode(s)));
  return [...h].map((b) => b.toString(16).padStart(2, '0')).join('');
}
async function hmacB64(secret: string, msg: string) {
  const k = await crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-512' }, false, ['sign']);
  return b64(await crypto.subtle.sign('HMAC', k, enc.encode(msg)));
}
async function rsaSignB64(pem: string, msg: string) {
  const isi = pem.replace(/\\n/g, '\n').replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
  const der = Uint8Array.from(atob(isi), (c) => c.charCodeAt(0));
  const k = await crypto.subtle.importKey('pkcs8', der, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
  return b64(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', k, enc.encode(msg)));
}
// Format waktu ISO 8601 dengan zona WIB, misalnya 2026-10-30T00:15:00+07:00
function waktuWIB(d: Date) {
  return new Date(d.getTime() + 7 * 3600 * 1000).toISOString().slice(0, 19) + '+07:00';
}

let cacheToken: { token: string; exp: number } | null = null;
async function accessToken(): Promise<string> {
  if (cacheToken && Date.now() < cacheToken.exp - 60_000) return cacheToken.token;
  const clientId = env('DOKU_CLIENT_ID');
  const ts = waktuWIB(new Date());
  const sig = await rsaSignB64(env('DOKU_PRIVATE_KEY'), clientId + '|' + ts);
  const r = await fetch(env('DOKU_TOKEN_URL'), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-TIMESTAMP': ts, 'X-CLIENT-KEY': clientId, 'X-SIGNATURE': sig },
    body: JSON.stringify({ grantType: 'client_credentials' }),
  });
  const d = await r.json().catch(() => ({}));
  if (!r.ok || !d.accessToken) throw new Error('Token DOKU gagal: ' + (d.responseMessage || r.status));
  cacheToken = { token: d.accessToken, exp: Date.now() + Number(d.expiresIn || 900) * 1000 };
  return cacheToken.token;
}

async function buatQris(ref: string, jumlah: number, kedaluwarsa: Date): Promise<string> {
  const path = '/snap-adapter/b2b/v1.0/qr/qr-mpm-generate';
  const token = await accessToken();
  const clientId = env('DOKU_CLIENT_ID');
  const body = JSON.stringify({
    partnerReferenceNo: ref,
    amount: { value: jumlah.toFixed(2), currency: 'IDR' },
    merchantId: env('DOKU_MERCHANT_ID'),
    terminalId: env('DOKU_TERMINAL_ID'),
    validityPeriod: waktuWIB(kedaluwarsa),
    additionalInfo: { postalCode: env('DOKU_POSTAL_CODE', false) || '94111', feeType: 1 },
  });
  const ts = waktuWIB(new Date());
  const extId = Date.now().toString() + Math.floor(Math.random() * 1e6).toString().padStart(6, '0');
  const sig = await hmacB64(env('DOKU_SECRET_KEY'), ['POST', path, token, await sha256Hex(body), ts].join(':'));
  const r = await fetch(env('DOKU_BASE_URL') + path, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json', Authorization: 'Bearer ' + token, 'X-TIMESTAMP': ts, 'X-SIGNATURE': sig,
      'X-PARTNER-ID': clientId, 'X-EXTERNAL-ID': extId, 'CHANNEL-ID': 'H2H',
    },
    body,
  });
  const d = await r.json().catch(() => ({}));
  if (!r.ok || !d.qrContent) throw new Error('QRIS DOKU gagal: ' + (d.responseMessage || r.status));
  return d.qrContent as string;
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

    const qr = await buatQris(row.gateway_order_id, Number(row.jumlah), new Date(row.kedaluwarsa_pada));
    await rpc('svc_simpan_qris', { p_pembayaran_id: row.pembayaran_id, p_qr: qr });
    return json({ ok: true, qr_string: qr });
  } catch (e) {
    return json({ ok: false, error: String((e as Error).message || e) }, 500);
  }
});
