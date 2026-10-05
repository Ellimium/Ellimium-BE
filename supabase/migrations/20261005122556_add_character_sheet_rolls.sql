alter table public.dice_rolls
add column character_sheet_id uuid references public.character_sheets(id) on delete set null,
add column sheet_roll jsonb check (sheet_roll is null or jsonb_typeof(sheet_roll) = 'object');

create index dice_rolls_character_sheet_id_idx
on public.dice_rolls(character_sheet_id)
where character_sheet_id is not null;

comment on column public.dice_rolls.sheet_roll is
'Immutable roll-time system, character name, item kind/key, value and applied modifier. Protected by dice_rolls RLS; never copied to notifications.';

-- Only the validated public RPCs can supply sheet metadata to this helper.
create function private.insert_dice_roll(
  target_room_id uuid,
  dice_expression text,
  target_character_sheet_id uuid,
  sheet_roll_context jsonb
)
returns public.dice_rolls
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_id uuid := (select auth.uid());
  normalized_expression text;
  expression_parts text[];
  dice_count_number numeric;
  side_count_number numeric;
  keep_count_number numeric;
  modifier_number numeric;
  dice_count integer;
  side_count bigint;
  keep_mode text;
  keep_count integer;
  modifier bigint;
  random_bytes bytea;
  raw_value bigint;
  die_value bigint;
  rolled_values bigint[] := array[]::bigint[];
  rolled_total bigint;
  created_roll public.dice_rolls;
begin
  if caller_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if not (select public.can_use_room_feature(target_room_id, 'dice')) then
    raise exception 'dice roll permission required' using errcode = '42501';
  end if;

  if dice_expression is null
    or char_length(btrim(dice_expression)) not between 1 and 100 then
    raise exception 'invalid dice expression' using errcode = '22023';
  end if;

  normalized_expression := btrim(dice_expression);
  expression_parts := regexp_match(
    normalized_expression,
    '^(?:/roll[[:space:]]+)?([0-9]+)[dD]([0-9]+)(?:[kK]([hHlL])([0-9]+))?([+-][0-9]+)?$'
  );

  if expression_parts is null then
    raise exception 'invalid dice expression' using errcode = '22023';
  end if;

  dice_count_number := expression_parts[1]::numeric;
  side_count_number := expression_parts[2]::numeric;
  keep_count_number := coalesce(expression_parts[4], expression_parts[1])::numeric;
  modifier_number := coalesce(expression_parts[5], '0')::numeric;

  if dice_count_number not between 1 and 100 then
    raise exception 'dice count must be between 1 and 100' using errcode = '22023';
  end if;

  if side_count_number not between 1 and 4294967296 then
    raise exception 'dice sides must be between 1 and 4294967296' using errcode = '22023';
  end if;

  if keep_count_number not between 1 and dice_count_number then
    raise exception 'keep count must be between 1 and dice count' using errcode = '22023';
  end if;

  if modifier_number not between -9223372036854775808 and 9223372036854775807 then
    raise exception 'dice modifier is outside the supported range' using errcode = '22023';
  end if;

  if keep_count_number + modifier_number < -9223372036854775808
    or keep_count_number * side_count_number + modifier_number > 9223372036854775807 then
    raise exception 'dice total is outside the supported range' using errcode = '22023';
  end if;

  dice_count := dice_count_number::integer;
  side_count := side_count_number::bigint;
  keep_mode := lower(expression_parts[3]);
  keep_count := keep_count_number::integer;
  modifier := modifier_number::bigint;

  for roll_index in 1..dice_count loop
    loop
      random_bytes := extensions.gen_random_bytes(4);
      raw_value := pg_catalog.get_byte(random_bytes, 0)::bigint * 16777216
        + pg_catalog.get_byte(random_bytes, 1)::bigint * 65536
        + pg_catalog.get_byte(random_bytes, 2)::bigint * 256
        + pg_catalog.get_byte(random_bytes, 3)::bigint;
      die_value := public.dice_value_from_uint32(raw_value, side_count);
      exit when die_value is not null;
    end loop;

    rolled_values := pg_catalog.array_append(rolled_values, die_value);
  end loop;

  if keep_mode = 'h' then
    select pg_catalog.sum(kept.value)::bigint
    into rolled_total
    from (
      select rolled.value
      from pg_catalog.unnest(rolled_values) as rolled(value)
      order by rolled.value desc
      limit keep_count
    ) as kept;
  elsif keep_mode = 'l' then
    select pg_catalog.sum(kept.value)::bigint
    into rolled_total
    from (
      select rolled.value
      from pg_catalog.unnest(rolled_values) as rolled(value)
      order by rolled.value
      limit keep_count
    ) as kept;
  else
    select pg_catalog.sum(rolled.value)::bigint
    into rolled_total
    from pg_catalog.unnest(rolled_values) as rolled(value);
  end if;

  insert into public.dice_rolls (
    room_id,
    roller_id,
    expression,
    individual_results,
    total,
    character_sheet_id,
    sheet_roll
  ) values (
    target_room_id,
    caller_id,
    normalized_expression,
    pg_catalog.to_jsonb(rolled_values),
    rolled_total + modifier,
    target_character_sheet_id,
    sheet_roll_context
  )
  returning * into created_roll;

  return created_roll;
