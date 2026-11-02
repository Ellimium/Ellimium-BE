drop policy room_members_receive_drawing_changes on realtime.messages;

create policy room_members_receive_drawing_changes
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
      and (select public.can_use_room_feature(room_id, 'map_view'))
      and (select realtime.topic()) = 'room:' || room_id::text || ':drawings'
  )
);
