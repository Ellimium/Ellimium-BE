create table public.room_maps (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms (id) on delete cascade,
  asset_id uuid not null references public.assets (id),
  grid_cell_size integer check (grid_cell_size > 0),
  grid_offset_x integer,
  grid_offset_y integer,
  created_at timestamptz not null default now(),
  unique (room_id, asset_id)
);

alter table public.room_maps enable row level security;

create function public.can_read_room_asset(target_asset_id uuid)
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
  );
$$;

revoke all on function public.can_read_room_asset(uuid) from public;
grant execute on function public.can_read_room_asset(uuid) to authenticated;

create policy room_maps_select_active_members
on public.room_maps
for select
to authenticated
using ((select public.is_active_room_member(room_id)));

create policy room_maps_insert_masters
on public.room_maps
for insert
to authenticated
with check (
  (select public.is_room_master(room_id))
  and exists (
    select 1
    from public.assets
    where id = asset_id
      and owner_id = (select auth.uid())
      and category = 'map'
  )
);

create policy room_maps_update_masters
on public.room_maps
for update
to authenticated
using ((select public.is_room_master(room_id)))
with check (
  (select public.is_room_master(room_id))
  and exists (
    select 1
    from public.assets
    where id = asset_id
      and owner_id = (select auth.uid())
      and category = 'map'
  )
);

create policy room_maps_delete_masters
on public.room_maps
for delete
to authenticated
using ((select public.is_room_master(room_id)));

drop policy assets_select_own on public.assets;

create policy assets_select_authorized
on public.assets
for select
to authenticated
using (
  owner_id = (select auth.uid())
  or (select public.can_read_room_asset(id))
);

drop policy assets_select_own on storage.objects;

create policy assets_select_authorized
on storage.objects
for select
to authenticated
using (
  bucket_id = 'assets'
  and exists (
    select 1
    from public.assets
    where storage.objects.name in (assets.storage_path, assets.thumbnail_storage_path)
      and (
        assets.owner_id = (select auth.uid())
        or (select public.can_read_room_asset(assets.id))
      )
  )
);
