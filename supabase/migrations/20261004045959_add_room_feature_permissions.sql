create table public.room_feature_permissions (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms (id) on delete cascade,
  feature text not null check (
    feature in ('chat', 'map_view', 'dice', 'token_move', 'drawing')
  ),
  role text check (role in ('player', 'spectator')),
  user_id uuid,
  allowed boolean not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint room_feature_permissions_scope check (
    (role is not null and user_id is null)
    or (role is null and user_id is not null)
  ),
  constraint room_feature_permissions_member_fk
    foreign key (room_id, user_id)
    references public.room_members (room_id, user_id)
    on delete cascade,
  unique nulls not distinct (room_id, feature, role, user_id)
);

create index room_feature_permissions_member_idx
on public.room_feature_permissions (room_id, user_id, feature)
where user_id is not null;

alter table public.room_feature_permissions enable row level security;

revoke all on table public.room_feature_permissions from anon, authenticated;
grant select on table public.room_feature_permissions to authenticated;

create policy room_feature_permissions_select_active_members
on public.room_feature_permissions
for select
to authenticated
using ((select public.is_active_room_member(room_id)));

create function private.insert_default_room_feature_permissions(target_room_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.room_feature_permissions (room_id, feature, role, allowed)
  values
    (target_room_id, 'chat', 'player', true),
    (target_room_id, 'map_view', 'player', true),
    (target_room_id, 'dice', 'player', true),
    (target_room_id, 'token_move', 'player', true),
    (target_room_id, 'drawing', 'player', false),
    (target_room_id, 'chat', 'spectator', false),
    (target_room_id, 'map_view', 'spectator', true),
    (target_room_id, 'dice', 'spectator', false),
    (target_room_id, 'token_move', 'spectator', false),
    (target_room_id, 'drawing', 'spectator', false)
  on conflict (room_id, feature, role, user_id) do nothing;
$$;

revoke all on function private.insert_default_room_feature_permissions(uuid)
from public, anon, authenticated;

select private.insert_default_room_feature_permissions(id)
from public.rooms;

create function private.insert_default_room_feature_permissions_on_room_create()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.insert_default_room_feature_permissions(new.id);
  return new;
end;
$$;

revoke all on function private.insert_default_room_feature_permissions_on_room_create()
from public, anon, authenticated;

create trigger insert_default_room_feature_permissions
after insert on public.rooms
for each row execute function private.insert_default_room_feature_permissions_on_room_create();

create function public.can_use_room_feature(target_room_id uuid, target_feature text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  caller_id uuid := (select auth.uid());
  caller_role text;
  resolved_allowed boolean;
begin
  if caller_id is null
    or target_feature is null
    or target_feature not in ('chat', 'map_view', 'dice', 'token_move', 'drawing') then
    return false;
  end if;

  select role
  into caller_role
  from public.room_members
  where room_id = target_room_id
    and user_id = caller_id
    and status = 'active';

  if caller_role is null then
    return false;
  end if;

  if caller_role = 'master' then
    return true;
  end if;

  select allowed
  into resolved_allowed
  from public.room_feature_permissions
  where room_id = target_room_id
    and feature = target_feature
    and user_id = caller_id;

  if found then
    return resolved_allowed;
  end if;

  select allowed
  into resolved_allowed
  from public.room_feature_permissions
  where room_id = target_room_id
    and feature = target_feature
    and role = caller_role;

  return coalesce(resolved_allowed, false);
end;
$$;

revoke all on function public.can_use_room_feature(uuid, text) from public, anon;
grant execute on function public.can_use_room_feature(uuid, text) to authenticated;

create function public.set_room_feature_permission(
  target_room_id uuid,
  target_feature text,
  new_allowed boolean,
  target_role text default null,
  target_user_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if not (select public.is_room_master(target_room_id)) then
    raise exception 'master role required' using errcode = '42501';
  end if;

  if target_feature is null
    or target_feature not in ('chat', 'map_view', 'dice', 'token_move', 'drawing') then
    raise exception 'invalid room feature' using errcode = '22023';
  end if;

  if new_allowed is null then
    raise exception 'permission state is required' using errcode = '22023';
  end if;

  if (target_role is null) = (target_user_id is null) then
    raise exception 'exactly one permission target is required' using errcode = '22023';
  end if;

  if target_role is not null then
    if target_role not in ('player', 'spectator') then
      raise exception 'permission role must be player or spectator' using errcode = '22023';
    end if;

    insert into public.room_feature_permissions (
      room_id,
      feature,
      role,
      allowed
    ) values (
      target_room_id,
      target_feature,
      target_role,
      new_allowed
    )
    on conflict (room_id, feature, role, user_id) do update
    set allowed = excluded.allowed,
        updated_at = now();
  else
    if not exists (
      select 1
      from public.room_members
      where room_id = target_room_id
        and user_id = target_user_id
        and role in ('player', 'spectator')
        and status = 'active'
    ) then
      raise exception 'active non-master room member required' using errcode = '22023';
    end if;

    insert into public.room_feature_permissions (
      room_id,
      feature,
      user_id,
      allowed
    ) values (
      target_room_id,
      target_feature,
      target_user_id,
      new_allowed
    )
    on conflict (room_id, feature, role, user_id) do update
    set allowed = excluded.allowed,
        updated_at = now();
  end if;
end;
$$;

revoke all on function public.set_room_feature_permission(uuid, text, boolean, text, uuid)
from public, anon;
grant execute on function public.set_room_feature_permission(uuid, text, boolean, text, uuid)
to authenticated;

drop policy chat_messages_select_active_members on public.chat_messages;

create policy chat_messages_select_authorized_members
on public.chat_messages
for select
to authenticated
using ((select public.is_active_room_member(room_id)));

create or replace function public.send_chat_message(
  target_room_id uuid,
  message_mode text,
  message_content text,
  target_character_id uuid default null
)
returns public.chat_messages
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_id uuid := (select auth.uid());
  caller_role text;
  speaking_character_name text;
  created_message public.chat_messages;
begin
  if caller_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  select role
  into caller_role
  from public.room_members
  where room_id = target_room_id
    and user_id = caller_id
    and status = 'active';

  if caller_role is null
    or not (select public.can_use_room_feature(target_room_id, 'chat')) then
    raise exception 'chat permission required' using errcode = '42501';
  end if;

  if message_mode is null or message_mode not in ('general', 'ic', 'ooc') then
    raise exception 'invalid chat mode' using errcode = '22023';
  end if;

  if message_content is null
    or char_length(message_content) not between 1 and 2000
    or char_length(btrim(message_content)) = 0 then
    raise exception 'message content must be 1 to 2000 characters' using errcode = '22023';
  end if;

  if target_character_id is not null then
    select name
    into speaking_character_name
    from public.character_sheets
    where id = target_character_id
      and room_id = target_room_id
      and (owner_id = caller_id or caller_role = 'master');

    if speaking_character_name is null then
      raise exception 'speaking character permission required' using errcode = '42501';
    end if;
  end if;

  insert into public.chat_messages (
    room_id,
    sender_id,
    character_id,
    character_name,
    mode,
    content
  ) values (
    target_room_id,
    caller_id,
    target_character_id,
    speaking_character_name,
    message_mode,
    message_content
  )
  returning * into created_message;

  return created_message;
end;
$$;

drop policy room_maps_select_active_members on public.room_maps;

create policy room_maps_select_authorized_members
on public.room_maps
for select
to authenticated
using ((select public.can_use_room_feature(room_id, 'map_view')));

create or replace function public.can_read_room_asset(target_asset_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.room_maps
    where room_maps.asset_id = target_asset_id
      and (select public.can_use_room_feature(room_maps.room_id, 'map_view'))
  ) or exists (
    select 1
    from public.room_tokens
    join public.room_maps on room_maps.id = room_tokens.map_id
    where room_tokens.image_asset_id = target_asset_id
      and (select public.can_use_room_feature(room_maps.room_id, 'map_view'))
  );
$$;

drop policy room_tokens_select_active_members on public.room_tokens;

create policy room_tokens_select_authorized_members
on public.room_tokens
for select
to authenticated
using (
  exists (
    select 1
    from public.room_maps
    where room_maps.id = map_id
      and (select public.can_use_room_feature(room_maps.room_id, 'map_view'))
  )
);

drop policy room_tokens_update_controllers on public.room_tokens;

create policy room_tokens_update_controllers
on public.room_tokens
for update
to authenticated
using (
  exists (
    select 1
    from public.room_maps
    join public.room_members on room_members.room_id = room_maps.room_id
    where room_maps.id = map_id
      and room_members.user_id = (select auth.uid())
      and room_members.status = 'active'
      and (select public.can_use_room_feature(room_maps.room_id, 'token_move'))
      and (
        room_members.role = 'master'
        or (room_members.role = 'player' and owner_id = (select auth.uid()))
      )
  )
)
with check (
  exists (
    select 1
    from public.room_maps
    join public.room_members on room_members.room_id = room_maps.room_id
    where room_maps.id = map_id
      and room_members.user_id = (select auth.uid())
      and room_members.status = 'active'
      and (select public.can_use_room_feature(room_maps.room_id, 'token_move'))
      and (
        room_members.role = 'master'
        or (room_members.role = 'player' and owner_id = (select auth.uid()))
      )
  )
  and (select public.is_valid_room_token_owner(map_id, owner_id))
  and (select public.can_link_room_token_asset(id, image_asset_id))
);

drop policy dice_rolls_select_authorized_members on public.dice_rolls;

create policy dice_rolls_select_authorized_members
on public.dice_rolls
for select
to authenticated
using (
  (select public.is_active_room_member(room_id))
  and (
    visibility = 'public'
    or roller_id = (select auth.uid())
    or (select public.is_room_master(room_id))
  )
);

drop policy dice_roll_notifications_select_active_members
on public.dice_roll_notifications;

create policy dice_roll_notifications_select_authorized_members
on public.dice_roll_notifications
for select
to authenticated
using ((select public.is_active_room_member(room_id)));

create or replace function public.roll_dice(target_room_id uuid, dice_expression text)
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

drop policy map_visibility_select_authorized_members on public.map_visibility;

create policy map_visibility_select_authorized_members
on public.map_visibility
for select
to authenticated
using (
  exists (
    select 1
    from public.room_maps
    where room_maps.id = map_id
      and (
        (select public.is_room_master(room_maps.room_id))
        or (
          (select public.can_use_room_feature(room_maps.room_id, 'map_view'))
          and (
            scope = 'all'
            or room_member_id = (select auth.uid())
          )
        )
      )
  )
);

drop policy room_members_receive_dice_changes on realtime.messages;

create policy room_members_receive_dice_changes
on realtime.messages
for select
to authenticated
using (
  extension = 'broadcast'
  and topic = (select realtime.topic())
  and coalesce(((select auth.jwt()) ->> 'is_anonymous')::boolean, false) = false
  and exists (
    select 1
    from public.room_members
    where user_id = (select auth.uid())
      and status = 'active'
      and (select realtime.topic()) = 'room:' || room_id::text || ':dice'
  )
);

drop policy room_members_receive_token_movement on realtime.messages;

create policy room_members_receive_token_movement
on realtime.messages
for select
to authenticated
using (
  extension = 'broadcast'
  and topic = (select realtime.topic())
  and coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) = false
  and exists (
    select 1
    from public.room_members
    where user_id = (select auth.uid())
      and status = 'active'
      and (select realtime.topic()) = 'room:' || room_id::text || ':tokens'
      and (select public.can_use_room_feature(room_id, 'map_view'))
  )
);

drop policy token_controllers_send_movement on realtime.messages;

create policy token_controllers_send_movement
on realtime.messages
for insert
to authenticated
with check (
  extension = 'broadcast'
  and topic = (select realtime.topic())
  and coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) = false
  and exists (
    select 1
    from public.room_members
    where user_id = (select auth.uid())
      and status = 'active'
      and role in ('master', 'player')
      and (select realtime.topic()) = 'room:' || room_id::text || ':tokens'
      and (select public.can_use_room_feature(room_id, 'token_move'))
  )
);

alter publication supabase_realtime add table public.room_feature_permissions;
