alter table public.chat_messages
alter column sender_id drop not null,
add column message_type text not null default 'chat',
add column event_type text,
add column event_data jsonb;

alter table public.chat_messages
add constraint chat_messages_message_type_check
check (message_type in ('chat', 'system')),
add constraint chat_messages_event_type_check
check (event_type is null or event_type in ('dice_roll', 'member_joined', 'member_left', 'notification')),
add constraint chat_messages_event_data_check
check (event_data is null or jsonb_typeof(event_data) = 'object'),
add constraint chat_messages_shape_check
check (
  (
    message_type = 'chat'
    and sender_id is not null
    and event_type is null
    and event_data is null
  )
  or
  (
    message_type = 'system'
    and mode = 'general'
    and character_id is null
    and character_name is null
    and event_type is not null
    and event_data is not null
  )
);

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create function private.record_system_message(
  target_room_id uuid,
  system_event_type text,
  message_content text,
  event_payload jsonb default '{}'::jsonb,
  actor_id uuid default null
)
returns public.chat_messages
language plpgsql
security invoker
set search_path = ''
as $$
declare
  created_message public.chat_messages;
begin
  if system_event_type is null
    or system_event_type not in ('dice_roll', 'member_joined', 'member_left', 'notification') then
    raise exception 'invalid system event type' using errcode = '22023';
  end if;

  if message_content is null
    or char_length(message_content) not between 1 and 2000
    or char_length(btrim(message_content)) = 0 then
    raise exception 'message content must be 1 to 2000 characters' using errcode = '22023';
  end if;

  if event_payload is null or jsonb_typeof(event_payload) <> 'object' then
    raise exception 'system event payload must be an object' using errcode = '22023';
  end if;

  insert into public.chat_messages (
    room_id,
    sender_id,
    mode,
    content,
    message_type,
    event_type,
    event_data
  ) values (
    target_room_id,
    actor_id,
    'general',
    message_content,
    'system',
    system_event_type,
    event_payload
  )
  returning * into created_message;

  return created_message;
end;
$$;

revoke all on function private.record_system_message(uuid, text, text, jsonb, uuid)
from public, anon, authenticated;
