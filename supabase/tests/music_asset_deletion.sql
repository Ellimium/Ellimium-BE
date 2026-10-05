begin;
select plan(24);
select has_column('public', 'music_assets', 'deletion_pending', 'failed cleanup retains retry state');
select has_column('public', 'room_jukebox_states', 'status', 'jukebox records stopped state');
select ok(has_function_privilege('authenticated', 'public.prepare_music_asset_deletion(uuid)', 'execute'), 'owner can request preparation');
select ok(not has_function_privilege('anon', 'public.prepare_music_asset_deletion(uuid)', 'execute'), 'anonymous cannot prepare deletion');
select ok(not has_function_privilege('authenticated', 'public.finish_music_asset_deletion(uuid,uuid)', 'execute'), 'client cannot skip Storage cleanup');
select ok(has_function_privilege('service_role', 'public.finish_music_asset_deletion(uuid,uuid)', 'execute'), 'server can finalize');

insert into auth.users (id, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000300', '{"nickname":"Delete Owner"}'),
  ('00000000-0000-0000-0000-000000000301', '{"nickname":"Delete Other"}');
insert into public.rooms (id, creator_id, name, game_system) values
  ('00000000-0000-0000-0000-000000000310', '00000000-0000-0000-0000-000000000300', 'Delete A', 'Test'),
  ('00000000-0000-0000-0000-000000000311', '00000000-0000-0000-0000-000000000300', 'Delete B', 'Test');
insert into public.music_assets (id, owner_id, title, storage_path, mime_type, file_size_bytes, duration_ms) values
  ('00000000-0000-0000-0000-000000000320', '00000000-0000-0000-0000-000000000300', 'Deleting', '00000000-0000-0000-0000-000000000300/deleting.mp3', 'audio/mpeg', 100, 100),
  ('00000000-0000-0000-0000-000000000321', '00000000-0000-0000-0000-000000000300', 'Keep', '00000000-0000-0000-0000-000000000300/keep.mp3', 'audio/mpeg', 100, 100);
insert into storage.objects (bucket_id, name) values
  ('music-assets', '00000000-0000-0000-0000-000000000300/deleting.mp3'),
  ('music-assets', '00000000-0000-0000-0000-000000000300/keep.mp3');
insert into public.room_jukebox_states (room_id, music_asset_id, status) values
  ('00000000-0000-0000-0000-000000000310', '00000000-0000-0000-0000-000000000320', 'playing'),
  ('00000000-0000-0000-0000-000000000311', '00000000-0000-0000-0000-000000000320', 'paused');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000301', true);
select throws_ok($$select public.prepare_music_asset_deletion('00000000-0000-0000-0000-000000000320')$$,
  '42501', 'music owner required', 'non-owner cannot prepare deletion');
set local role postgres;
select is((select count(*) from public.music_assets where deletion_pending), 0::bigint, 'denied request does not mark music');
set local role authenticated;
select set_config('request.jwt.claim.sub', '', true);
select throws_ok($$select public.prepare_music_asset_deletion('00000000-0000-0000-0000-000000000320')$$,
  '42501', 'authentication required', 'missing user id cannot prepare deletion');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000300', true);
select is(public.prepare_music_asset_deletion('00000000-0000-0000-0000-000000000320'),
  '00000000-0000-0000-0000-000000000300/deleting.mp3', 'owner receives stored cleanup path');
select is((select deletion_pending from public.music_assets where id = '00000000-0000-0000-0000-000000000320'), true, 'deletion is pending');
set local role postgres;
select is((select count(*) from public.room_jukebox_states where status = 'stopped' and music_asset_id is null), 2::bigint, 'all referencing rooms stop and clear music');
select is((select count(*) from public.music_assets), 2::bigint, 'metadata remains for retries before Storage cleanup');
set local role authenticated;
select results_eq($$select name from storage.objects where bucket_id = 'music-assets'$$,
  $$values ('00000000-0000-0000-0000-000000000300/keep.mp3'::text)$$, 'pending music is excluded from new Storage access');
set local role postgres;
select throws_ok($$update public.room_jukebox_states set music_asset_id = '00000000-0000-0000-0000-000000000320', status = 'playing'$$,
  '23514', 'music deletion is pending', 'pending music cannot be reselected');
set local role authenticated;
select is(public.prepare_music_asset_deletion('00000000-0000-0000-0000-000000000320'),
  '00000000-0000-0000-0000-000000000300/deleting.mp3', 'owner can retry preparation');
select is(public.prepare_music_asset_deletion('00000000-0000-0000-0000-000000000399'), null::text, 'missing music is an idempotent no-op');
select throws_ok($$select public.finish_music_asset_deletion('00000000-0000-0000-0000-000000000320', '00000000-0000-0000-0000-000000000300')$$,
  '42501', null, 'authenticated client cannot finalize');
set local role service_role;
select throws_ok($$select public.finish_music_asset_deletion('00000000-0000-0000-0000-000000000320', '00000000-0000-0000-0000-000000000301')$$,
  '42501', 'music deletion was not prepared for this owner', 'finalization checks expected owner');
select throws_ok($$select public.finish_music_asset_deletion('00000000-0000-0000-0000-000000000321', '00000000-0000-0000-0000-000000000300')$$,
  '42501', 'music deletion was not prepared for this owner', 'unprepared music cannot be finalized');
select is(public.finish_music_asset_deletion('00000000-0000-0000-0000-000000000320', '00000000-0000-0000-0000-000000000300'), true, 'server finalizes prepared metadata');
select is(public.finish_music_asset_deletion('00000000-0000-0000-0000-000000000320', '00000000-0000-0000-0000-000000000300'), false, 'repeated finalization is a no-op');
set local role postgres;
select is((select count(*) from public.room_jukebox_states), 2::bigint, 'room state rows survive deletion');
update public.room_jukebox_states set music_asset_id = '00000000-0000-0000-0000-000000000321', status = 'playing';
delete from public.music_assets where id = '00000000-0000-0000-0000-000000000321';
select is((select count(*) from public.room_jukebox_states where status = 'stopped' and music_asset_id is null), 2::bigint, 'FK cleanup also stops music on owner/account cascade');
select * from finish();
rollback;
