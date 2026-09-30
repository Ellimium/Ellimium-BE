drop policy room_members_receive_token_movement on realtime.messages;

create policy room_members_receive_token_movement
on realtime.messages
for select
to authenticated
using (
  extension = 'broadcast'
  and topic = (select realtime.topic())
  and coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) = false
  and exists (
    select 1
    from public.room_members
    where user_id = (select auth.uid())
      and status = 'active'
      and (select realtime.topic()) = 'room:' || room_id::text || ':tokens'
  )
);

drop policy token_controllers_send_movement on realtime.messages;

create policy token_controllers_send_movement
on realtime.messages
for insert
to authenticated
with check (
  extension = 'broadcast'
  and topic = (select realtime.topic())
  and coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) = false
  and exists (
    select 1
    from public.room_members
    where user_id = (select auth.uid())
      and status = 'active'
      and role in ('master', 'player')
      and (select realtime.topic()) = 'room:' || room_id::text || ':tokens'
  )
);
