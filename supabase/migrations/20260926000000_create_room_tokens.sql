create table public.room_tokens (
  id uuid primary key default gen_random_uuid(),
  map_id uuid not null references public.room_maps (id) on delete cascade,
  owner_id uuid references auth.users (id) on delete set null,
  image_asset_id uuid references public.assets (id) on delete set null,
  name text not null check (char_length(btrim(name)) between 1 and 50),
  x numeric not null default 0,
  y numeric not null default 0,
  size numeric not null default 1 check (size > 0),
  created_at timestamptz not null default now()
);

alter table public.room_tokens enable row level security;

create function public.is_valid_room_token_owner(target_map_id uuid, target_owner_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select target_owner_id is null or exists (
    select 1
    from public.room_maps
    join public.room_members on room_members.room_id = room_maps.room_id
    where room_maps.id = target_map_id
      and room_members.user_id = target_owner_id
      and room_members.role = 'player'
      and room_members.status = 'active'
  );
$$;

create function public.can_link_room_token_asset(target_token_id uuid, target_asset_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select target_asset_id is null or exists (
    select 1
    from public.assets
    where assets.id = target_asset_id
      and assets.category = 'token'
      and (
        assets.owner_id = (select auth.uid())
        or exists (
          select 1
          from public.room_tokens
          where room_tokens.id = target_token_id
            and room_tokens.image_asset_id = target_asset_id
        )
      )
  );
$$;

revoke all on function public.is_valid_room_token_owner(uuid, uuid) from public;
grant execute on function public.is_valid_room_token_owner(uuid, uuid) to authenticated;
revoke all on function public.can_link_room_token_asset(uuid, uuid) from public;
grant execute on function public.can_link_room_token_asset(uuid, uuid) to authenticated;

create function public.clear_invalid_room_token_owner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.role <> 'player' or new.status <> 'active' then
    update public.room_tokens
    set owner_id = null
    from public.room_maps
    where room_tokens.map_id = room_maps.id
      and room_maps.room_id = new.room_id
      and room_tokens.owner_id = new.user_id;
  end if;

  return new;
end;
$$;

revoke all on function public.clear_invalid_room_token_owner() from public;

create trigger clear_invalid_room_token_owner
  after update of role, status on public.room_members
  for each row execute function public.clear_invalid_room_token_owner();

create policy room_tokens_select_active_members
on public.room_tokens
for select
to authenticated
using (
  exists (
    select 1
    from public.room_maps
    where room_maps.id = map_id
      and (select public.is_active_room_member(room_maps.room_id))
  )
);

create policy room_tokens_insert_masters
on public.room_tokens
for insert
to authenticated
with check (
  exists (
    select 1
    from public.room_maps
    where room_maps.id = map_id
      and (select public.is_room_master(room_maps.room_id))
  )
  and (select public.is_valid_room_token_owner(map_id, owner_id))
  and (select public.can_link_room_token_asset(id, image_asset_id))
);

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
      and (
        room_members.role = 'master'
        or (room_members.role = 'player' and owner_id = (select auth.uid()))
      )
  )
  and (select public.is_valid_room_token_owner(map_id, owner_id))
  and (select public.can_link_room_token_asset(id, image_asset_id))
);

create policy room_tokens_delete_masters
on public.room_tokens
for delete
to authenticated
using (
  exists (
    select 1
    from public.room_maps
    where room_maps.id = map_id
      and (select public.is_room_master(room_maps.room_id))
  )
);

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
    join public.room_members on room_members.room_id = room_maps.room_id
    where room_maps.asset_id = target_asset_id
      and room_members.user_id = (select auth.uid())
      and room_members.status = 'active'
  ) or exists (
    select 1
    from public.room_tokens
    join public.room_maps on room_maps.id = room_tokens.map_id
    join public.room_members on room_members.room_id = room_maps.room_id
    where room_tokens.image_asset_id = target_asset_id
      and room_members.user_id = (select auth.uid())
      and room_members.status = 'active'
  );
$$;

create policy room_members_receive_token_movement
on realtime.messages
for select
to authenticated
using (
  private
  and extension = 'broadcast'
  and topic = (select realtime.topic())
  and coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) = false
  and exists (
    select 1
    from public.room_members
    where user_id = (select auth.uid())
      and status = 'active'
      and (select realtime.topic()) = 'room:' || room_id::text || ':tokens'
  )
);

create policy token_controllers_send_movement
on realtime.messages
for insert
to authenticated
with check (
  private
  and extension = 'broadcast'
  and topic = (select realtime.topic())
  and coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) = false
  and exists (
    select 1
    from public.room_tokens
    join public.room_maps on room_maps.id = room_tokens.map_id
    join public.room_members on room_members.room_id = room_maps.room_id
    where room_tokens.id::text = payload ->> 'token_id'
      and room_members.user_id = (select auth.uid())
      and room_members.status = 'active'
      and (select realtime.topic()) = 'room:' || room_maps.room_id::text || ':tokens'
      and (
        room_members.role = 'master'
        or (room_members.role = 'player' and room_tokens.owner_id = (select auth.uid()))
      )
  )
);

alter publication supabase_realtime add table public.room_tokens;
