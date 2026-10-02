begin;

select plan(52);

select has_table('public', 'chat_messages', 'chat messages table exists');
select col_is_pk('public', 'chat_messages', 'id', 'chat message id is the primary key');
select col_is_fk('public', 'chat_messages', 'room_id', 'chat message references its room');
select col_is_fk('public', 'chat_messages', 'sender_id', 'chat message references its sender');
select col_is_fk('public', 'chat_messages', 'character_id', 'chat message optionally references a character');
select has_column('public', 'chat_messages', 'character_name', 'chat messages preserve the speaking character name');
select has_column('public', 'chat_messages', 'message_type', 'chat messages distinguish chat and system messages');
select has_column('public', 'chat_messages', 'event_type', 'system messages identify their event type');
select has_column('public', 'chat_messages', 'event_data', 'system messages store structured event data');
select has_function(
  'public',
  'send_chat_message',
  array['uuid', 'text', 'text', 'uuid'],
  'chat message function exists'
);
select has_function(
  'private',
  'record_system_message',
  array['uuid', 'text', 'text', 'jsonb', 'uuid'],
  'internal system message function exists'
);
select has_function(
  'public',
  'send_system_notification',
  array['uuid', 'text'],
  'system notification function exists'
);
select ok(
  not (
    select prosecdef
    from pg_proc
    where oid = 'private.record_system_message(uuid, text, text, jsonb, uuid)'::regprocedure
  ),
  'the system message function runs with caller privileges'
);
select ok(
  (select relrowsecurity from pg_class where oid = 'public.chat_messages'::regclass),
  'chat messages use row level security'
);
select ok(
  has_table_privilege('authenticated', 'public.chat_messages', 'select'),
  'authenticated users can read authorized chat messages'
);
select ok(
  has_table_privilege('authenticated', 'public.profiles', 'select'),
  'authenticated room members can read sender profiles through RLS'
);
select ok(
  not has_table_privilege('authenticated', 'public.chat_messages', 'insert'),
  'authenticated users cannot spoof chat messages with direct inserts'
);
select ok(
  not has_table_privilege('anon', 'public.chat_messages', 'select'),
  'anonymous users cannot read chat messages'
);
select ok(
  has_function_privilege(
    'authenticated',
    'public.send_chat_message(uuid, text, text, uuid)',
    'execute'
  ),
  'authenticated users can call the chat message function'
);
select ok(
  not has_function_privilege(
    'anon',
    'public.send_chat_message(uuid, text, text, uuid)',
    'execute'
  ),
  'anonymous users cannot call the chat message function'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'private.record_system_message(uuid, text, text, jsonb, uuid)',
    'execute'
  ),
  'authenticated users cannot call the system message function'
);
select ok(
  not has_function_privilege(
    'anon',
    'private.record_system_message(uuid, text, text, jsonb, uuid)',
    'execute'
  ),
  'anonymous users cannot call the system message function'
);
select ok(
  has_function_privilege(
    'authenticated',
    'public.send_system_notification(uuid, text)',
    'execute'
  ),
  'authenticated users can call the system notification function'
);
select ok(
  not has_function_privilege(
    'anon',
    'public.send_system_notification(uuid, text)',
    'execute'
  ),
  'anonymous users cannot call the system notification function'
);
select results_eq(
  $$select count(*) from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'chat_messages'$$,
  $$values (1::bigint)$$,
  'chat messages publish Postgres changes'
);

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, confirmation_token, email_change,
  recovery_token, email_change_token_new
) values
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000e0', 'authenticated', 'authenticated', 'chat-master@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"채팅마스터"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000e1', 'authenticated', 'authenticated', 'chat-player@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"채팅플레이어"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000e2', 'authenticated', 'authenticated', 'chat-peer@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"채팅동료"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000e3', 'authenticated', 'authenticated', 'chat-spectator@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"채팅관전자"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000e4', 'authenticated', 'authenticated', 'chat-outsider@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"채팅외부인"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000e5', 'authenticated', 'authenticated', 'other-chat-master@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"다른룸마스터"}', '', '', '', '');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000e0', true);

create temporary table test_room as
select created.* from public.create_room('채팅 테스트 룸', null, 'D&D 5e') as created;

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000e5', true);

create temporary table other_room as
select created.* from public.create_room('다른 채팅 룸', null, 'CoC 7th') as created;

