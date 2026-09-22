create function public.set_room_member_role(target_room_id uuid, target_user_id uuid, target_role text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if not (select public.is_room_master(target_room_id)) then
    raise exception 'master role required' using errcode = '42501';
  end if;

  if target_user_id = (select auth.uid()) then
    raise exception 'masters cannot change their own role' using errcode = '22023';
  end if;

  if target_role not in ('master', 'player', 'spectator') then
    raise exception 'role must be master, player, or spectator' using errcode = '22023';
  end if;

  update public.room_members
  set role = target_role
  where room_id = target_room_id
    and user_id = target_user_id
    and status = 'active';

  if not found then
    raise exception 'active room member not found' using errcode = '22023';
  end if;
end;
$$;

create function public.force_remove_room_member(target_room_id uuid, target_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if not (select public.is_room_master(target_room_id)) then
    raise exception 'master role required' using errcode = '42501';
  end if;

  if target_user_id = (select auth.uid()) then
    raise exception 'masters cannot force-remove themselves' using errcode = '22023';
  end if;

  update public.room_members
  set status = 'removed'
  where room_id = target_room_id
    and user_id = target_user_id
    and status = 'active';

  if not found then
    raise exception 'active room member not found' using errcode = '22023';
  end if;
end;
$$;

revoke all on function public.set_room_member_role(uuid, uuid, text) from public;
revoke all on function public.set_room_member_role(uuid, uuid, text) from anon;
grant execute on function public.set_room_member_role(uuid, uuid, text) to authenticated;
revoke all on function public.force_remove_room_member(uuid, uuid) from public;
revoke all on function public.force_remove_room_member(uuid, uuid) from anon;
grant execute on function public.force_remove_room_member(uuid, uuid) to authenticated;
