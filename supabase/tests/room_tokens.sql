begin;

select plan(37);

select has_table('public', 'room_tokens', 'room tokens table exists');
select col_is_pk('public', 'room_tokens', 'id', 'room token id is the primary key');
select col_is_fk('public', 'room_tokens', 'map_id', 'room token references its map');
select col_is_fk('public', 'room_tokens', 'owner_id', 'room token references its optional owner');
select col_is_fk('public', 'room_tokens', 'image_asset_id', 'room token references its optional image asset');

select results_eq(
  $$select count(*) from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'room_tokens'$$,
  $$values (1::bigint)$$,
  'room token changes are published to Realtime'
);

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, confirmation_token, email_change,
  recovery_token, email_change_token_new
) values
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000080', 'authenticated', 'authenticated', 'token-master@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"토큰마스터"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000081', 'authenticated', 'authenticated', 'token-player@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"토큰플레이어"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000082', 'authenticated', 'authenticated', 'token-spectator@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"토큰관전자"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000083', 'authenticated', 'authenticated', 'token-other@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"다른룸플레이어"}', '', '', '', '');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000080', true);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000080","is_anonymous":false}', true);

create temporary table test_room as
select created.*
from public.create_room('토큰 정책 테스트 룸', null, 'D&D 5e') as created;

create temporary table other_room as
select created.*
from public.create_room('다른 토큰 테스트 룸', null, 'D&D 5e') as created;

set local role postgres;

insert into public.room_members (room_id, user_id, role) values
  ((select id from test_room), '00000000-0000-0000-0000-000000000081', 'player'),
  ((select id from test_room), '00000000-0000-0000-0000-000000000082', 'spectator'),
  ((select id from other_room), '00000000-0000-0000-0000-000000000083', 'player'),
  ((select id from other_room), '00000000-0000-0000-0000-000000000081', 'player');

insert into public.assets (id, owner_id, category, storage_path) values
  ('00000000-0000-0000-0000-000000000090', '00000000-0000-0000-0000-000000000080', 'map', '00000000-0000-0000-0000-000000000080/map.png'),
  ('00000000-0000-0000-0000-000000000091', '00000000-0000-0000-0000-000000000080', 'token', '00000000-0000-0000-0000-000000000080/token.png'),
  ('00000000-0000-0000-0000-000000000092', '00000000-0000-0000-0000-000000000083', 'token', '00000000-0000-0000-0000-000000000083/token.png');

insert into storage.objects (bucket_id, name) values
  ('assets', '00000000-0000-0000-0000-000000000080/map.png'),
  ('assets', '00000000-0000-0000-0000-000000000080/token.png'),
  ('assets', '00000000-0000-0000-0000-000000000083/token.png');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000080', true);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000080","is_anonymous":false}', true);

insert into public.room_maps (id, room_id, asset_id)
values ('00000000-0000-0000-0000-0000000000b0', (select id from test_room), '00000000-0000-0000-0000-000000000090');

select lives_ok(
  $$insert into public.room_tokens (id, map_id, owner_id, image_asset_id, name, x, y, size) values ('00000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-000000000081', '00000000-0000-0000-0000-000000000091', '플레이어 토큰', 1.5, 2.5, 1)$$,
  'masters can create and assign tokens'
);

select results_eq(
  $$select name, x, y, size, owner_id, image_asset_id from public.room_tokens where id = '00000000-0000-0000-0000-0000000000a0'$$,
  $$values ('플레이어 토큰'::text, 1.5::numeric, 2.5::numeric, 1::numeric, '00000000-0000-0000-0000-000000000081'::uuid, '00000000-0000-0000-0000-000000000091'::uuid)$$,
  'token state is persisted'
);

select results_eq(
  $$update public.room_tokens set size = 2 where id = '00000000-0000-0000-0000-0000000000a0' returning size$$,
  $$values (2::numeric)$$,
  'masters can change every token'
);

select throws_ok(
  $$insert into public.room_tokens (map_id, owner_id, name) values ('00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-000000000082', '관전자 토큰')$$,
  '42501',
  null,
  'tokens cannot be assigned to spectators'
);

