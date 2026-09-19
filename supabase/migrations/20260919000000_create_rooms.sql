create table public.rooms (
  id uuid primary key default gen_random_uuid(),
  creator_id uuid not null references auth.users (id),
  name text not null check (char_length(btrim(name)) between 1 and 50),
  description text check (description is null or char_length(description) <= 500),
  game_system text not null check (char_length(btrim(game_system)) between 1 and 50),
  invite_code text not null unique default gen_random_uuid()::text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.room_members (
  room_id uuid not null references public.rooms (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  role text not null check (role in ('master', 'player', 'spectator')),
  status text not null default 'active' check (status in ('active', 'left', 'removed')),
  joined_at timestamptz not null default now(),
  primary key (room_id, user_id)
);

create function public.is_active_room_member(target_room_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.room_members
    where room_id = target_room_id
      and user_id = (select auth.uid())
      and status = 'active'
  );
$$;

create function public.is_room_master(target_room_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.room_members
    where room_id = target_room_id
      and user_id = (select auth.uid())
      and role = 'master'
      and status = 'active'
  );
$$;

create function public.shares_active_room(target_user_id text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.room_members as mine
    join public.room_members as theirs on theirs.room_id = mine.room_id
    where mine.user_id = (select auth.uid())
      and mine.status = 'active'
      and theirs.user_id::text = target_user_id
      and theirs.status = 'active'
  );
$$;

create function public.create_room(room_name text, room_description text, room_game_system text)
returns public.rooms
language plpgsql
security definer
set search_path = ''
as $$
declare
  created_room public.rooms;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if coalesce(char_length(btrim(room_name)) not between 1 and 50, true) then
    raise exception 'room name must be 1 to 50 characters' using errcode = '22023';
  end if;

  if room_description is not null and char_length(room_description) > 500 then
    raise exception 'room description must be 500 characters or fewer' using errcode = '22023';
  end if;

  if coalesce(char_length(btrim(room_game_system)) not between 1 and 50, true) then
    raise exception 'game system must be 1 to 50 characters' using errcode = '22023';
  end if;

  insert into public.rooms (creator_id, name, description, game_system)
  values (auth.uid(), btrim(room_name), nullif(btrim(room_description), ''), btrim(room_game_system))
  returning * into created_room;

  insert into public.room_members (room_id, user_id, role)
  values (created_room.id, auth.uid(), 'master');

  return created_room;
end;
$$;

revoke all on function public.create_room(text, text, text) from public;
grant execute on function public.create_room(text, text, text) to authenticated;
revoke all on function public.is_active_room_member(uuid) from public;
grant execute on function public.is_active_room_member(uuid) to authenticated;
revoke all on function public.is_room_master(uuid) from public;
grant execute on function public.is_room_master(uuid) to authenticated;
revoke all on function public.shares_active_room(text) from public;
grant execute on function public.shares_active_room(text) to authenticated;

alter table public.rooms enable row level security;
alter table public.room_members enable row level security;

create policy rooms_select_active_members
on public.rooms
for select
to authenticated
using ((select public.is_active_room_member(id)));

create policy rooms_update_creators
on public.rooms
for update
to authenticated
using (
  (select public.is_room_master(id))
  and creator_id = (select auth.uid())
)
with check (
  (select public.is_room_master(id))
  and creator_id = (select auth.uid())
);

create policy room_members_select_active_members
on public.room_members
for select
to authenticated
using (status = 'active' and (select public.is_active_room_member(room_id)));

create policy profiles_select_same_active_room
on public.profiles
for select
to authenticated
using ((select public.shares_active_room(user_id::text)));

create policy avatars_select_same_active_room
on storage.objects
for select
to authenticated
using (
  bucket_id = 'avatars'
  and (select public.shares_active_room((storage.foldername(name))[1]))
);
