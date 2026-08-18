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

   注意: これはアプリを見せないための層です。
   記録そのものは Supabase 側の共有キーが守っています。
   ブラウザは Supabase と直接やりとりするため、
   ここを通らない経路が別に存在します。
   ============================================================ */

/* 送られてきた合言葉と、設定された合言葉を比べます。

   そのまま1文字ずつ比べると、
   「何文字目まで合っていたか」が処理時間に出てしまいます。
   長さの違いも同じように漏れます。

   そこで両方を SHA-256 にかけてから比べます。
   ハッシュは必ず32バイトになるので、
   合言葉が何文字であっても処理は同じ手数で終わります。 */
async function digest(value) {
  const bytes = new TextEncoder().encode(value);
  const hash = await crypto.subtle.digest("SHA-256", bytes);
  return new Uint8Array(hash);
}

function equalBytes(a, b) {
  let diff = a.length ^ b.length;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

async function matches(given, expected) {
  const [g, e] = await Promise.all([digest(given), digest(expected)]);
  return equalBytes(g, e);
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
    return new Response("設定が未完了です", {
      status: 503,
      headers: { "Content-Type": "text/plain; charset=UTF-8", "Cache-Control": "no-store" },
    });
  }

  const header = request.headers.get("Authorization") || "";
  if (!header.startsWith("Basic ")) return DENY("認証が必要です");

  // base64 を「バイト列」に戻してから UTF-8 として読みます。
  // atob の結果をそのまま文字列として扱うと、
  // 日本語などASCII外の合言葉が壊れて永久に認証できなくなります
  let decoded;
  try {
    const bytes = Uint8Array.from(atob(header.slice(6)), (c) => c.charCodeAt(0));
    decoded = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    return DENY("認証情報を読み取れませんでした");
  }

  // パスワード側に「:」が含まれても壊れないよう、最初の1つで区切ります
  const sep = decoded.indexOf(":");
  if (sep < 0) return DENY("認証情報の形式が不正です");

  // 片方だけ先に判定すると、どちらが違うのか推測されます。
  // 両方を評価してから、まとめて判断します
  const [okUser, okPass] = await Promise.all([
    matches(decoded.slice(0, sep), env.BASIC_USER),
    matches(decoded.slice(sep + 1), env.BASIC_PASS),
  ]);
  if (!(okUser && okPass)) return DENY("利用者名または合言葉が違います");

  // ここまで来た人にだけ、アプリを渡します
  const response = await next();

  // 認証の内側なので、共有の中継サーバーに残らないようにします
  const out = new Response(response.body, response);
  out.headers.set("Cache-Control", "private, no-store");
  out.headers.set("X-Robots-Tag", "noindex, nofollow");
  return out;
}
