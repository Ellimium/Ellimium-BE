begin;

select plan(12);

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, confirmation_token, email_change,
  recovery_token, email_change_token_new
) values
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000030', 'authenticated', 'authenticated', 'room-owner@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"방장님"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000031', 'authenticated', 'authenticated', 'room-member@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"구성원"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000032', 'authenticated', 'authenticated', 'room-outsider@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"외부인"}', '', '', '', '');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000030', true);

create temporary table test_room as
select (public.create_room('공유 룸', '테스트 룸', 'D&D 5e')).*;

select results_eq(
  $$select role || ':' || status from public.room_members where room_id = (select id from test_room)$$,
  $$values ('master:active'::text)$$,
  'room creator becomes the active master'
);

select throws_ok(
  $$select public.create_room(' ', null, 'D&D 5e')$$,
  '22023',
  'room name must be 1 to 50 characters',
  'room name is validated by the creation function'
);

select lives_ok(
  $$select public.create_room('공유 룸', null, 'D&D 5e')$$,
  'duplicate room names are allowed'
);

set local role postgres;
insert into public.room_members (room_id, user_id, role)
select id, '00000000-0000-0000-0000-000000000031', 'player' from test_room;
insert into storage.objects (bucket_id, name) values
  ('avatars', '00000000-0000-0000-0000-000000000030/avatar'),
  ('avatars', '00000000-0000-0000-0000-000000000031/avatar'),
  ('avatars', '00000000-0000-0000-0000-000000000032/avatar');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000030', true);

select results_eq(
  $$select name from public.rooms where id = (select id from test_room)$$,
  $$values ('공유 룸'::text)$$,
  'active masters can read their rooms'
);

select results_eq(
  $$update public.rooms set name = '변경된 룸' where id = (select id from test_room) returning name$$,
  $$values ('변경된 룸'::text)$$,
  'active masters can update their rooms'
);

select results_eq(
  $$select user_id from public.profiles order by user_id$$,
  $$values ('00000000-0000-0000-0000-000000000030'::uuid), ('00000000-0000-0000-0000-000000000031'::uuid)$$,
  'active room members can read each other profiles'
);

select results_eq(
  $$select name from storage.objects where bucket_id = 'avatars' order by name$$,
  $$values ('00000000-0000-0000-0000-000000000030/avatar'::text), ('00000000-0000-0000-0000-000000000031/avatar'::text)$$,
  'active room members can read each other avatars'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000032', true);

select results_eq(
  $$select count(*) from public.rooms$$,
  $$values (0::bigint)$$,
  'outsiders cannot read rooms'
);

select results_eq(
  $$update public.rooms set name = '침입' where id = (select id from test_room) returning id$$,
  $$select null::uuid where false$$,
  'outsiders cannot update rooms'
);

set local role postgres;
update public.room_members set status = 'left'
where room_id = (select id from test_room)
  and user_id = '00000000-0000-0000-0000-000000000031';

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000030', true);

select results_eq(
  $$select user_id from public.profiles order by user_id$$,
  $$values ('00000000-0000-0000-0000-000000000030'::uuid)$$,
  'departed members profiles are hidden'
);

select results_eq(
  $$select name from storage.objects where bucket_id = 'avatars' order by name$$,
  $$values ('00000000-0000-0000-0000-000000000030/avatar'::text)$$,
  'departed members avatars are hidden'
);

set local role anon;
select set_config('request.jwt.claim.sub', '', true);

select results_eq(
  $$select (select count(*) from public.rooms), (select count(*) from public.profiles), (select count(*) from storage.objects where bucket_id = 'avatars')$$,
  $$values (0::bigint, 0::bigint, 0::bigint)$$,
  'anonymous users cannot read rooms, profiles, or avatars'
);

select * from finish();

rollback;
