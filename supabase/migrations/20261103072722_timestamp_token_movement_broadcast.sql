-- Server time orders previews against other previews and confirmed DB commit timestamps.
create or replace function private.broadcast_token_movement(
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
      'sender_id', caller_id,
      'sent_at', pg_catalog.clock_timestamp()
    ),
    'token-move',
    'room:' || target_room_id::text || ':token-movements',
    true
  );
end;
$$;

