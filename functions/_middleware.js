/* ============================================================
   Basic認証 — アプリを配る前に、扉で止める

   Cloudflare Pages の Functions として動きます。
   index.html を渡す前にここが実行されるため、
   合言葉が合わない相手にはHTMLが1バイトも渡りません。

   合言葉はこのファイルに書きません。
   Cloudflare の管理画面で「環境変数」として設定します。
     BASIC_USER … 利用者名
     BASIC_PASS … 合言葉
   リポジトリには残らないので、公開しても漏れません。
   ============================================================ */

/* 文字列の比較にかかる時間から合言葉を推測されないよう、
   長さが違っても同じ手数で比べます */
function timingSafeEqual(a, b) {
  const enc = new TextEncoder();
  const x = enc.encode(a);
  const y = enc.encode(b);
  let diff = x.length ^ y.length;
  const len = Math.max(x.length, y.length);
  for (let i = 0; i < len; i++) {
    diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  }
  return diff === 0;
}

const DENY = (message) =>
  new Response(message, {
    status: 401,
    headers: {
      // これがブラウザに合言葉の入力画面を出させます
      "WWW-Authenticate": 'Basic realm="seisan", charset="UTF-8"',
      "Content-Type": "text/plain; charset=UTF-8",
      "Cache-Control": "no-store",
    },
  });

export async function onRequest(context) {
  const { request, next, env } = context;

  // 環境変数が未設定なら、通さない。
  // 設定し忘れたときに誰でも入れてしまう事故を防ぎます
  if (!env.BASIC_USER || !env.BASIC_PASS) {
    return new Response("設定が未完了です（BASIC_USER / BASIC_PASS 未設定）", {
      status: 503,
      headers: { "Content-Type": "text/plain; charset=UTF-8" },
    });
  }

  const header = request.headers.get("Authorization") || "";
  if (!header.startsWith("Basic ")) return DENY("認証が必要です");

  let decoded;
  try {
    decoded = atob(header.slice(6));
  } catch {
    return DENY("認証情報を読み取れませんでした");
  }

  // パスワード側に「:」が含まれても壊れないよう、最初の1つで区切ります
  const sep = decoded.indexOf(":");
  if (sep < 0) return DENY("認証情報の形式が不正です");

  const user = decoded.slice(0, sep);
  const pass = decoded.slice(sep + 1);

  // 片方だけ先に判定すると、どちらが違うのか推測されます。
  // 両方を評価してから、まとめて判断します
  const okUser = timingSafeEqual(user, env.BASIC_USER);
  const okPass = timingSafeEqual(pass, env.BASIC_PASS);
  if (!(okUser && okPass)) return DENY("利用者名または合言葉が違います");

  // ここまで来た人にだけ、アプリを渡します
  const response = await next();

  // 認証の内側なので、共有の中継サーバーに残らないようにします
  const out = new Response(response.body, response);
  out.headers.set("Cache-Control", "private, no-store");
  out.headers.set("X-Robots-Tag", "noindex, nofollow");
  return out;
}
