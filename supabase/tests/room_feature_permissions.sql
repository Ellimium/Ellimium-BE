begin;

select plan(39);

select has_table(
  'public',
  'room_feature_permissions',
  'room feature permissions table exists'
);
select has_function(
  'public',
  'can_use_room_feature',
  array['uuid', 'text'],
  'common room feature permission function exists'
);
select has_function(
  'public',
  'set_room_feature_permission',
  array['uuid', 'text', 'boolean', 'text', 'uuid'],
  'room feature permission setter exists'
);

select ok(
  has_table_privilege('authenticated', 'public.room_feature_permissions', 'select'),
  'authenticated users can read authorized permission rows'
);
select ok(
  not has_table_privilege('authenticated', 'public.room_feature_permissions', 'insert'),
  'authenticated users cannot bypass the permission setter'
);
select ok(
  has_function_privilege('authenticated', 'public.can_use_room_feature(uuid, text)', 'execute'),
  'authenticated users can evaluate their feature permissions'
);
select ok(
  has_function_privilege('authenticated', 'public.set_room_feature_permission(uuid, text, boolean, text, uuid)', 'execute'),
  'authenticated users can request permission changes'
);
select ok(
  not has_function_privilege('anon', 'public.set_room_feature_permission(uuid, text, boolean, text, uuid)', 'execute'),
  'anonymous users cannot request permission changes'
);
select results_eq(
  $$select count(*) from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'room_feature_permissions'$$,
  $$values (1::bigint)$$,
  'permission changes are published to Realtime'
);

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, confirmation_token, email_change,
  recovery_token, email_change_token_new
) values
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000f0', 'authenticated', 'authenticated', 'feature-master@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"권한마스터"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000f1', 'authenticated', 'authenticated', 'feature-player@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"권한플레이어"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000f2', 'authenticated', 'authenticated', 'feature-spectator@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"권한관전자"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000f3', 'authenticated', 'authenticated', 'feature-outsider@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"권한외부인"}', '', '', '', '');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f0', true);

create temporary table test_room as
select created.*
from public.create_room('기능 권한 테스트 룸', null, 'D&D 5e') as created;

select results_eq(
  $$select feature, role, allowed from public.room_feature_permissions where room_id = (select id from test_room) order by role, feature$$,
  $$values
    ('chat'::text, 'player'::text, true),
    ('dice'::text, 'player'::text, true),
    ('drawing'::text, 'player'::text, false),
    ('map_view'::text, 'player'::text, true),
    ('token_move'::text, 'player'::text, true),
    ('chat'::text, 'spectator'::text, false),
    ('dice'::text, 'spectator'::text, false),
    ('drawing'::text, 'spectator'::text, false),
    ('map_view'::text, 'spectator'::text, true),
    ('token_move'::text, 'spectator'::text, false)$$,
  'new rooms store role defaults for every configurable feature'
);

select results_eq(
  $$select feature, public.can_use_room_feature((select id from test_room), feature) from unnest(array['chat', 'dice', 'drawing', 'map_view', 'token_move']) as feature order by feature$$,
  $$values
    ('chat'::text, true),
    ('dice'::text, true),
    ('drawing'::text, true),
    ('map_view'::text, true),
    ('token_move'::text, true)$$,
  'masters always have every room feature permission'
);

set local role postgres;

insert into public.room_members (room_id, user_id, role) values
  ((select id from test_room), '00000000-0000-0000-0000-0000000000f1', 'player'),
  ((select id from test_room), '00000000-0000-0000-0000-0000000000f2', 'spectator');

insert into public.assets (id, owner_id, category, storage_path)
values (
  '00000000-0000-0000-0000-0000000000f4',
  '00000000-0000-0000-0000-0000000000f0',
  'map',
  '00000000-0000-0000-0000-0000000000f0/feature-map.png'
);

insert into storage.objects (bucket_id, name)
values ('assets', '00000000-0000-0000-0000-0000000000f0/feature-map.png');

