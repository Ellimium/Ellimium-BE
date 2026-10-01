create policy room_members_receive_realtime
on realtime.messages
for select
to authenticated
using (
  private
  and extension in ('broadcast', 'presence')
  and topic = (select realtime.topic())
  and coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) = false
  and exists (
    select 1
    from public.room_members
    where user_id = (select auth.uid())
      and status = 'active'
      and (select realtime.topic()) = 'room:' || room_id::text
  )
);

create policy room_members_send_realtime
on realtime.messages
for insert
to authenticated
with check (
  private
  and extension in ('broadcast', 'presence')
  and topic = (select realtime.topic())
  and coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) = false
  and exists (
    select 1
    from public.room_members
    where user_id = (select auth.uid())
      and status = 'active'
      and (select realtime.topic()) = 'room:' || room_id::text
  )
);
