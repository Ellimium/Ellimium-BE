alter table public.room_maps
add column fog_enabled boolean not null default false;

create function public.set_map_fog_enabled(target_map_id uuid, new_fog_enabled boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_room_id uuid;
begin
  if (select auth.uid()) is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if new_fog_enabled is null then
    raise exception 'fog state is required' using errcode = '22023';
  end if;

  select room_id
  into target_room_id
  from public.room_maps
  where id = target_map_id;

  if target_room_id is null then
    raise exception 'room map not found' using errcode = '22023';
  end if;

  if not (select public.is_room_master(target_room_id)) then
    raise exception 'master role required' using errcode = '42501';
  end if;

  update public.room_maps
  set fog_enabled = new_fog_enabled
  where id = target_map_id;
end;
$$;

revoke all on function public.set_map_fog_enabled(uuid, boolean) from public, anon;
grant execute on function public.set_map_fog_enabled(uuid, boolean) to authenticated;

create function public.is_valid_revealed_areas(value jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select case
    when pg_catalog.jsonb_typeof(value) = 'array' then not exists (
      select 1
      from pg_catalog.jsonb_array_elements(value) as areas(area)
      where pg_catalog.jsonb_typeof(area) <> 'object'
        or pg_catalog.jsonb_typeof(area -> 'x') is distinct from 'number'
        or pg_catalog.jsonb_typeof(area -> 'y') is distinct from 'number'
        or pg_catalog.jsonb_typeof(area -> 'width') is distinct from 'number'
        or pg_catalog.jsonb_typeof(area -> 'height') is distinct from 'number'
        or (area ->> 'x')::numeric < 0
        or (area ->> 'y')::numeric < 0
        or (area ->> 'width')::numeric <= 0
        or (area ->> 'height')::numeric <= 0
    )
    else false
  end;
$$;

revoke all on function public.is_valid_revealed_areas(jsonb) from public, anon;
grant execute on function public.is_valid_revealed_areas(jsonb) to authenticated;

create table public.map_visibility (
  id uuid primary key default gen_random_uuid(),
  map_id uuid not null references public.room_maps (id) on delete cascade,
  room_member_id uuid references auth.users (id) on delete cascade,
  scope text not null check (scope in ('all', 'member')),
  inherits_common boolean not null default false,
  revealed_areas jsonb not null default '[]'::jsonb
    check (public.is_valid_revealed_areas(revealed_areas)),
  updated_at timestamptz not null default now(),
  unique nulls not distinct (map_id, room_member_id),
  constraint map_visibility_scope_member check (
    (scope = 'all' and room_member_id is null)
    or (scope = 'member' and room_member_id is not null)
  ),
  constraint map_visibility_inheritance_scope check (
    scope = 'member' or not inherits_common
  )
);

create index map_visibility_room_member_id_idx
on public.map_visibility (room_member_id)
where room_member_id is not null;

alter table public.map_visibility enable row level security;

revoke all on table public.map_visibility from anon, authenticated;
-- ponytail: rows are update-only because Postgres Changes cannot apply RLS to DELETE;
-- inherits_common restores shared visibility without leaking DELETE events.
grant select, insert, update (revealed_areas, inherits_common) on table public.map_visibility to authenticated;

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
          (select public.is_active_room_member(room_maps.room_id))
          and (
            scope = 'all'
            or room_member_id = (select auth.uid())
          )
        )
      )
  )
);

create policy map_visibility_insert_masters
on public.map_visibility
for insert
to authenticated
with check (
  exists (
    select 1
    from public.room_maps
    where room_maps.id = map_id
      and (select public.is_room_master(room_maps.room_id))
      and (
        scope = 'all'
        or exists (
          select 1
          from public.room_members
          where room_members.room_id = room_maps.room_id
            and room_members.user_id = room_member_id
            and room_members.role = 'player'
            and room_members.status = 'active'
        )
      )
  )
);

create policy map_visibility_update_masters
on public.map_visibility
for update
to authenticated
using (
  exists (
    select 1
    from public.room_maps
    where room_maps.id = map_id
      and (select public.is_room_master(room_maps.room_id))
  )
)
with check (
  exists (
    select 1
    from public.room_maps
    where room_maps.id = map_id
      and (select public.is_room_master(room_maps.room_id))
      and (
        scope = 'all'
        or exists (
          select 1
          from public.room_members
          where room_members.room_id = room_maps.room_id
            and room_members.user_id = room_member_id
            and room_members.role = 'player'
            and room_members.status = 'active'
        )
      )
  )
);

create function public.set_map_visibility_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

revoke all on function public.set_map_visibility_updated_at() from public, anon, authenticated;

create trigger set_map_visibility_updated_at
before update on public.map_visibility
for each row execute function public.set_map_visibility_updated_at();

alter publication supabase_realtime add table public.room_maps;
alter publication supabase_realtime add table public.map_visibility;
