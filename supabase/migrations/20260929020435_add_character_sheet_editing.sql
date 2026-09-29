alter table public.character_sheets
add column skills jsonb not null default '{}'::jsonb check (jsonb_typeof(skills) = 'object'),
add column equipment jsonb not null default '[]'::jsonb check (jsonb_typeof(equipment) = 'array'),
add column resources jsonb not null default '{}'::jsonb check (jsonb_typeof(resources) = 'object'),
add column notes text not null default '',
add column backstory text not null default '';

grant select on public.room_members to authenticated;

grant update (attributes, skills, equipment, resources, notes, backstory)
on public.character_sheets
to authenticated;

create policy character_sheets_update_owner_or_master
on public.character_sheets
for update
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
)
with check (
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
