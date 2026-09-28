create table public.character_sheets (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms (id) on delete cascade,
  owner_id uuid not null references auth.users (id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 50),
  system text not null check (system in ('dnd_5e', 'coc_7e', 'custom')),
  attributes jsonb not null default '{}'::jsonb check (jsonb_typeof(attributes) = 'object'),
  created_at timestamptz not null default now()
);

create index character_sheets_room_id_idx on public.character_sheets (room_id);
create index character_sheets_owner_id_idx on public.character_sheets (owner_id);

alter table public.character_sheets enable row level security;

revoke all on table public.character_sheets from anon, authenticated;
grant select, insert on table public.character_sheets to authenticated;

create policy character_sheets_select_owner_or_master
on public.character_sheets
for select
to authenticated
using (
  (
    owner_id = (select auth.uid())
    and exists (
      select 1
      from public.room_members
      where room_members.room_id = character_sheets.room_id
        and room_members.user_id = (select auth.uid())
        and room_members.role = 'player'
        and room_members.status = 'active'
    )
  )
  or (select public.is_room_master(room_id))
);

create policy character_sheets_insert_players
on public.character_sheets
for insert
to authenticated
with check (
  owner_id = (select auth.uid())
  and exists (
    select 1
    from public.room_members
    where room_members.room_id = character_sheets.room_id
      and room_members.user_id = (select auth.uid())
      and room_members.role = 'player'
      and room_members.status = 'active'
  )
);
