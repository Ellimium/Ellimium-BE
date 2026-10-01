begin;

select plan(16);

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, confirmation_token, email_change,
  recovery_token, email_change_token_new
) values
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000040', 'authenticated', 'authenticated', 'join-owner@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"참가방장"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000041', 'authenticated', 'authenticated', 'join-member@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"참가회원"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000042', 'authenticated', 'authenticated', 'join-outsider@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"참가외부인"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000043', 'authenticated', 'authenticated', null, '', now(), '{}', '{"nickname":"익명회원"}', '', '', '', '');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000040', true);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000040","is_anonymous":false}', true);

create temporary table test_room as
select created.*
from public.create_room('참가 테스트 룸', null, 'D&D 5e') as created;

set local role postgres;
insert into storage.objects (bucket_id, name) values
  ('avatars', '00000000-0000-0000-0000-000000000040/avatar'),
  ('avatars', '00000000-0000-0000-0000-000000000041/avatar');

select ok(
  has_function_privilege('authenticated', 'public.join_room(text)', 'execute'),
  'authenticated users can execute join_room'
);

select ok(
  not has_function_privilege('anon', 'public.join_room(text)', 'execute'),
  'unauthenticated users cannot execute join_room'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000041', true);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000041","is_anonymous":false}', true);

select results_eq(
  $$select count(*) from public.rooms where id = (select id from test_room)$$,
  $$values (0::bigint)$$,
  'users cannot read a room before joining'
);

select results_eq(
  $$select count(*) from storage.objects where name = '00000000-0000-0000-0000-000000000040/avatar'$$,
  $$values (0::bigint)$$,
  'users cannot read another user avatar before joining'
);

select throws_ok(
  $$select public.join_room('not-a-valid-code')$$,
  '22023',
  'invalid invite code',
  'invalid invite codes are rejected'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000043', true);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000043","is_anonymous":true}', true);

select throws_ok(
  $$select public.join_room((select invite_code from test_room))$$,
  '42501',
  'registered account required',
  'anonymous authenticated users are rejected'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000041', true);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000041","is_anonymous":false}', true);

select results_eq(
  $$select public.join_room((select invite_code from test_room))$$,
  $$select id from test_room$$,
  'valid invite codes return the joined room id'
);

select results_eq(
  $$select role || ':' || status from public.room_members where room_id = (select id from test_room) and user_id = '00000000-0000-0000-0000-000000000041'$$,
  $$values ('player:active'::text)$$,
  'new members join as active players'
);

select results_eq(
  $$select name from public.rooms where id = (select id from test_room)$$,
  $$values ('참가 테스트 룸'::text)$$,
  'members can read the room after joining'
);

select results_eq(
  $$select name from storage.objects where name = '00000000-0000-0000-0000-000000000040/avatar'$$,
  $$values ('00000000-0000-0000-0000-000000000040/avatar'::text)$$,
  'members can read another member avatar after joining'
);

select results_eq(
  $$select count(*) from public.room_members where room_id = (select id from test_room)$$,
  $$values (2::bigint)$$,
  'members can read the active participant list after joining'
);

set local role postgres;
update public.room_members
set role = 'spectator', status = 'left'
where room_id = (select id from test_room)
  and user_id = '00000000-0000-0000-0000-000000000041';

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000041', true);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000041","is_anonymous":false}', true);
do $$
begin
  perform public.join_room((select invite_code from test_room));
end;
$$;

select results_eq(
  $$select role || ':' || status from public.room_members where room_id = (select id from test_room) and user_id = '00000000-0000-0000-0000-000000000041'$$,
  $$values ('spectator:active'::text)$$,
  'departed members rejoin without changing their role'
);

set local role postgres;
update public.room_members
set status = 'removed'
where room_id = (select id from test_room)
  and user_id = '00000000-0000-0000-0000-000000000041';

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000041', true);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000041","is_anonymous":false}', true);
do $$
begin
  perform public.join_room((select invite_code from test_room));
end;
$$;

select results_eq(
  $$select role || ':' || status from public.room_members where room_id = (select id from test_room) and user_id = '00000000-0000-0000-0000-000000000041'$$,
  $$values ('spectator:active'::text)$$,
  'removed members rejoin without changing their role'
);

do $$
begin
  perform public.join_room((select invite_code from test_room))
  from generate_series(1, 2);
end;
$$;

select results_eq(
  $$select count(*) from public.room_members where room_id = (select id from test_room) and user_id = '00000000-0000-0000-0000-000000000041'$$,
  $$values (1::bigint)$$,
  'duplicate join requests keep one membership row'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000042', true);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000042","is_anonymous":false}', true);

select results_eq(
  $$select count(*) from public.rooms where id = (select id from test_room)$$,
  $$values (0::bigint)$$,
  'non-members still cannot read the room'
);

select results_eq(
  $$select count(*) from storage.objects where name = '00000000-0000-0000-0000-000000000040/avatar'$$,
  $$values (0::bigint)$$,
  'non-members still cannot read member avatars'
);

select * from finish();

rollback;
