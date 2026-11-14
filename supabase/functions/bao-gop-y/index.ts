// Edge Function: gửi thông báo đẩy về điện thoại admin.
// - { loai: "khoa" }  : trả khóa công khai VAPID (tự tạo cặp khóa lần đầu, cất trong bảng push_cfg)
// - { loai: "gop-y" } : trigger trong database gọi khi có góp ý mới (kèm header x-bao = push_cfg.bi_mat)
// - { loai: "thu" }   : admin bấm "Gửi thử" trong Cài đặt (kèm phiên đăng nhập), chỉ gửi tới máy của admin đó
// Triển khai với "Verify JWT" TẮT: hàm tự kiểm tra quyền như trên.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2.49.4";

const URL_SB = Deno.env.get("SUPABASE_URL")!;
const sb = createClient(URL_SB, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const tl = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

type Cfg = { bi_mat: string; vapid_pub: string | null; vapid_priv: string | null };
async function cfg(): Promise<Cfg> {
  const { data, error } = await sb.from("push_cfg").select("bi_mat, vapid_pub, vapid_priv").eq("id", 1).single();
  if (error) throw error;
  if (data.vapid_pub && data.vapid_priv) return data;
  const k = webpush.generateVAPIDKeys();
  // chỉ ghi khi còn trống, rồi đọc lại (hai lần gọi cùng lúc vẫn ra một cặp khóa)
  await sb.from("push_cfg").update({ vapid_pub: k.publicKey, vapid_priv: k.privateKey }).eq("id", 1).is("vapid_pub", null);
  const r = await sb.from("push_cfg").select("bi_mat, vapid_pub, vapid_priv").eq("id", 1).single();
  if (r.error) throw r.error;
  return r.data;
}

type Sub = { endpoint: string; p256dh: string; auth: string };
async function gui(c: Cfg, subs: Sub[], tin: Record<string, string>) {
  webpush.setVapidDetails("https://littledua.github.io/nikki-nstt/", c.vapid_pub!, c.vapid_priv!);
  let ok = 0;
  for (const s of subs) {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, JSON.stringify(tin), { TTL: 86400, urgency: "high" });
      ok++;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) await sb.from("push_subs").delete().eq("endpoint", s.endpoint); // máy đã tắt thông báo
      else console.error("gửi lỗi", code, (e as { body?: string }).body);
    }
  }
  return ok;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const b = await req.json().catch(() => ({}));
    const c = await cfg();
    if (b.loai === "khoa") return tl({ khoa: c.vapid_pub });

    if (b.loai === "gop-y") {
      if (req.headers.get("x-bao") !== c.bi_mat) return tl({ loi: "sai mã" }, 401);
      const { data: subs } = await sb.from("push_subs").select("endpoint, p256dh, auth");
      const ten = String(b.ten || "").trim() || "Ai đó";
      const nd = String(b.noi_dung || "").replace(/\s+/g, " ").trim();
      const n = await gui(c, subs || [], {
        title: "💬 Góp ý mới",
        body: ten + ": " + (nd.length > 140 ? nd.slice(0, 139) + "…" : nd),
        url: "./?mo=hop-thu#admin",
        tag: "gop-y",
      });
      return tl({ gui: n });
    }

    if (b.loai === "thu") {
      const auth = req.headers.get("Authorization") || "";
      const nguoi = createClient(URL_SB, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } } });
      const { data: u } = await nguoi.auth.getUser(auth.replace(/^Bearer\s+/i, ""));
      const { data: la } = await nguoi.rpc("is_admin");
      if (!u?.user || la !== true) return tl({ loi: "chưa đăng nhập admin" }, 401);
      const { data: subs } = await sb.from("push_subs").select("endpoint, p256dh, auth").eq("user_id", u.user.id);
      const n = await gui(c, subs || [], { title: "Nikki Diary", body: "Thông báo đã hoạt động. Có góp ý mới là máy sẽ báo như thế này.", url: "./#admin", tag: "thu" });
      return tl({ gui: n });
    }
    return tl({ loi: "không rõ yêu cầu" }, 400);
  } catch (e) {
    console.error(e);
    return tl({ loi: String((e as Error).message || e) }, 500);
  }
});
