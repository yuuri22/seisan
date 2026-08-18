-- ============================================================
-- 割り勘アプリ ふたりで同期するための設定
--
-- Supabase の SQL Editor に、このファイルの中身をすべて貼って
-- 実行してください。一度だけで済みます。
--
-- 守り方:
--   1. テーブルには誰も直接アクセスできません。
--      （RLSを有効にし、ポリシーを一切作らないため）
--   2. 読み書きは下の2つの関数からのみ。関数は共有キーの一致を求めます。
--      共有キーはUUID（122ビットの乱数）で、総当たりは不可能です。
--   3. 知らないキーでは何も作られません。
--      キーを持たない相手は、書き込みも領域の消費もできません。
-- ============================================================

-- ── 世帯（ふたりの組）────────────────────────────────────
create table if not exists public.households (
  id          uuid primary key,
  name_a      text        not null default 'Aさん',
  name_b      text        not null default 'Bさん',
  updated_at  timestamptz not null default now(),
  created_at  timestamptz not null default now()
);

-- ── 記録 ────────────────────────────────────────────────
-- 主キーを (household, id) にしています。
-- idだけを主キーにすると、別の世帯が同じidを先に使ったときに
-- 自分の記録が保存できなくなるためです。
create table if not exists public.entries (
  household       uuid        not null references public.households(id) on delete cascade,
  id              text        not null,
  date            text        not null,
  title           text        not null default '',
  amount          integer     not null default 0,
  payer           text        not null default 'A',
  method          text        not null default '',
  a_personal      integer     not null default 0,
  a_personal_note text        not null default '',
  b_personal      integer     not null default 0,
  b_personal_note text        not null default '',
  txn_id          text        not null default '',
  settled         boolean     not null default false,
  settled_on      text        not null default '',
  source          text        not null default 'manual',
  deleted         boolean     not null default false,  -- 削除は消さずに印を付ける
  updated_at      timestamptz not null default now(),
  primary key (household, id)
);

create index if not exists entries_household_idx
  on public.entries (household, updated_at);

-- ── 直接アクセスを塞ぐ ──────────────────────────────────
alter table public.households enable row level security;
alter table public.entries    enable row level security;

revoke all on public.households from anon, authenticated;
revoke all on public.entries    from anon, authenticated;

-- ============================================================
-- 取り出す
-- ============================================================
create or replace function public.warikan_pull(p_key uuid)
returns json
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_house public.households%rowtype;
  v_rows  json;
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

  return pg_catalog.json_build_object(
    'names', pg_catalog.json_build_object('A', v_house.name_a, 'B', v_house.name_b),
    'namesUpdatedAt', v_house.updated_at,
    'entries', v_rows
  );
end;
$$;

-- ============================================================
-- 送り込む（あとから直したほうを残す）
-- ============================================================
create or replace function public.warikan_push(
  p_key             uuid,
  p_entries         json,
  p_name_a          text        default null,
  p_name_b          text        default null,
  p_names_updated   timestamptz default null
)
returns json
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_house  public.households%rowtype;
  v_count  integer;
  v_total  integer;
  v_now    timestamptz := pg_catalog.now();
  v_limit  timestamptz := pg_catalog.now() + interval '1 day';
begin
  select * into v_house from public.households where id = p_key;
  if not found then
    raise exception 'unknown key' using errcode = '28000';
  end if;

  -- 一度に送れる件数を制限する（領域を一気に埋められないように）
  select pg_catalog.count(*) into v_count
    from pg_catalog.json_array_elements(coalesce(p_entries, '[]'::json));
  if v_count > 3000 then
    raise exception 'too many entries in one request' using errcode = '54000';
  end if;

  -- 表示名。あとから変えたほうを採用する
  if p_name_a is not null
     and p_names_updated is not null
     and p_names_updated > v_house.updated_at then
    update public.households
       set name_a = p_name_a,
           name_b = coalesce(p_name_b, name_b),
           -- 遠い未来の時刻を送られると以後変更できなくなるため、上限をかける
           updated_at = least(p_names_updated, v_limit)
     where id = p_key;
  end if;

  if p_entries is not null then
    insert into public.entries as t (
      household, id, date, title, amount, payer, method,
      a_personal, a_personal_note, b_personal, b_personal_note,
      txn_id, settled, settled_on, source, deleted, updated_at
    )
    select
      p_key,
      pg_catalog.left(x.id, 64),
      pg_catalog.left(x.date, 10),
      pg_catalog.left(coalesce(x.title, ''), 200),
      coalesce(x.amount, 0),
      case when x.payer = 'B' then 'B' else 'A' end,
      pg_catalog.left(coalesce(x.method, ''), 20),
      coalesce(x.a_personal, 0), pg_catalog.left(coalesce(x.a_personal_note, ''), 200),
      coalesce(x.b_personal, 0), pg_catalog.left(coalesce(x.b_personal_note, ''), 200),
      pg_catalog.left(coalesce(x.txn_id, ''), 100),
      coalesce(x.settled, false), pg_catalog.left(coalesce(x.settled_on, ''), 10),
      pg_catalog.left(coalesce(x.source, 'manual'), 20),
      coalesce(x.deleted, false),
      least(coalesce(x.updated_at, v_now), v_limit)
    from pg_catalog.json_populate_recordset(null::public.entries, p_entries) x
    where x.id is not null
      and x.id <> ''
      and x.date is not null
    on conflict (household, id) do update
      set date            = excluded.date,
          title           = excluded.title,
          amount          = excluded.amount,
          payer           = excluded.payer,
          method          = excluded.method,
          a_personal      = excluded.a_personal,
          a_personal_note = excluded.a_personal_note,
          b_personal      = excluded.b_personal,
          b_personal_note = excluded.b_personal_note,
          txn_id          = excluded.txn_id,
          settled         = excluded.settled,
          settled_on      = excluded.settled_on,
          source          = excluded.source,
          deleted         = excluded.deleted,
          updated_at      = excluded.updated_at
      where excluded.updated_at > t.updated_at;
  end if;

  -- 1つの世帯が持てる件数にも上限を設ける
  select pg_catalog.count(*) into v_total from public.entries where household = p_key;
  if v_total > 50000 then
    raise exception 'this household has too many records' using errcode = '54000';
  end if;

  -- 消した印だけが残り続けないよう、古いものは片付ける
  delete from public.entries
   where household = p_key
     and deleted
     and updated_at < v_now - interval '90 days';

  return public.warikan_pull(p_key);
end;
$$;

-- ── 関数だけを公開する ──────────────────────────────────
-- 既定では PUBLIC に実行権が付くため、いったん取り消してから anon にだけ渡します
revoke execute on function public.warikan_pull(uuid) from public;
revoke execute on function public.warikan_push(uuid, json, text, text, timestamptz) from public;

grant execute on function public.warikan_pull(uuid)                                to anon;
grant execute on function public.warikan_push(uuid, json, text, text, timestamptz) to anon;

-- ============================================================
-- 共有キーを発行する
--
-- ここで世帯そのものを作ります。
-- あらかじめ作られたキーでなければ同期できないので、
-- キーを知らない相手は書き込むことも領域を使うこともできません。
-- ============================================================
-- セットアップのときに、__HOUSEHOLD_UUID__ を実際のUUIDに置き換えます。
-- （マイグレーションでは戻り値を受け取れないため、あらかじめ決めた値を入れます）
insert into public.households (id) values ('__HOUSEHOLD_UUID__')
on conflict (id) do nothing;
