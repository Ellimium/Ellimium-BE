create table public.room_map_drawings (
  id uuid primary key default gen_random_uuid(),
  map_id uuid not null references public.room_maps (id) on delete cascade,
  drawing_type text not null check (
    drawing_type in ('line', 'circle', 'rectangle', 'freehand', 'text')
  ),
  geometry jsonb not null check (jsonb_typeof(geometry) = 'object'),
  text_content text,
  color text not null check (color ~ '^#[0-9A-Fa-f]{6}$'),
  stroke_width numeric not null check (stroke_width > 0 and stroke_width <= 100),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint room_map_drawings_text_content check (
    (
      drawing_type = 'text'
      and text_content is not null
      and char_length(btrim(text_content)) between 1 and 500
    )
    or (
      drawing_type <> 'text'
      and text_content is null
    )
  )
);

create index room_map_drawings_map_idx
on public.room_map_drawings (map_id, created_at, id);

alter table public.room_map_drawings enable row level security;

revoke all on table public.room_map_drawings from anon, authenticated;
grant select, delete on table public.room_map_drawings to authenticated;
grant insert (id, map_id, drawing_type, geometry, text_content, color, stroke_width)
on public.room_map_drawings to authenticated;
grant update (drawing_type, geometry, text_content, color, stroke_width)
on public.room_map_drawings to authenticated;

create policy room_map_drawings_select_active_members
on public.room_map_drawings
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

create policy room_map_drawings_insert_authorized_editors
on public.room_map_drawings
for insert
to authenticated
with check (
  exists (
    select 1
    from public.room_maps
    join public.room_members on room_members.room_id = room_maps.room_id
    where room_maps.id = map_id
      and room_members.user_id = (select auth.uid())
      and room_members.status = 'active'
      and room_members.role in ('master', 'player')
      and (select public.can_use_room_feature(room_maps.room_id, 'drawing'))
  )
);

create policy room_map_drawings_update_authorized_editors
on public.room_map_drawings
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
      and room_members.role in ('master', 'player')
      and (select public.can_use_room_feature(room_maps.room_id, 'drawing'))
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
      and room_members.role in ('master', 'player')
      and (select public.can_use_room_feature(room_maps.room_id, 'drawing'))
  )
);

create policy room_map_drawings_delete_authorized_editors
on public.room_map_drawings
for delete
to authenticated
using (
  exists (
    select 1
    from public.room_maps
    join public.room_members on room_members.room_id = room_maps.room_id
    where room_maps.id = map_id
      and room_members.user_id = (select auth.uid())
      and room_members.status = 'active'
      and room_members.role in ('master', 'player')
      and (select public.can_use_room_feature(room_maps.room_id, 'drawing'))
  )
);

create function public.set_room_map_drawing_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

revoke all on function public.set_room_map_drawing_updated_at()
from public, anon, authenticated;

create trigger set_room_map_drawing_updated_at
before update on public.room_map_drawings
for each row execute function public.set_room_map_drawing_updated_at();

create function private.broadcast_room_map_drawing_changes()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_room_id uuid;
begin
  select room_id
  into target_room_id
  from public.room_maps
  where id = coalesce(new.map_id, old.map_id);

  if target_room_id is not null then
    perform realtime.broadcast_changes(
      'room:' || target_room_id::text || ':drawings',
      tg_op,
      tg_op,
      tg_table_name,
      tg_table_schema,
      new,
      old
    );
  end if;

  return null;
end;
$$;

revoke all on function private.broadcast_room_map_drawing_changes()
from public, anon, authenticated;

create trigger broadcast_room_map_drawing_changes
after insert or update or delete on public.room_map_drawings
for each row execute function private.broadcast_room_map_drawing_changes();

create policy room_members_receive_drawing_changes
on realtime.messages
for select
to authenticated
using (
  private
  and extension = 'broadcast'
  and topic = (select realtime.topic())
  and coalesce(((select auth.jwt()) ->> 'is_anonymous')::boolean, false) = false
  and exists (
    select 1
    from public.room_members
    where user_id = (select auth.uid())
      and status = 'active'
      and (select realtime.topic()) = 'room:' || room_id::text || ':drawings'
  )
);