set local role postgres;

insert into public.room_members (room_id, user_id, role) values
  ((select id from test_room), '00000000-0000-0000-0000-0000000000e1', 'player'),
  ((select id from test_room), '00000000-0000-0000-0000-0000000000e2', 'player'),
  ((select id from test_room), '00000000-0000-0000-0000-0000000000e3', 'spectator');

insert into public.character_sheets (id, room_id, owner_id, name, system) values
  ('00000000-0000-0000-0000-0000000000f1', (select id from test_room), '00000000-0000-0000-0000-0000000000e1', '플레이어 캐릭터', 'custom'),
  ('00000000-0000-0000-0000-0000000000f2', (select id from test_room), '00000000-0000-0000-0000-0000000000e2', '동료 캐릭터', 'custom'),
  ('00000000-0000-0000-0000-0000000000f3', (select id from other_room), '00000000-0000-0000-0000-0000000000e5', '다른 룸 캐릭터', 'custom');

insert into public.chat_messages (room_id, sender_id, mode, content, created_at) values
  ((select id from test_room), '00000000-0000-0000-0000-0000000000e0', 'general', '먼저 저장된 메시지', '2026-01-01 00:00:00+00'),
  ((select id from test_room), '00000000-0000-0000-0000-0000000000e0', 'general', '나중에 저장된 메시지', '2026-01-02 00:00:00+00');

create temporary table returned_system_message as
select * from private.record_system_message(
  (select id from test_room),
  'notification',
  '세션이 곧 시작됩니다.',
  '{"level":"info"}'::jsonb
);

select ok(
  exists (
    select 1
    from returned_system_message as returned
    join public.chat_messages as stored using (id)
    where returned.room_id = (select id from test_room)
      and returned.sender_id is null
      and returned.character_id is null
      and returned.character_name is null
      and returned.mode = 'general'
      and returned.content = '세션이 곧 시작됩니다.'
      and returned.message_type = 'system'
      and returned.event_type = 'notification'
      and returned.event_data = '{"level":"info"}'::jsonb
      and returned.message_type = stored.message_type
      and returned.event_type = stored.event_type
      and returned.event_data = stored.event_data
  ),
  'the internal function stores a structured system message'
);

