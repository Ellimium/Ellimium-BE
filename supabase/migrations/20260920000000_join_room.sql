create function public.join_room(room_invite_code text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  target_room_id uuid;
begin
  if current_user_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    raise exception 'registered account required' using errcode = '42501';
  end if;

  select id
  into target_room_id
  from public.rooms
  where invite_code = btrim(room_invite_code);

  if target_room_id is null then
    raise exception 'invalid invite code' using errcode = '22023';
  end if;

  insert into public.room_members (room_id, user_id, role)
  values (target_room_id, current_user_id, 'player')
  on conflict (room_id, user_id) do update
  set status = 'active',
      joined_at = now();

  return target_room_id;
end;
$$;

revoke all on function public.join_room(text) from public;
revoke all on function public.join_room(text) from anon;
grant execute on function public.join_room(text) to authenticated;