end;
$$;

revoke all on function private.insert_dice_roll(uuid, text, uuid, jsonb)
from public, anon, authenticated;

-- Keep both existing roll_dice signatures and visibility handling compatible.
create or replace function public.roll_dice(target_room_id uuid, dice_expression text)
returns public.dice_rolls
language sql
security definer
set search_path = ''
as $$
  select private.insert_dice_roll(target_room_id, dice_expression, null, null);
$$;

create function public.roll_character_sheet(
  target_room_id uuid,
  target_character_sheet_id uuid,
  sheet_item_kind text,
  sheet_item_key text,
  roll_visibility text default 'public'
)
returns public.dice_rolls
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_id uuid := (select auth.uid());
  sheet public.character_sheets;
  item_value jsonb;
  score numeric;
  modifier numeric;
  expression text;
  snapshot jsonb;
  created_roll public.dice_rolls;
  previous_visibility text := pg_catalog.current_setting('app.dice_roll_visibility', true);
begin
  if caller_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if not (select public.can_use_room_feature(target_room_id, 'dice')) then
    raise exception 'dice roll permission required' using errcode = '42501';
  end if;

  -- Match sheet ownership/role restrictions without exposing the sheet to peers.
  -- Hold the row against editing/deletion until its roll-time snapshot is stored.
  select s.* into sheet
  from public.character_sheets as s
  where s.id = target_character_sheet_id
    and s.room_id = target_room_id
    and (
      (select public.is_room_master(target_room_id))
      or (s.owner_id = caller_id and exists (
        select 1 from public.room_members
        where room_id = target_room_id and user_id = caller_id
          and role = 'player' and status = 'active'
      ))
    )
  for share;

  if not found then
    raise exception 'character sheet roll permission required' using errcode = '42501';
  end if;

  if roll_visibility is null or roll_visibility not in ('public', 'private') then
    raise exception 'invalid dice visibility' using errcode = '22023';
  end if;

  if sheet.system = 'dnd_5e' and sheet_item_kind = 'attribute'
    and sheet_item_key in ('STR', 'DEX', 'CON', 'INT', 'WIS', 'CHA') then
    item_value := sheet.attributes -> sheet_item_key;
  elsif sheet.system = 'coc_7e' and sheet_item_kind = 'skill' then
    item_value := sheet.skills -> sheet_item_key;
  else
    raise exception 'unsupported sheet roll item' using errcode = '22023';
  end if;

  if item_value is null or pg_catalog.jsonb_typeof(item_value) <> 'number' then
    raise exception 'sheet roll item must be numeric' using errcode = '22023';
  end if;
  score := (item_value #>> '{}')::numeric;
  if score <> pg_catalog.trunc(score) or score < 0
    or (sheet.system = 'dnd_5e' and score < 1) then
    raise exception 'invalid sheet roll item value' using errcode = '22023';
  end if;

  if sheet.system = 'dnd_5e' then
    modifier := pg_catalog.floor((score - 10) / 2);
    expression := '1d20' || case when modifier >= 0 then '+' else '' end || modifier::text;
  else
    expression := '1d100';
  end if;

  snapshot := pg_catalog.jsonb_build_object(
    'system', sheet.system,
    'character_name', sheet.name,
    'item_kind', sheet_item_kind,
    'item_key', sheet_item_key,
    'value', score,
    'modifier', modifier
  );

  perform pg_catalog.set_config('app.dice_roll_visibility', roll_visibility, true);
  select * into created_roll
  from private.insert_dice_roll(target_room_id, expression, sheet.id, snapshot);
  perform pg_catalog.set_config('app.dice_roll_visibility', coalesce(previous_visibility, ''), true);
  return created_roll;
end;
$$;

revoke all on function public.roll_character_sheet(uuid, uuid, text, text, text)
from public, anon;
grant execute on function public.roll_character_sheet(uuid, uuid, text, text, text)
to authenticated;