select throws_ok(
  $$select private.record_system_message((select id from test_room), 'unknown', '잘못된 이벤트')$$,
  '22023',
  'invalid system event type',
  'unknown system event types are rejected'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000e1', true);

select results_eq(
  $$select message_type, event_type, event_data from public.chat_messages where event_type = 'notification'$$,
  $$values ('system'::text, 'notification'::text, '{"level":"info"}'::jsonb)$$,
  'active members can read system messages in their room'
);

select throws_ok(
  $$select private.record_system_message((select id from test_room), 'notification', '위조된 시스템 메시지')$$,
  '42501',
  'permission denied for schema private',
  'authenticated users cannot record system messages'
);

select throws_ok(
  $$select public.send_system_notification((select id from test_room), '권한 없는 알림')$$,
  '42501',
  'master role required',
  'players cannot send system notifications'
);

create temporary table returned_message as
select * from public.send_chat_message(
  (select id from test_room),
  'general',
  '안녕하세요 👋 https://example.com'
);

select pass('players can send general chat messages');

select ok(
  exists (
    select 1
    from returned_message as returned
    join public.chat_messages as stored using (id)
    where returned.room_id = (select id from test_room)
      and returned.sender_id = '00000000-0000-0000-0000-0000000000e1'
      and returned.character_id is null
      and returned.character_name is null
      and returned.mode = 'general'
      and returned.content = '안녕하세요 👋 https://example.com'
      and returned.created_at is not null
      and returned.room_id = stored.room_id
      and returned.sender_id = stored.sender_id
      and returned.mode = stored.mode
      and returned.content = stored.content
      and returned.created_at = stored.created_at
  ),
  'the authenticated sender and returned message match the stored row'
);

select results_eq(
  $$select character_id, character_name from public.send_chat_message((select id from test_room), 'ic', '우리가 먼저 간다.', '00000000-0000-0000-0000-0000000000f1')$$,
  $$values ('00000000-0000-0000-0000-0000000000f1'::uuid, '플레이어 캐릭터'::text)$$,
  'players can speak as their own character and preserve its visible name'
);

select lives_ok(
  $$select public.send_chat_message((select id from test_room), 'ooc', repeat('가', 2000))$$,
  'messages at the 2000 character limit are accepted'
);

select throws_ok(
  $$select public.send_chat_message((select id from test_room), 'general', repeat('가', 2001))$$,
  '22023',
  'message content must be 1 to 2000 characters',
  'messages over 2000 characters are rejected'
);

select throws_ok(
  $$select public.send_chat_message((select id from test_room), 'general', '   ')$$,
  '22023',
  'message content must be 1 to 2000 characters',
  'blank messages are rejected'
);

select throws_ok(
  $$select public.send_chat_message((select id from test_room), 'system', '위조된 시스템 메시지')$$,
  '22023',
  'invalid chat mode',
  'unsupported chat modes are rejected'
);

select throws_ok(
  $$select public.send_chat_message((select id from test_room), 'ic', '동료 위조', '00000000-0000-0000-0000-0000000000f2')$$,
  '42501',
  'speaking character permission required',
  'players cannot speak as another players character'
);

select throws_ok(
  $$select public.send_chat_message((select id from test_room), 'ic', '다른 룸 위조', '00000000-0000-0000-0000-0000000000f3')$$,
  '42501',
  'speaking character permission required',
  'players cannot speak as characters from another room'
);

select throws_ok(
  $$insert into public.chat_messages (room_id, sender_id, mode, content) values ((select id from test_room), '00000000-0000-0000-0000-0000000000e2', 'general', '발신자 위조')$$,
  '42501',
  'permission denied for table chat_messages',
  'players cannot spoof senders with direct inserts'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000e0', true);

select results_eq(
  $$select event_type, content, event_data ->> 'created_by' from public.send_system_notification((select id from test_room), '마스터 공지')$$,
  $$values ('notification'::text, '마스터 공지'::text, '00000000-0000-0000-0000-0000000000e0'::text)$$,
  'masters can send system notifications'
);

select throws_ok(
  $$select public.send_system_notification((select id from test_room), '   ')$$,
  '22023',
  'message content must be 1 to 2000 characters',
  'blank system notifications are rejected'
);

select lives_ok(
  $$select public.send_chat_message((select id from test_room), 'ic', '마스터 발언', '00000000-0000-0000-0000-0000000000f1')$$,
  'masters can speak as a character in their room'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000e3', true);

select results_eq(
  $$select count(*) from public.chat_messages$$,
  $$values (12::bigint)$$,
  'spectators can read every stored message in their room'
);

select results_eq(
  $$select content from public.chat_messages where content like '%저장된 메시지' order by created_at, id$$,
  $$values ('먼저 저장된 메시지'::text), ('나중에 저장된 메시지')$$,
  'stored messages can be requeried in chronological order'
);

select throws_ok(
  $$select public.send_chat_message((select id from test_room), 'general', '관전자 발언')$$,
  '42501',
  'chat permission required',
  'spectators cannot send chat messages'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000e4', true);

select results_eq(
  $$select count(*) from public.chat_messages$$,
  $$values (0::bigint)$$,
  'non-members cannot read chat messages'
);

select throws_ok(
  $$select public.send_chat_message((select id from test_room), 'general', '외부인 발언')$$,
  '42501',
  'chat permission required',
  'non-members cannot send chat messages'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000e5', true);

select lives_ok(
  $$select public.send_chat_message((select id from other_room), 'general', '다른 룸 메시지')$$,
  'members can send chat messages in their own room'
);

select results_eq(
  $$select content from public.chat_messages where message_type = 'chat' order by created_at, id$$,
  $$values ('다른 룸 메시지'::text)$$,
  'members cannot read messages from another room'
);

set local role postgres;
update public.room_members
set status = 'left'
where room_id = (select id from test_room)
  and user_id = '00000000-0000-0000-0000-0000000000e1';

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000e1', true);

select results_eq(
  $$select count(*) from public.chat_messages$$,
  $$values (0::bigint)$$,
  'departed members cannot requery chat history'
);

select throws_ok(
  $$select public.send_chat_message((select id from test_room), 'general', '퇴장 후 발언')$$,
  '42501',
  'chat permission required',
  'departed members cannot send chat messages'
);

select * from finish();

rollback;
