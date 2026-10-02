create function private.record_room_member_system_message()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if tg_op = 'INSERT'
    or (old.status is distinct from 'active' and new.status = 'active') then
    perform private.record_system_message(
      new.room_id,
      'member_joined',
      '룸에 입장했습니다.',
      pg_catalog.jsonb_build_object('user_id', new.user_id),
      new.user_id
    );
  elsif old.status = 'active' and new.status in ('left', 'removed') then
    perform private.record_system_message(
      new.room_id,
      'member_left',
      '룸에서 퇴장했습니다.',
      pg_catalog.jsonb_build_object('user_id', new.user_id, 'status', new.status),
      new.user_id
    );
  end if;

  return new;
end;
$$;

revoke all on function private.record_room_member_system_message()
from public, anon, authenticated;

create trigger record_room_member_system_message
after insert or update of status on public.room_members
for each row execute function private.record_room_member_system_message();

create function private.record_dice_roll_system_message()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  event_payload jsonb := pg_catalog.jsonb_build_object(
    'roll_id', new.id,
    'visibility', new.visibility
  );
begin
  if new.visibility = 'public' then
    event_payload := event_payload || pg_catalog.jsonb_build_object(
      'expression', new.expression,
      'individual_results', new.individual_results,
      'total', new.total
    );
  end if;

  perform private.record_system_message(
    new.room_id,
    'dice_roll',
    case new.visibility
      when 'private' then '비공개 주사위를 굴렸습니다.'
      else '주사위를 굴렸습니다.'
    end,
    event_payload,
    new.roller_id
  );

  return new;
end;
$$;

revoke all on function private.record_dice_roll_system_message()
from public, anon, authenticated;

create trigger record_dice_roll_system_message
after insert on public.dice_rolls
for each row execute function private.record_dice_roll_system_message();

create function public.send_system_notification(
  target_room_id uuid,
  message_content text
)
returns public.chat_messages
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_id uuid := (select auth.uid());
  created_message public.chat_messages;
begin
  if caller_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.room_members
    where room_id = target_room_id
      and user_id = caller_id
      and role = 'master'
      and status = 'active'
  ) then
    raise exception 'master role required' using errcode = '42501';
  end if;

  select *
  into created_message
  from private.record_system_message(
    target_room_id,
    'notification',
    message_content,
    pg_catalog.jsonb_build_object('created_by', caller_id),
    caller_id
  );

  return created_message;
end;
$$;

revoke all on function public.send_system_notification(uuid, text) from public;
revoke all on function public.send_system_notification(uuid, text) from anon;
grant execute on function public.send_system_notification(uuid, text) to authenticated;
