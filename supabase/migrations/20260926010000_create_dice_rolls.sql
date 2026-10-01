create extension if not exists pgcrypto with schema extensions;

create table public.dice_rolls (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms (id) on delete cascade,
  roller_id uuid not null references auth.users (id) on delete cascade,
  expression text not null,
  individual_results jsonb not null,
  total bigint not null,
  created_at timestamptz not null default now()
);

alter table public.dice_rolls enable row level security;

create policy dice_rolls_select_active_members
on public.dice_rolls
for select
to authenticated
using ((select public.is_active_room_member(room_id)));

revoke all on table public.dice_rolls from anon, authenticated;
grant select on table public.dice_rolls to authenticated;

create function public.dice_value_from_uint32(raw_value bigint, side_count bigint)
returns bigint
language sql
immutable
strict
set search_path = ''
as $$
  select case
    when raw_value < 0 or raw_value >= 4294967296
      or side_count < 1 or side_count > 4294967296 then null
    when raw_value >= 4294967296 - (4294967296 % side_count) then null
    else raw_value % side_count + 1
  end;
$$;

revoke all on function public.dice_value_from_uint32(bigint, bigint) from public;
revoke all on function public.dice_value_from_uint32(bigint, bigint) from anon, authenticated;

create function public.roll_dice(target_room_id uuid, dice_expression text)
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

  if not exists (
    select 1
    from public.room_members
    where room_id = target_room_id
      and user_id = caller_id
      and role in ('master', 'player')
      and status = 'active'
  ) then
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
    total
  ) values (
    target_room_id,
    caller_id,
    normalized_expression,
    pg_catalog.to_jsonb(rolled_values),
    rolled_total + modifier
  )
  returning * into created_roll;

  return created_roll;
end;
$$;

revoke all on function public.roll_dice(uuid, text) from public;
revoke all on function public.roll_dice(uuid, text) from anon;
grant execute on function public.roll_dice(uuid, text) to authenticated;