select throws_ok(
  $$insert into public.room_tokens (map_id, image_asset_id, name) values ('00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-000000000092', '다른 사용자 이미지 토큰')$$,
  '42501',
  null,
  'masters cannot link another users token assets'
);

select lives_ok(
  $$insert into public.room_tokens (id, map_id, name, x, y) values ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b0', '미할당 토큰', 3, 4)$$,
  'masters can create unassigned tokens'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000081', true);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000081","is_anonymous":false}', true);

select results_eq(
  $$select count(*) from public.room_tokens$$,
  $$values (2::bigint)$$,
  'players can read tokens in their room'
);

select results_eq(
  $$update public.room_tokens set x = 5, y = 6 where id = '00000000-0000-0000-0000-0000000000a0' returning x, y$$,
  $$values (5::numeric, 6::numeric)$$,
  'players can move their assigned token while keeping its masters image'
);

select results_eq(
  $$update public.room_tokens set x = 7 where id = '00000000-0000-0000-0000-0000000000a1' returning x$$,
  $$select null::numeric where false$$,
  'players cannot change unassigned tokens'
);

select throws_ok(
  $$insert into public.room_tokens (map_id, owner_id, name) values ('00000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-000000000081', '플레이어 생성 토큰')$$,
  '42501',
  null,
  'players cannot create tokens'
);

select results_eq(
  $$select storage_path from public.assets where id = '00000000-0000-0000-0000-000000000091'$$,
  $$values ('00000000-0000-0000-0000-000000000080/token.png'::text)$$,
  'room members can read linked token assets'
);

select results_eq(
  $$select name from storage.objects where bucket_id = 'assets' and name = '00000000-0000-0000-0000-000000000080/token.png'$$,
  $$values ('00000000-0000-0000-0000-000000000080/token.png'::text)$$,
  'room members can read linked token files'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000082', true);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000082","is_anonymous":false}', true);

select results_eq(
  $$select x, y from public.room_tokens where id = '00000000-0000-0000-0000-0000000000a0'$$,
  $$values (5::numeric, 6::numeric)$$,
  'spectators can requery the final token position'
);

select results_eq(
  $$update public.room_tokens set x = 9 where id = '00000000-0000-0000-0000-0000000000a0' returning x$$,
  $$select null::numeric where false$$,
  'spectators cannot change tokens'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000083', true);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000083","is_anonymous":false}', true);

select results_eq(
  $$select (select count(*) from public.room_tokens), (select count(*) from public.assets where id = '00000000-0000-0000-0000-000000000091'), (select count(*) from storage.objects where name = '00000000-0000-0000-0000-000000000080/token.png')$$,
  $$values (0::bigint, 0::bigint, 0::bigint)$$,
  'other room members cannot read tokens or their images'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000080', true);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000080","is_anonymous":false}', true);

-- Both maps must be otherwise valid destinations, so RLS cannot mask the regression.
set local role postgres;
insert into public.assets (id, owner_id, category, storage_path) values
  ('00000000-0000-0000-0000-000000000093', '00000000-0000-0000-0000-000000000080', 'map', '00000000-0000-0000-0000-000000000080/map-2.png');
insert into public.room_maps (id, room_id, asset_id) values
  ('00000000-0000-0000-0000-0000000000b1', (select id from test_room), '00000000-0000-0000-0000-000000000093'),
  ('00000000-0000-0000-0000-0000000000b2', (select id from other_room), '00000000-0000-0000-0000-000000000090');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000081', true);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000081","is_anonymous":false}', true);

