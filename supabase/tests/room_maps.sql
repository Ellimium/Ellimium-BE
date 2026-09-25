begin;

select plan(14);

select has_table('public', 'room_maps', 'room maps table exists');
select col_is_pk('public', 'room_maps', 'id', 'room map id is the primary key');
select col_is_fk('public', 'room_maps', 'room_id', 'room map references its room');

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, confirmation_token, email_change,
  recovery_token, email_change_token_new
) values
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000060', 'authenticated', 'authenticated', 'map-master@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"맵마스터"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000061', 'authenticated', 'authenticated', 'map-member@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"맵구성원"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000062', 'authenticated', 'authenticated', 'map-outsider@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"맵외부인"}', '', '', '', '');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000060', true);

create temporary table test_room as
select (public.create_room('맵 정책 테스트 룸', null, 'D&D 5e')).*;

set local role postgres;

insert into public.room_members (room_id, user_id, role)
select id, '00000000-0000-0000-0000-000000000061', 'player' from test_room;

insert into public.assets (id, owner_id, category, storage_path, thumbnail_storage_path) values
  ('00000000-0000-0000-0000-000000000070', '00000000-0000-0000-0000-000000000060', 'map', '00000000-0000-0000-0000-000000000060/map.png', '00000000-0000-0000-0000-000000000060/map-thumb.png'),
  ('00000000-0000-0000-0000-000000000071', '00000000-0000-0000-0000-000000000060', 'token', '00000000-0000-0000-0000-000000000060/token.png', null),
  ('00000000-0000-0000-0000-000000000072', '00000000-0000-0000-0000-000000000062', 'map', '00000000-0000-0000-0000-000000000062/other-map.png', null);

insert into storage.objects (bucket_id, name) values
  ('assets', '00000000-0000-0000-0000-000000000060/map.png'),
  ('assets', '00000000-0000-0000-0000-000000000060/map-thumb.png'),
  ('assets', '00000000-0000-0000-0000-000000000060/token.png'),
  ('assets', '00000000-0000-0000-0000-000000000062/other-map.png');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000060', true);

select lives_ok(
  $$insert into public.room_maps (room_id, asset_id, grid_cell_size, grid_offset_x, grid_offset_y) values ((select id from test_room), '00000000-0000-0000-0000-000000000070', 50, -10, 20)$$,
  'masters can connect their map assets'
);

select results_eq(
  $$select grid_cell_size, grid_offset_x, grid_offset_y from public.room_maps where room_id = (select id from test_room)$$,
  $$values (50::integer, -10::integer, 20::integer)$$,
  'map grid metadata is persisted'
);

select throws_ok(
  $$insert into public.room_maps (room_id, asset_id) values ((select id from test_room), '00000000-0000-0000-0000-000000000071')$$,
  '42501',
  null,
  'masters cannot connect non-map assets'
);

select throws_ok(
  $$insert into public.room_maps (room_id, asset_id) values ((select id from test_room), '00000000-0000-0000-0000-000000000072')$$,
  '42501',
  null,
  'masters cannot connect another users map assets'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000061', true);

select results_eq(
  $$select asset_id from public.room_maps where room_id = (select id from test_room)$$,
  $$values ('00000000-0000-0000-0000-000000000070'::uuid)$$,
  'active members can read room map metadata'
);

select results_eq(
  $$select storage_path from public.assets$$,
  $$values ('00000000-0000-0000-0000-000000000060/map.png'::text)$$,
  'active members can read linked map assets'
);

select results_eq(
  $$select name from storage.objects where bucket_id = 'assets' order by name$$,
  $$values ('00000000-0000-0000-0000-000000000060/map-thumb.png'::text), ('00000000-0000-0000-0000-000000000060/map.png'::text)$$,
  'active members can read linked map files and thumbnails'
);

select throws_ok(
  $$insert into public.room_maps (room_id, asset_id) values ((select id from test_room), '00000000-0000-0000-0000-000000000070')$$,
  '42501',
  null,
  'non-masters cannot add room maps'
);

select results_eq(
  $$update public.room_maps set grid_cell_size = 100 where room_id = (select id from test_room) returning grid_cell_size$$,
  $$select null::integer where false$$,
  'non-masters cannot change room maps'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000062', true);

select results_eq(
  $$select (select count(*) from public.room_maps), (select count(*) from public.assets where id = '00000000-0000-0000-0000-000000000070'), (select count(*) from storage.objects where name in ('00000000-0000-0000-0000-000000000060/map.png', '00000000-0000-0000-0000-000000000060/map-thumb.png'))$$,
  $$values (0::bigint, 0::bigint, 0::bigint)$$,
  'outsiders cannot read room maps or linked assets'
);

set local role anon;
select set_config('request.jwt.claim.sub', '', true);

select results_eq(
  $$select (select count(*) from public.room_maps), (select count(*) from public.assets), (select count(*) from storage.objects where bucket_id = 'assets')$$,
  $$values (0::bigint, 0::bigint, 0::bigint)$$,
  'anonymous users cannot read room maps or linked assets'
);

select * from finish();

rollback;
