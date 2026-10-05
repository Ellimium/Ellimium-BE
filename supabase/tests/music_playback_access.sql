begin;
select plan(23);

select has_table('public', 'room_jukebox_states', 'room music reference table exists');
select col_is_pk('public', 'room_jukebox_states', 'room_id', 'one reference per room');
select col_is_fk('public', 'room_jukebox_states', 'music_asset_id', 'references music_assets');

insert into auth.users (id, raw_user_meta_data)
select ('00000000-0000-0000-0000-' || lpad(id::text, 12, '0'))::uuid,
       jsonb_build_object('nickname', 'Music test ' || id)
from generate_series(200, 205) as id;
insert into public.rooms (id, creator_id, name, game_system) values
  ('00000000-0000-0000-0000-000000000210', '00000000-0000-0000-0000-000000000200', 'Music room', 'Test'),
  ('00000000-0000-0000-0000-000000000211', '00000000-0000-0000-0000-000000000200', 'Other room', 'Test');
insert into public.room_members (room_id, user_id, role, status) values
  ('00000000-0000-0000-0000-000000000210', '00000000-0000-0000-0000-000000000200', 'master', 'active'),
  ('00000000-0000-0000-0000-000000000210', '00000000-0000-0000-0000-000000000201', 'player', 'active'),
  ('00000000-0000-0000-0000-000000000210', '00000000-0000-0000-0000-000000000202', 'spectator', 'active'),
  ('00000000-0000-0000-0000-000000000210', '00000000-0000-0000-0000-000000000203', 'player', 'left'),
  ('00000000-0000-0000-0000-000000000210', '00000000-0000-0000-0000-000000000204', 'player', 'removed'),
  ('00000000-0000-0000-0000-000000000211', '00000000-0000-0000-0000-000000000205', 'player', 'active');
insert into public.music_assets (id, owner_id, title, storage_path, mime_type, file_size_bytes, duration_ms) values
  ('00000000-0000-0000-0000-000000000220', '00000000-0000-0000-0000-000000000200', 'Current', '00000000-0000-0000-0000-000000000200/current.mp3', 'audio/mpeg', 100, 100),
  ('00000000-0000-0000-0000-000000000221', '00000000-0000-0000-0000-000000000200', 'Private', '00000000-0000-0000-0000-000000000200/private.mp3', 'audio/mpeg', 100, 100);
insert into public.room_jukebox_states (room_id, music_asset_id) values
  ('00000000-0000-0000-0000-000000000210', '00000000-0000-0000-0000-000000000220');
insert into storage.objects (bucket_id, name) values
  ('music-assets', '00000000-0000-0000-0000-000000000200/current.mp3'),
  ('music-assets', '00000000-0000-0000-0000-000000000200/private.mp3');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000200', true);
select is((select count(*) from storage.objects where bucket_id = 'music-assets'), 2::bigint, 'owner sees both files');
select throws_ok($$update public.room_jukebox_states set music_asset_id = null$$, '42501', null, 'even master cannot bypass future jukebox RPC');

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000201', true);
select results_eq($$select name from storage.objects where bucket_id = 'music-assets'$$,
  $$values ('00000000-0000-0000-0000-000000000200/current.mp3'::text)$$, 'player sees only currently referenced file');
select is((select count(*) from public.music_assets), 0::bigint, 'player cannot list owner library');
select is((select count(*) from public.room_jukebox_states), 1::bigint, 'player can read current room reference');
select throws_ok($$insert into public.room_jukebox_states (room_id, music_asset_id) values ('00000000-0000-0000-0000-000000000211', '00000000-0000-0000-0000-000000000221')$$,
  '42501', null, 'player cannot grant access by inserting a reference');
select throws_ok($$delete from public.room_jukebox_states$$, '42501', null, 'player cannot delete state rows');

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000202', true);
select is((select count(*) from storage.objects where bucket_id = 'music-assets'), 1::bigint, 'active spectator can access current music');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000203', true);
select is((select count(*) from storage.objects where bucket_id = 'music-assets'), 0::bigint, 'left member cannot access current music');
select is((select count(*) from public.room_jukebox_states), 0::bigint, 'left member cannot read state');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000204', true);
select is((select count(*) from storage.objects where bucket_id = 'music-assets'), 0::bigint, 'removed member cannot access current music');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000205', true);
select is((select count(*) from storage.objects where bucket_id = 'music-assets'), 0::bigint, 'membership in an unrelated room grants no access');

set local role postgres;
update public.room_jukebox_states set music_asset_id = '00000000-0000-0000-0000-000000000221';
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000201', true);
select results_eq($$select name from storage.objects where bucket_id = 'music-assets'$$,
  $$values ('00000000-0000-0000-0000-000000000200/private.mp3'::text)$$, 'changing reference immediately replaces access');

set local role postgres;
update public.room_jukebox_states set music_asset_id = null;
set local role authenticated;
select is((select count(*) from storage.objects where bucket_id = 'music-assets'), 0::bigint, 'empty reference removes access');

set local role postgres;
update public.room_jukebox_states set music_asset_id = '00000000-0000-0000-0000-000000000220';
insert into public.room_members (room_id, user_id, role) values
  ('00000000-0000-0000-0000-000000000211', '00000000-0000-0000-0000-000000000203', 'player');
insert into public.room_jukebox_states (room_id, music_asset_id) values
  ('00000000-0000-0000-0000-000000000211', '00000000-0000-0000-0000-000000000220');
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000203', true);
select is((select count(*) from storage.objects where bucket_id = 'music-assets'), 1::bigint, 'another active reference room still grants access');

set local role postgres;
update public.room_members set status = 'left' where user_id = '00000000-0000-0000-0000-000000000200';
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000200', true);
select is((select count(*) from storage.objects where bucket_id = 'music-assets'), 2::bigint, 'owner access survives leaving room');
select set_config('request.jwt.claim.sub', '', true);
select is((select count(*) from storage.objects where bucket_id = 'music-assets'), 0::bigint, 'missing user id grants no access');

set local role anon;
select is((select count(*) from storage.objects where bucket_id = 'music-assets'), 0::bigint, 'anonymous cannot access music');
select throws_ok($$select * from public.room_jukebox_states$$, '42501', null, 'anonymous cannot read state');

set local role postgres;
delete from public.music_assets where id = '00000000-0000-0000-0000-000000000220';
select is((select count(*) from public.room_jukebox_states where music_asset_id is null), 2::bigint, 'deleted music clears reference but preserves room rows');
select * from finish();
rollback;