select ok(
  public.can_use_room_feature((select id from test_room), 'map_view')
  and public.can_use_room_feature((select id from test_room), 'token_move')
  and public.can_use_room_feature((select id from other_room), 'map_view')
  and public.can_use_room_feature((select id from other_room), 'token_move'),
  'player has map and token permissions in both rooms'
);
select throws_ok(
  $$update public.room_tokens set map_id = '00000000-0000-0000-0000-0000000000b1' where id = '00000000-0000-0000-0000-0000000000a0'$$,
  '23514', 'room token map cannot be changed',
  'players cannot move an assigned token to another map in the same room'
);
select throws_ok(
  $$update public.room_tokens set map_id = '00000000-0000-0000-0000-0000000000b2' where id = '00000000-0000-0000-0000-0000000000a0'$$,
  '23514', 'room token map cannot be changed',
  'players cannot move an assigned token to another room'
);
select results_eq(
  $$select map_id, owner_id, image_asset_id from public.room_tokens where id = '00000000-0000-0000-0000-0000000000a0'$$,
  $$values ('00000000-0000-0000-0000-0000000000b0'::uuid, '00000000-0000-0000-0000-000000000081'::uuid, '00000000-0000-0000-0000-000000000091'::uuid)$$,
  'failed map changes preserve the original map, owner and image'
);
select results_eq(
  $$update public.room_tokens set map_id = '00000000-0000-0000-0000-0000000000b0', x = 7, y = 8 where id = '00000000-0000-0000-0000-0000000000a0' returning x, y$$,
  $$values (7::numeric, 8::numeric)$$,
  'players can move their token with an explicitly unchanged map'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000083', true);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000083","is_anonymous":false}', true);
select results_eq(
  $$select count(*) from public.room_tokens where id = '00000000-0000-0000-0000-0000000000a0'$$,
  $$values (0::bigint)$$,
  'the token does not appear for target-room-only members'
);
select results_eq(
  $$select count(*) from public.assets where id = '00000000-0000-0000-0000-000000000091'$$,
  $$values (0::bigint)$$,
  'target-room-only members still cannot read the token image metadata'
);
select results_eq(
  $$select count(*) from storage.objects where bucket_id = 'assets' and name = '00000000-0000-0000-0000-000000000080/token.png'$$,
  $$values (0::bigint)$$,
  'target-room-only members still cannot read the token image file'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000080', true);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000080","is_anonymous":false}', true);
select throws_ok(
  $$update public.room_tokens set map_id = '00000000-0000-0000-0000-0000000000b1' where id = '00000000-0000-0000-0000-0000000000a0'$$,
  '23514', 'room token map cannot be changed',
  'masters cannot move an existing token to another map in the same room'
);
select throws_ok(
  $$update public.room_tokens set map_id = '00000000-0000-0000-0000-0000000000b2' where id = '00000000-0000-0000-0000-0000000000a0'$$,
  '23514', 'room token map cannot be changed',
  'masters cannot move an existing token to another room'
);
select results_eq(
  $$update public.room_tokens set x = 9, y = 10 where id = '00000000-0000-0000-0000-0000000000a0' returning x, y$$,
  $$values (9::numeric, 10::numeric)$$,
  'masters can move an existing token without specifying its map'
);
select results_eq(
  $$update public.room_tokens set map_id = '00000000-0000-0000-0000-0000000000b0', x = 11, y = 12 where id = '00000000-0000-0000-0000-0000000000a0' returning x, y$$,
  $$values (11::numeric, 12::numeric)$$,
  'masters can move an existing token with an explicitly unchanged map'
);
select results_eq(
  $$update public.room_tokens set owner_id = null where id = '00000000-0000-0000-0000-0000000000a0' returning owner_id$$,
  $$values (null::uuid)$$,
  'masters can unassign an existing token'
);
select results_eq(
  $$update public.room_tokens set owner_id = '00000000-0000-0000-0000-000000000081' where id = '00000000-0000-0000-0000-0000000000a0' returning owner_id$$,
  $$values ('00000000-0000-0000-0000-000000000081'::uuid)$$,
  'masters can reassign an existing token'
);

select lives_ok(
  $$select public.set_room_member_role((select id from test_room), '00000000-0000-0000-0000-000000000081', 'spectator')$$,
  'masters can change an assigned players role'
);

select results_eq(
  $$select owner_id is null from public.room_tokens where id = '00000000-0000-0000-0000-0000000000a0'$$,
  $$values (true)$$,
  'tokens are unassigned when their owner is no longer an active player'
);

select * from finish();

rollback;
