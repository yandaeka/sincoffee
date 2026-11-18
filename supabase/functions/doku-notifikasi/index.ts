// Sin Coffee: menerima notifikasi pembayaran dari DOKU, memverifikasi tanda tangan,
// lalu meneruskannya ke database. Pesanan berubah jadi lunas hanya jika notifikasi valid.
// Atur Notification URL di DOKU ke: https://<project>.supabase.co/functions/v1/doku-notifikasi
// Di Supabase, matikan "Verify JWT" untuk fungsi ini (DOKU tidak mengirim token Supabase).

const enc = new TextEncoder();
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { 'Content-Type': 'application/json' } });
const env = (k: string) => {
  const v = Deno.env.get(k);
  if (!v) throw new Error('Secret ' + k + ' belum diisi.');
  return v;
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
// Bandingkan dua string dengan waktu konstan
function samaAman(a: string, b: string) {
  if (a.length !== b.length) return false;
  let beda = 0;
  for (let i = 0; i < a.length; i++) beda |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return beda === 0;
}

const SRK = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
async function rpc(fn: string, args: Record<string, unknown>) {
  const r = await fetch(`${Deno.env.get('SUPABASE_URL')}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', apikey: SRK, Authorization: 'Bearer ' + SRK },
    body: JSON.stringify(args),
  });
  return r.json();
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ responseCode: '4055600', responseMessage: 'Method not allowed' }, 405);
  try {
    const raw = await req.text();
    const ts = req.headers.get('X-TIMESTAMP') || '';
    const sig = req.headers.get('X-SIGNATURE') || '';
    const extId = req.headers.get('X-EXTERNAL-ID') || '';
    const token = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
    const relatif = new URL(req.url).pathname;

    const harapan = await hmacB64(env('DOKU_SECRET_KEY'), ['POST', relatif, token, await sha256Hex(raw), ts].join(':'));
    if (!sig || !samaAman(sig, harapan)) {
      return json({ responseCode: '4015600', responseMessage: 'Unauthorized. Signature' }, 401);
    }

    const d = JSON.parse(raw);
    const kode = d.latestTransactionStatus;
    if (kode === '03') return json({ responseCode: '2005600', responseMessage: 'Successful' }); // masih pending
    const status = kode === '00' ? 'settlement' : kode === '06' ? 'failure' : 'deny';

    const hasil = await rpc('svc_notifikasi_doku', {
      p_raw: JSON.stringify({
        event_id: extId || d.originalExternalId,
        gateway_order_id: d.originalPartnerReferenceNo,
        status,
        amount: Math.round(Number(d.amount?.value || 0)),
      }),
    });
    return json({ responseCode: '2005600', responseMessage: 'Successful', hasil });
  } catch (e) {
    return json({ responseCode: '5005600', responseMessage: String((e as Error).message || e) }, 500);
  }
});
