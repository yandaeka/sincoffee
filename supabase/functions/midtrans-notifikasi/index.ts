// Sin Coffee: menerima notifikasi pembayaran dari Midtrans, memverifikasi signature_key,
// lalu meneruskannya ke database. Pesanan jadi lunas hanya jika notifikasi valid.
// Atur Payment Notification URL di Midtrans ke:
//   https://hoywfuuldbqinbbtwsgj.supabase.co/functions/v1/midtrans-notifikasi
// Di Supabase, matikan "Verify JWT" untuk fungsi ini (Midtrans tidak mengirim token Supabase).

const enc = new TextEncoder();
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { 'Content-Type': 'application/json' } });
const env = (k: string) => {
  const v = Deno.env.get(k);
  if (!v) throw new Error('Secret ' + k + ' belum diisi.');
  return v;
};
async function sha512Hex(s: string) {
  const h = new Uint8Array(await crypto.subtle.digest('SHA-512', enc.encode(s)));
  return [...h].map((b) => b.toString(16).padStart(2, '0')).join('');
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

// Midtrans transaction_status -> status yang dipakai database
function petakan(d: { transaction_status?: string; fraud_status?: string }): string | null {
  switch (d.transaction_status) {
    case 'settlement': return 'settlement';
    case 'capture': return d.fraud_status === 'accept' ? 'settlement' : null;
    case 'deny':
    case 'cancel': return 'deny';
    case 'expire': return 'expire';
    case 'failure': return 'failure';
    default: return null; // pending dan lainnya: tidak mengubah pesanan
  }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ ok: false }, 405);
  try {
    const raw = await req.text();
    const d = JSON.parse(raw);

    // Verifikasi: sha512(order_id + status_code + gross_amount + server_key) harus sama dengan signature_key
    const harapan = await sha512Hex(String(d.order_id) + String(d.status_code) + String(d.gross_amount) + env('MIDTRANS_SERVER_KEY'));
    if (!d.signature_key || !samaAman(String(d.signature_key), harapan)) {
      return json({ ok: false, error: 'Signature tidak valid.' }, 403);
    }

    const status = petakan(d);
    if (!status) return json({ ok: true, diabaikan: d.transaction_status }, 200);

    const hasil = await rpc('svc_notifikasi_midtrans', {
      p_raw: JSON.stringify({
        event_id: String(d.transaction_id || d.order_id) + ':' + d.transaction_status,
        gateway_order_id: d.order_id,
        status,
        amount: Math.round(Number(d.gross_amount || 0)),
      }),
    });
    return json({ ok: true, hasil }, 200);
  } catch (e) {
    return json({ ok: false, error: String((e as Error).message || e) }, 500);
  }
});
