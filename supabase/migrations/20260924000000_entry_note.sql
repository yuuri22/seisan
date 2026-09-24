-- ============================================================
-- 記録にメモを付けられるようにする（2026-09-24）
--
-- 楽天の注文の中身など、記録ごとに自由に書き残すための欄です。
-- 保存処理（warikan_push）が列を1つずつ並べて書き込む作りのため、
-- 列を足すのに合わせて関数も置き換えます。
-- 読み出し（warikan_pull）は行をそのまま返すので、変更はいりません。
--
-- 何度流しても同じ結果になるように書いてあります。
-- ============================================================

alter table public.entries
  add column if not exists note text not null default '';

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
      txn_id, settled, settled_on, source, deleted, updated_at, note
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
      least(coalesce(x.updated_at, v_now), v_limit),
      pg_catalog.left(coalesce(x.note, ''), 1000)
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
          updated_at      = excluded.updated_at,
          note            = excluded.note
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

-- 置き換えても権限は引き継がれますが、念のため初回と同じ形に揃えます
revoke execute on function public.warikan_push(uuid, json, text, text, timestamptz) from public;
grant  execute on function public.warikan_push(uuid, json, text, text, timestamptz) to anon;
