create table public.room_asset_shares (
  asset_id uuid not null references public.assets (id) on delete cascade,
  room_id uuid not null references public.rooms (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (asset_id, room_id)
);

create index room_asset_shares_room_idx on public.room_asset_shares (room_id, asset_id);

alter table public.room_asset_shares enable row level security;
revoke all on public.room_asset_shares from public, anon, authenticated;
grant select, insert, delete on public.room_asset_shares to authenticated;
grant all on public.room_asset_shares to service_role;

-- Only the owner may share, and only into a room they currently belong to.
create policy room_asset_shares_insert_owner
on public.room_asset_shares for insert to authenticated
with check (
  (select public.is_active_room_member(room_id))
  and exists (
    select 1 from public.assets
    where assets.id = asset_id and assets.owner_id = (select auth.uid())
  )
);

-- Owners retain visibility and revocation rights after leaving a room.
create policy room_asset_shares_select_authorized
on public.room_asset_shares for select to authenticated
using (
  (select public.is_active_room_member(room_id))
  or exists (
    select 1 from public.assets
    where assets.id = asset_id and assets.owner_id = (select auth.uid())
  )
);

create policy room_asset_shares_delete_owner
on public.room_asset_shares for delete to authenticated
using (
  exists (
    select 1 from public.assets
    where assets.id = asset_id and assets.owner_id = (select auth.uid())
  )
);

-- Bypass share-row RLS only for this membership lookup to avoid the
-- assets -> shares -> assets policy cycle. private is not exposed by the API.
create function private.can_read_shared_asset(target_asset_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null and exists (
    select 1 from public.room_asset_shares
    where asset_id = target_asset_id
      and public.is_active_room_member(room_id)
  );
$$;

revoke all on function private.can_read_shared_asset(uuid) from public, anon, authenticated;
grant execute on function private.can_read_shared_asset(uuid) to authenticated;

-- Add metadata visibility independently of existing map/token file access.
-- Storage access for library shares is handled by the following TODO.
create policy assets_select_shared_rooms
on public.assets for select to authenticated
using ((select private.can_read_shared_asset(id)));
