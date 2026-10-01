alter table public.dice_rolls
add column visibility text not null default 'public'
check (visibility in ('public', 'private'));

drop policy dice_rolls_select_active_members on public.dice_rolls;

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

create table public.dice_roll_notifications (
  id uuid primary key references public.dice_rolls (id) on delete cascade,
  room_id uuid not null references public.rooms (id) on delete cascade,
  roller_id uuid not null references auth.users (id) on delete cascade,
  visibility text not null check (visibility in ('public', 'private')),
  created_at timestamptz not null
);

alter table public.dice_roll_notifications enable row level security;

create policy dice_roll_notifications_select_active_members
on public.dice_roll_notifications
for select
to authenticated
using ((select public.is_active_room_member(room_id)));

revoke all on table public.dice_roll_notifications from anon, authenticated;
grant select on table public.dice_roll_notifications to authenticated;

insert into public.dice_roll_notifications (id, room_id, roller_id, visibility, created_at)
select id, room_id, roller_id, visibility, created_at
from public.dice_rolls;

create function public.set_dice_roll_visibility()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.visibility := coalesce(
    nullif(pg_catalog.current_setting('app.dice_roll_visibility', true), ''),
    'public'
  );
  return new;
end;
$$;

revoke all on function public.set_dice_roll_visibility() from public, anon, authenticated;

create trigger set_dice_roll_visibility
before insert on public.dice_rolls
for each row execute function public.set_dice_roll_visibility();

create function public.sync_dice_roll_notification()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  insert into public.dice_roll_notifications (id, room_id, roller_id, visibility, created_at)
  values (new.id, new.room_id, new.roller_id, new.visibility, new.created_at)
  on conflict (id) do update set visibility = excluded.visibility;

  return new;
end;
$$;

revoke all on function public.sync_dice_roll_notification() from public, anon, authenticated;

create trigger sync_dice_roll_notification
after insert or update of visibility on public.dice_rolls
for each row execute function public.sync_dice_roll_notification();

create function public.roll_dice(target_room_id uuid, dice_expression text, roll_visibility text)
returns public.dice_rolls
language plpgsql
security definer
set search_path = ''
as $$
declare
  created_roll public.dice_rolls;
  previous_visibility text := pg_catalog.current_setting('app.dice_roll_visibility', true);
begin
  if roll_visibility is null or roll_visibility not in ('public', 'private') then
    raise exception 'invalid dice visibility' using errcode = '22023';
  end if;

  perform pg_catalog.set_config('app.dice_roll_visibility', roll_visibility, true);

  select *
  into created_roll
  from public.roll_dice(target_room_id, dice_expression);

  perform pg_catalog.set_config(
    'app.dice_roll_visibility',
    coalesce(previous_visibility, ''),
    true
  );

  return created_roll;
end;
$$;

revoke all on function public.roll_dice(uuid, text, text) from public;
revoke all on function public.roll_dice(uuid, text, text) from anon;
grant execute on function public.roll_dice(uuid, text, text) to authenticated;

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

alter publication supabase_realtime add table public.dice_rolls;
alter publication supabase_realtime add table public.dice_roll_notifications;
