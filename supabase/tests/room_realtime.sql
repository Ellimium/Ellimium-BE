begin;

select plan(11);

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, confirmation_token, email_change,
  recovery_token, email_change_token_new
) values
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000050', 'authenticated', 'authenticated', 'realtime-owner@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"실시간방장"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000051', 'authenticated', 'authenticated', 'realtime-member@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"실시간구성원"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000052', 'authenticated', 'authenticated', 'realtime-other@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"다른룸구성원"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000053', 'authenticated', 'authenticated', 'realtime-outsider@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"실시간외부인"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000054', 'authenticated', 'authenticated', null, '', now(), '{}', '{"nickname":"익명구성원"}', '', '', '', '');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000050', true);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000050","is_anonymous":false}', true);

create temporary table first_room as
select created.*
from public.create_room('실시간 첫 룸', null, 'D&D 5e') as created;

create temporary table second_room as
select created.*
from public.create_room('실시간 둘째 룸', null, 'D&D 5e') as created;

set local role postgres;
insert into public.room_members (room_id, user_id, role) values
  ((select id from first_room), '00000000-0000-0000-0000-000000000051', 'player'),
  ((select id from first_room), '00000000-0000-0000-0000-000000000054', 'player'),
  ((select id from second_room), '00000000-0000-0000-0000-000000000052', 'player');

insert into realtime.messages (topic, extension, payload, event, private) values
  ('room:' || (select id from first_room), 'broadcast', '{}', 'token-move', true),
  ('room:' || (select id from first_room), 'presence', '{}', 'sync', true),
  ('room:' || (select id from first_room), 'broadcast', '{}', 'public-event', false),
  ('room:' || (select id from second_room), 'broadcast', '{}', 'token-move', true);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000051', true);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000051","is_anonymous":false}', true);
select set_config('realtime.topic', 'room:' || (select id from first_room), true);

select results_eq(
  $$select count(*) from realtime.messages$$,
  $$values (2::bigint)$$,
  'active members receive only private broadcast and presence messages for their room'
);

select lives_ok(
  $$insert into realtime.messages (topic, extension, payload, event, private) values ((select realtime.topic()), 'broadcast', '{}', 'token-move', true)$$,
  'active members can send private broadcast messages to their room'
);

select set_config('realtime.topic', 'room:' || (select id from second_room), true);

select results_eq(
  $$select count(*) from realtime.messages$$,
  $$values (0::bigint)$$,
  'members cannot receive another room messages'
);

select throws_ok(
  $$insert into realtime.messages (topic, extension, payload, event, private) values ((select realtime.topic()), 'broadcast', '{}', 'token-move', true)$$,
  '42501',
  'new row violates row-level security policy for table "messages"',
  'members cannot send messages to another room'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000052', true);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000052","is_anonymous":false}', true);
select set_config('realtime.topic', 'room:' || (select id from second_room), true);

select results_eq(
  $$select count(*) from realtime.messages$$,
  $$values (1::bigint)$$,
  'other room members receive only their room messages'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000053', true);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000053","is_anonymous":false}', true);
select set_config('realtime.topic', 'room:' || (select id from first_room), true);

select results_eq(
  $$select count(*) from realtime.messages$$,
  $$values (0::bigint)$$,
  'non-members cannot receive room messages'
);

select throws_ok(
  $$insert into realtime.messages (topic, extension, payload, event, private) values ((select realtime.topic()), 'presence', '{}', 'track', true)$$,
  '42501',
  'new row violates row-level security policy for table "messages"',
  'non-members cannot send presence updates'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000054', true);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000054","is_anonymous":true}', true);
select set_config('realtime.topic', 'room:' || (select id from first_room), true);

select results_eq(
  $$select count(*) from realtime.messages$$,
  $$values (0::bigint)$$,
  'anonymous authenticated members cannot receive room messages'
);

select throws_ok(
  $$insert into realtime.messages (topic, extension, payload, event, private) values ((select realtime.topic()), 'presence', '{}', 'track', true)$$,
  '42501',
  'new row violates row-level security policy for table "messages"',
  'anonymous authenticated members cannot send presence updates'
);

set local role postgres;
update public.room_members
set status = 'left'
where room_id = (select id from first_room)
  and user_id = '00000000-0000-0000-0000-000000000051';

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000051', true);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000051","is_anonymous":false}', true);
select set_config('realtime.topic', 'room:' || (select id from first_room), true);

select results_eq(
  $$select count(*) from realtime.messages$$,
  $$values (0::bigint)$$,
  'departed members cannot receive room messages after reconnecting'
);

select throws_ok(
  $$insert into realtime.messages (topic, extension, payload, event, private) values ((select realtime.topic()), 'broadcast', '{}', 'token-move', true)$$,
  '42501',
  'new row violates row-level security policy for table "messages"',
  'departed members cannot send room messages after reconnecting'
);

select * from finish();

rollback;
