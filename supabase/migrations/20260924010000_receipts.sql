-- ============================================================
-- 記録にレシートの写真を1枚付けられるようにする（2026-09-24）
--
-- 守り方は記録と同じです。
-- ・表には直接触れさせず、共有キーを確かめる関数だけを公開します。
-- ・Supabase Storage（ファイル置き場）は使いません。
--   ログインを使わないこのアプリでは、置き場の権限で
--   「共有キーを知っているか」を確かめられないためです。
--
-- 写真は端末で縮めたJPEGを、文字（base64）にして保存します。
-- 記録の同期（warikan_pull）には写真そのものを載せず、
-- 「どの記録に写真があるか」だけを返します。見るときに1枚ずつ取りに行きます。
--
-- 何度流しても同じ結果になるように書いてあります。
-- ============================================================

create table if not exists public.receipts (
  household  uuid        not null references public.households(id) on delete cascade,
  entry_id   text        not null,
  data       text        not null,   -- JPEG を base64 にしたもの
  created_at timestamptz not null default now(),
  primary key (household, entry_id)
);

alter table public.receipts enable row level security;
revoke all on public.receipts from anon, authenticated;

-- ── 読み出しに「写真のある記録」の一覧を足す ────────────────
create or replace function public.warikan_pull(p_key uuid)
returns json
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_house public.households%rowtype;
  v_rows  json;
  v_rcpt  json;
begin
  -- 知らないキーでは何もしない。
  -- ここで世帯を作ってしまうと、キーを持たない相手でも
  -- 呼び出すだけで領域を消費させられるためです。
  select * into v_house from public.households where id = p_key;
  if not found then
    raise exception 'unknown key' using errcode = '28000';
  end if;

  select coalesce(pg_catalog.json_agg(e order by e.updated_at), '[]'::json)
    into v_rows
    from public.entries e
   where e.household = p_key;

  select coalesce(pg_catalog.json_agg(r.entry_id), '[]'::json)
    into v_rcpt
    from public.receipts r
   where r.household = p_key;

  return pg_catalog.json_build_object(
    'names', pg_catalog.json_build_object('A', v_house.name_a, 'B', v_house.name_b),
    'namesUpdatedAt', v_house.updated_at,
    'entries', v_rows,
    'receipts', v_rcpt
  );
end;
$$;

-- ── 写真を置く（同じ記録に置き直すと差し替え） ───────────────
create or replace function public.warikan_receipt_put(
  p_key   uuid,
  p_entry text,
  p_data  text
)
returns json
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  perform 1 from public.households where id = p_key;
  if not found then
    raise exception 'unknown key' using errcode = '28000';
  end if;

  if p_entry is null or p_entry = '' or pg_catalog.length(p_entry) > 64 then
    raise exception 'bad entry id' using errcode = '22023';
  end if;

  -- 端末で縮めた写真は 300KB ほどに収まります。
  -- それより大きいものは受け取らず、領域を一気に埋められないようにします
  if p_data is null or pg_catalog.length(p_data) > 450000 then
    raise exception 'receipt too large' using errcode = '54000';
  end if;
  if p_data !~ '^[A-Za-z0-9+/]+=*$' then
    raise exception 'bad receipt data' using errcode = '22023';
  end if;

  -- 消した記録の写真を片付けます。
  -- 記録より先に写真が届くこともあるので、記録が見当たらないだけの写真は
  -- 1日待ってから消します
  delete from public.receipts r
   where r.household = p_key
     and (exists (select 1 from public.entries e
                   where e.household = r.household and e.id = r.entry_id and e.deleted)
          or (not exists (select 1 from public.entries e
                           where e.household = r.household and e.id = r.entry_id)
              and r.created_at < pg_catalog.now() - interval '1 day'));

  select pg_catalog.count(*) into v_count
    from public.receipts
   where household = p_key and entry_id <> p_entry;
  if v_count >= 1000 then
    raise exception 'too many receipts' using errcode = '54000';
  end if;

  insert into public.receipts (household, entry_id, data)
  values (p_key, p_entry, p_data)
  on conflict (household, entry_id) do update
    set data = excluded.data, created_at = pg_catalog.now();

  return pg_catalog.json_build_object('ok', true);
end;
$$;

-- ── 写真を1枚取り出す ─────────────────────────────────────
create or replace function public.warikan_receipt_get(p_key uuid, p_entry text)
returns json
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_data text;
begin
  perform 1 from public.households where id = p_key;
  if not found then
    raise exception 'unknown key' using errcode = '28000';
  end if;

  select data into v_data
    from public.receipts
   where household = p_key and entry_id = p_entry;

  return pg_catalog.json_build_object('data', v_data);
end;
$$;

-- ── 写真を外す ────────────────────────────────────────────
create or replace function public.warikan_receipt_del(p_key uuid, p_entry text)
returns json
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform 1 from public.households where id = p_key;
  if not found then
    raise exception 'unknown key' using errcode = '28000';
  end if;

  delete from public.receipts
   where household = p_key and entry_id = p_entry;

  return pg_catalog.json_build_object('ok', true);
end;
$$;

-- ── 関数だけを公開する ──────────────────────────────────
-- 既定では PUBLIC に実行権が付くため、いったん取り消してから anon にだけ渡します
revoke execute on function public.warikan_pull(uuid)                     from public;
revoke execute on function public.warikan_receipt_put(uuid, text, text)  from public;
revoke execute on function public.warikan_receipt_get(uuid, text)        from public;
revoke execute on function public.warikan_receipt_del(uuid, text)        from public;

grant execute on function public.warikan_pull(uuid)                      to anon;
grant execute on function public.warikan_receipt_put(uuid, text, text)   to anon;
grant execute on function public.warikan_receipt_get(uuid, text)         to anon;
grant execute on function public.warikan_receipt_del(uuid, text)         to anon;