insert into public.room_maps (id, room_id, asset_id)
values (
  '00000000-0000-0000-0000-0000000000f5',
  (select id from test_room),
  '00000000-0000-0000-0000-0000000000f4'
);

insert into public.room_tokens (id, map_id, owner_id, name)
values (
  '00000000-0000-0000-0000-0000000000f6',
  '00000000-0000-0000-0000-0000000000f5',
  '00000000-0000-0000-0000-0000000000f1',
  '권한 테스트 토큰'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f0', true);

select lives_ok(
  $$select public.set_room_feature_permission((select id from test_room), 'chat', false, 'player', null)$$,
  'masters can change role permissions'
);
select lives_ok(
  $$select public.set_room_feature_permission((select id from test_room), 'chat', true, null, '00000000-0000-0000-0000-0000000000f1')$$,
  'masters can add participant permission overrides'
);
select lives_ok(
  $$select public.set_room_feature_permission((select id from test_room), 'dice', false, 'player', null)$$,
  'masters can deny a second role feature'
);
select lives_ok(
  $$select public.set_room_feature_permission((select id from test_room), 'map_view', false, 'player', null)$$,
  'masters can deny map viewing'
);
select lives_ok(
  $$select public.set_room_feature_permission((select id from test_room), 'token_move', false, 'player', null)$$,
  'masters can deny token movement'
);

select throws_ok(
  $$select public.set_room_feature_permission((select id from test_room), 'invalid', true, 'player', null)$$,
  '22023',
  'invalid room feature',
  'only supported room features can be configured'
);
select throws_ok(
  $$select public.set_room_feature_permission((select id from test_room), 'chat', true, 'player', '00000000-0000-0000-0000-0000000000f1')$$,
  '22023',
  'exactly one permission target is required',
  'role and participant targets cannot be combined'
);
select throws_ok(
  $$select public.set_room_feature_permission((select id from test_room), 'chat', true, null, '00000000-0000-0000-0000-0000000000f0')$$,
  '22023',
  'active non-master room member required',
  'master permissions cannot be overridden'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f1', true);

select results_eq(
  $$select feature, public.can_use_room_feature((select id from test_room), feature) from unnest(array['chat', 'dice', 'drawing', 'map_view', 'token_move']) as feature order by feature$$,
  $$values
    ('chat'::text, true),
    ('dice'::text, false),
    ('drawing'::text, false),
    ('map_view'::text, false),
    ('token_move'::text, false)$$,
  'participant overrides take precedence over changed role permissions'
);

select results_eq(
  $$select count(*) from public.room_feature_permissions where room_id = (select id from test_room)$$,
  $$values (11::bigint)$$,
  'active members can read role settings and participant overrides'
);

select lives_ok(
  $$select public.send_chat_message((select id from test_room), 'general', '참가자 예외 허용')$$,
  'a participant override can allow chat'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f0', true);
select public.set_room_feature_permission(
  (select id from test_room),
  'chat',
  false,
  null,
  '00000000-0000-0000-0000-0000000000f1'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f1', true);

select throws_ok(
  $$select public.send_chat_message((select id from test_room), 'general', '거부되어야 하는 메시지')$$,
  '42501',
  'chat permission required',
  'denied players cannot send chat messages'
);

select results_eq(
  $$select count(*) from public.chat_messages where room_id = (select id from test_room)$$,
  $$values (4::bigint)$$,
  'chat denial preserves read-only access to room records'
);

select throws_ok(
  $$select public.roll_dice((select id from test_room), '1d6')$$,
  '42501',
  'dice roll permission required',
  'denied players cannot roll dice'
);

select results_eq(
  $$select (select count(*) from public.room_maps), (select count(*) from public.assets where id = '00000000-0000-0000-0000-0000000000f4'), (select count(*) from storage.objects where bucket_id = 'assets' and name = '00000000-0000-0000-0000-0000000000f0/feature-map.png')$$,
  $$values (0::bigint, 0::bigint, 0::bigint)$$,
  'map denial hides map rows, linked asset metadata, and storage objects'
);

select results_eq(
  $$update public.room_tokens set x = 10, y = 20 where id = '00000000-0000-0000-0000-0000000000f6' returning x, y$$,
  $$select 0::numeric, 0::numeric where false$$,
  'denied players cannot move their tokens'
);

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000f1","is_anonymous":false}', true);
select set_config('realtime.topic', 'room:' || (select id from test_room) || ':tokens', true);

select throws_ok(
  $$insert into realtime.messages (topic, extension, payload, event, private) values ((select realtime.topic()), 'broadcast', '{}', 'token-move', true)$$,
  '42501',
  'new row violates row-level security policy for table "messages"',
  'token movement denial applies to Realtime broadcasts'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f0', true);

select lives_ok(
  $$select public.set_room_feature_permission((select id from test_room), 'dice', true, null, '00000000-0000-0000-0000-0000000000f1')$$,
  'masters can allow dice for one participant'
);
select lives_ok(
  $$select public.set_room_feature_permission((select id from test_room), 'map_view', true, null, '00000000-0000-0000-0000-0000000000f1')$$,
  'masters can allow map viewing for one participant'
);
select lives_ok(
  $$select public.set_room_feature_permission((select id from test_room), 'token_move', true, null, '00000000-0000-0000-0000-0000000000f1')$$,
  'masters can allow token movement for one participant'
);
select lives_ok(
  $$select public.set_room_feature_permission((select id from test_room), 'drawing', true, null, '00000000-0000-0000-0000-0000000000f1')$$,
  'masters can allow drawing for one participant'
);
select public.set_room_feature_permission(
  (select id from test_room),
  'chat',
  true,
  null,
  '00000000-0000-0000-0000-0000000000f1'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f1', true);

select results_eq(
  $$select feature, public.can_use_room_feature((select id from test_room), feature) from unnest(array['chat', 'dice', 'drawing', 'map_view', 'token_move']) as feature order by feature$$,
  $$values
    ('chat'::text, true),
    ('dice'::text, true),
    ('drawing'::text, true),
    ('map_view'::text, true),
    ('token_move'::text, true)$$,
  'participant overrides can allow every configurable feature'
);

select results_eq(
  $$select (select count(*) from public.room_maps), (select count(*) from public.assets where id = '00000000-0000-0000-0000-0000000000f4'), (select count(*) from storage.objects where bucket_id = 'assets' and name = '00000000-0000-0000-0000-0000000000f0/feature-map.png')$$,
  $$values (1::bigint, 1::bigint, 1::bigint)$$,
  'map permission restores DB and Storage reads'
);

select results_eq(
  $$update public.room_tokens set x = 10, y = 20 where id = '00000000-0000-0000-0000-0000000000f6' returning x, y$$,
  $$values (10::numeric, 20::numeric)$$,
  'token movement permission restores owned token updates'
);

select lives_ok(
  $$select public.roll_dice((select id from test_room), '1d6')$$,
  'dice permission restores dice rolls'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f2', true);

select results_eq(
  $$select feature, public.can_use_room_feature((select id from test_room), feature) from unnest(array['chat', 'dice', 'drawing', 'map_view', 'token_move']) as feature order by feature$$,
  $$values
    ('chat'::text, false),
    ('dice'::text, false),
    ('drawing'::text, false),
    ('map_view'::text, true),
    ('token_move'::text, false)$$,
  'spectators default to map-only access'
);

select throws_ok(
  $$select public.set_room_feature_permission((select id from test_room), 'chat', true, 'spectator', null)$$,
  '42501',
  'master role required',
  'non-masters cannot change feature permissions'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f3', true);

select results_eq(
  $$select public.can_use_room_feature((select id from test_room), 'map_view'), (select count(*) from public.room_feature_permissions where room_id = (select id from test_room))$$,
  $$values (false, 0::bigint)$$,
  'outsiders cannot use room features or read permission settings'
);

select * from finish();

rollback;
