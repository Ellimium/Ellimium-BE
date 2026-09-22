begin;

select plan(15);

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, confirmation_token, email_change,
  recovery_token, email_change_token_new
) values
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000050', 'authenticated', 'authenticated', 'member-manager@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"마스터"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000051', 'authenticated', 'authenticated', 'managed-member@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"구성원"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000052', 'authenticated', 'authenticated', 'member-outsider@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"외부인"}', '', '', '', '');

select ok(
  has_function_privilege('authenticated', 'public.set_room_member_role(uuid, uuid, text)', 'execute'),
  'authenticated users can set room member roles'
);

select ok(
  not has_function_privilege('anon', 'public.set_room_member_role(uuid, uuid, text)', 'execute'),
  'anonymous users cannot set room member roles'
);

select ok(
  has_function_privilege('authenticated', 'public.force_remove_room_member(uuid, uuid)', 'execute'),
  'authenticated users can force-remove room members'
);

select ok(
  not has_function_privilege('anon', 'public.force_remove_room_member(uuid, uuid)', 'execute'),
  'anonymous users cannot force-remove room members'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000050', true);

create temporary table test_room as
select (public.create_room('구성원 관리 테스트 룸', null, 'D&D 5e')).*;

set local role postgres;
insert into public.room_members (room_id, user_id, role)
select id, '00000000-0000-0000-0000-000000000051', 'player' from test_room;

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000050', true);

select lives_ok(
  $$select public.set_room_member_role((select id from test_room), '00000000-0000-0000-0000-000000000051', 'spectator')$$,
  'masters can change participant roles'
);

select results_eq(
  $$select role from public.room_members where room_id = (select id from test_room) and user_id = '00000000-0000-0000-0000-000000000051'$$,
  $$values ('spectator'::text)$$,
  'role changes are persisted'
);

select throws_ok(
  $$select public.set_room_member_role((select id from test_room), '00000000-0000-0000-0000-000000000051', 'invalid')$$,
  '22023',
  'role must be master, player, or spectator',
  'roles are limited to master, player, or spectator'
);

select throws_ok(
  $$select public.set_room_member_role((select id from test_room), '00000000-0000-0000-0000-000000000050', 'player')$$,
  '22023',
  'masters cannot change their own role',
  'masters cannot remove their own role'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000051', true);

select throws_ok(
  $$select public.set_room_member_role((select id from test_room), '00000000-0000-0000-0000-000000000050', 'spectator')$$,
  '42501',
  'master role required',
  'non-masters cannot change participant roles'
);

select throws_ok(
  $$select public.force_remove_room_member((select id from test_room), '00000000-0000-0000-0000-000000000050')$$,
  '42501',
  'master role required',
  'non-masters cannot force-remove participants'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000050', true);

select throws_ok(
  $$select public.force_remove_room_member((select id from test_room), '00000000-0000-0000-0000-000000000050')$$,
  '22023',
  'masters cannot force-remove themselves',
  'masters cannot force-remove themselves'
);

select lives_ok(
  $$select public.force_remove_room_member((select id from test_room), '00000000-0000-0000-0000-000000000051')$$,
  'masters can force-remove participants'
);

set local role postgres;

select results_eq(
  $$select status from public.room_members where room_id = (select id from test_room) and user_id = '00000000-0000-0000-0000-000000000051'$$,
  $$values ('removed'::text)$$,
  'force removal changes the participant status'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000051', true);

select results_eq(
  $$select count(*) from public.room_members where room_id = (select id from test_room)$$,
  $$values (0::bigint)$$,
  'force-removed users are excluded from common member access'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000050', true);

select results_eq(
  $$select user_id from public.room_members where room_id = (select id from test_room) order by user_id$$,
  $$values ('00000000-0000-0000-0000-000000000050'::uuid)$$,
  'active members no longer see force-removed participants'
);

select * from finish();

rollback;
