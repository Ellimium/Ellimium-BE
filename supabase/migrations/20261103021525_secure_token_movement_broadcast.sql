-- Channel INSERT permissions are cached at join time and cannot validate each payload.
drop policy token_controllers_send_movement on realtime.messages;

-- Use a new topic so cached send permissions on legacy channels cannot reach new clients.
drop policy room_members_receive_token_movement on realtime.messages;
create policy room_members_receive_token_movement
on realtime.messages
for select
to authenticated
using (
  extension = 'broadcast'
  and topic = (select realtime.topic())
  and coalesce(((select auth.jwt()) ->> 'is_anonymous')::boolean, false) = false
  and exists (
    select 1 from public.room_members
    where user_id = (select auth.uid())
      and status = 'active'
      and (select public.can_use_room_feature(room_id, 'map_view'))
      and (select realtime.topic()) = 'room:' || room_id::text || ':token-movements'
  )
);

create function private.broadcast_token_movement(
  target_room_id uuid,
  target_token_id uuid,
  position_x double precision,
  position_y double precision
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_id uuid := (select auth.uid());
begin
  if caller_id is null
    or coalesce(((select auth.jwt()) ->> 'is_anonymous')::boolean, false)
    or not exists (
      select 1
      from public.room_tokens as t
      join public.room_maps as m on m.id = t.map_id
      join public.room_members as member on member.room_id = m.room_id
      where t.id = target_token_id
        and m.room_id = target_room_id
        and member.user_id = caller_id
        and member.status = 'active'
        and (
          member.role = 'master'
          or (member.role = 'player' and t.owner_id = caller_id)
        )
        and public.can_use_room_feature(m.room_id, 'token_move')
    ) then
    raise exception 'token movement permission required' using errcode = '42501';
  end if;

  if position_x is null or position_y is null
    or position_x in ('NaN'::float8, 'Infinity'::float8, '-Infinity'::float8)
    or position_y in ('NaN'::float8, 'Infinity'::float8, '-Infinity'::float8) then
    raise exception 'finite token coordinates required' using errcode = '22023';
  end if;

  perform realtime.send(
    pg_catalog.jsonb_build_object(
      'token_id', target_token_id,
      'x', position_x,
      'y', position_y,
      'sender_id', caller_id
    ),
    'token-move',
    'room:' || target_room_id::text || ':token-movements',
    true
  );
end;
$$;

revoke all on function private.broadcast_token_movement(uuid, uuid, double precision, double precision)
from public, anon, authenticated;
grant execute on function private.broadcast_token_movement(uuid, uuid, double precision, double precision)
to authenticated;

-- A parsed SQL body lets the invoker call the checked helper without private schema USAGE.
create function public.broadcast_token_movement(
  target_room_id uuid,
  target_token_id uuid,
  position_x double precision,
  position_y double precision
)
returns void
language sql
security invoker
set search_path = ''
begin atomic
  select private.broadcast_token_movement(target_room_id, target_token_id, position_x, position_y);
end;

revoke all on function public.broadcast_token_movement(uuid, uuid, double precision, double precision)
from public, anon;
grant execute on function public.broadcast_token_movement(uuid, uuid, double precision, double precision)
to authenticated;
