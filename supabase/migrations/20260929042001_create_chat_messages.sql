create table public.chat_messages (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms (id) on delete cascade,
  sender_id uuid not null references auth.users (id) on delete cascade,
  character_id uuid references public.character_sheets (id) on delete set null,
  character_name text,
  mode text not null check (mode in ('general', 'ic', 'ooc')),
  content text not null check (
    char_length(content) between 1 and 2000
    and char_length(btrim(content)) > 0
  ),
  created_at timestamptz not null default now()
);

create index chat_messages_room_created_at_idx
on public.chat_messages (room_id, created_at, id);

create index chat_messages_sender_id_idx
on public.chat_messages (sender_id);

create index chat_messages_character_id_idx
on public.chat_messages (character_id);

alter table public.chat_messages enable row level security;

revoke all on table public.chat_messages from anon, authenticated;
grant select on table public.chat_messages to authenticated;
grant select on table public.profiles to authenticated;

create policy chat_messages_select_active_members
on public.chat_messages
for select
to authenticated
using ((select public.is_active_room_member(room_id)));

create function public.send_chat_message(
  target_room_id uuid,
  message_mode text,
  message_content text,
  target_character_id uuid default null
)
returns public.chat_messages
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_id uuid := (select auth.uid());
  caller_role text;
  speaking_character_name text;
  created_message public.chat_messages;
begin
  if caller_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  select role
  into caller_role
  from public.room_members
  where room_id = target_room_id
    and user_id = caller_id
    and role in ('master', 'player')
    and status = 'active';

  if caller_role is null then
    raise exception 'chat permission required' using errcode = '42501';
  end if;

  if message_mode is null or message_mode not in ('general', 'ic', 'ooc') then
    raise exception 'invalid chat mode' using errcode = '22023';
  end if;

  if message_content is null
    or char_length(message_content) not between 1 and 2000
    or char_length(btrim(message_content)) = 0 then
    raise exception 'message content must be 1 to 2000 characters' using errcode = '22023';
  end if;

  if target_character_id is not null then
    select name
    into speaking_character_name
    from public.character_sheets
    where id = target_character_id
      and room_id = target_room_id
      and (owner_id = caller_id or caller_role = 'master');

    if speaking_character_name is null then
      raise exception 'speaking character permission required' using errcode = '42501';
    end if;
  end if;

  insert into public.chat_messages (
    room_id,
    sender_id,
    character_id,
    character_name,
    mode,
    content
  ) values (
    target_room_id,
    caller_id,
    target_character_id,
    speaking_character_name,
    message_mode,
    message_content
  )
  returning * into created_message;

  return created_message;
end;
$$;

revoke all on function public.send_chat_message(uuid, text, text, uuid) from public;
revoke all on function public.send_chat_message(uuid, text, text, uuid) from anon;
grant execute on function public.send_chat_message(uuid, text, text, uuid) to authenticated;

alter publication supabase_realtime add table public.chat_messages;
