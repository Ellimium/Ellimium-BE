begin;
select no_plan();

select ok(exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime'
  and schemaname = 'public' and tablename = 'room_jukebox_states'), 'state is published for Realtime');
select ok((select relrowsecurity from pg_class where oid = 'public.room_jukebox_states'::regclass), 'state RLS remains enabled');
select ok(not has_function_privilege('anon', 'public.control_room_jukebox(uuid,text,uuid,bigint,boolean)', 'execute'), 'anonymous cannot call control');
select ok(has_function_privilege('authenticated', 'public.control_room_jukebox(uuid,text,uuid,bigint,boolean)', 'execute'), 'authenticated can call checked control');

insert into auth.users (id, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000600', '{"nickname":"Jukebox Master"}'), ('00000000-0000-0000-0000-000000000601', '{"nickname":"Jukebox Player"}'),
  ('00000000-0000-0000-0000-000000000602', '{"nickname":"Jukebox Spectator"}'), ('00000000-0000-0000-0000-000000000603', '{"nickname":"Jukebox Left"}'),
  ('00000000-0000-0000-0000-000000000604', '{"nickname":"Jukebox Removed"}'), ('00000000-0000-0000-0000-000000000605', '{"nickname":"Jukebox Other"}');
insert into public.rooms (id, creator_id, name, game_system) values
  ('00000000-0000-0000-0000-000000000606', '00000000-0000-0000-0000-000000000600', 'Jukebox', 'Test'), ('00000000-0000-0000-0000-000000000607', '00000000-0000-0000-0000-000000000600', 'Other room', 'Test');
insert into public.room_members (room_id, user_id, role, status) values
  ('00000000-0000-0000-0000-000000000606', '00000000-0000-0000-0000-000000000600', 'master', 'active'), ('00000000-0000-0000-0000-000000000606', '00000000-0000-0000-0000-000000000601', 'player', 'active'),
  ('00000000-0000-0000-0000-000000000606', '00000000-0000-0000-0000-000000000602', 'spectator', 'active'), ('00000000-0000-0000-0000-000000000606', '00000000-0000-0000-0000-000000000603', 'master', 'left'),
  ('00000000-0000-0000-0000-000000000606', '00000000-0000-0000-0000-000000000604', 'master', 'removed'), ('00000000-0000-0000-0000-000000000607', '00000000-0000-0000-0000-000000000605', 'master', 'active');
insert into public.music_assets (id, owner_id, title, storage_path, mime_type, file_size_bytes, duration_ms) values
  ('00000000-0000-0000-0000-000000000608', '00000000-0000-0000-0000-000000000600', 'Current', '00000000-0000-0000-0000-000000000600/current.mp3', 'audio/mpeg', 100, 10000),
  ('00000000-0000-0000-0000-000000000609', '00000000-0000-0000-0000-000000000600', 'Next', '00000000-0000-0000-0000-000000000600/next.mp3', 'audio/mpeg', 100, 15000),
  ('00000000-0000-0000-0000-000000000610', '00000000-0000-0000-0000-000000000605', 'Private', '00000000-0000-0000-0000-000000000605/private.mp3', 'audio/mpeg', 100, 20000),
  ('00000000-0000-0000-0000-000000000611', '00000000-0000-0000-0000-000000000600', 'Deleting', '00000000-0000-0000-0000-000000000600/deleting.mp3', 'audio/mpeg', 100, 20000);
update public.music_assets set deletion_pending = true where id = '00000000-0000-0000-0000-000000000611';
create function pg_temp.control(action text, music uuid default null, playback_position bigint default null, looping boolean default null)
returns public.room_jukebox_states language sql as $$
  select public.control_room_jukebox('00000000-0000-0000-0000-000000000606', action, music, playback_position, looping);
$$;

set local role authenticated;
select set_config('request.jwt.claim.sub', '', true);
select throws_ok($$select pg_temp.control('stop')$$, '42501', 'authentication required', 'missing login denied');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000601', true);
select throws_ok($$select pg_temp.control('play', '00000000-0000-0000-0000-000000000608')$$, '42501', 'active room master required', 'player cannot control');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000602', true);
select throws_ok($$select pg_temp.control('stop')$$, '42501', 'active room master required', 'spectator cannot control');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000603', true);
select throws_ok($$select pg_temp.control('stop')$$, '42501', 'active room master required', 'left master cannot control');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000604', true);
select throws_ok($$select pg_temp.control('stop')$$, '42501', 'active room master required', 'removed master cannot control');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000605', true);
select throws_ok($$select pg_temp.control('stop')$$, '42501', 'active room master required', 'other room master cannot control');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000600', true);
select throws_ok($$select public.control_room_jukebox('00000000-0000-0000-0000-000000000612', 'stop')$$, '42501', 'active room master required', 'unknown room denied');
select throws_ok($$select pg_temp.control('play', '00000000-0000-0000-0000-000000000610')$$, '42501', 'music owner required', 'master cannot select another owner music');
select throws_ok($$select pg_temp.control('play', '00000000-0000-0000-0000-000000000611')$$, '23514', 'music deletion is pending', 'deleting music cannot be selected');
select throws_ok($$select pg_temp.control('play', '00000000-0000-0000-0000-000000000612')$$, '22023', 'playable music required', 'missing music denied');
select throws_ok($$select pg_temp.control(null)$$, '22023', 'invalid jukebox action', 'null action denied');
select throws_ok($$select pg_temp.control('delete')$$, '22023', 'invalid jukebox action', 'unknown action denied');
select throws_ok($$select pg_temp.control('play')$$, '22023', 'invalid jukebox arguments', 'play needs music');
select throws_ok($$select pg_temp.control('seek')$$, '22023', 'invalid jukebox arguments', 'seek needs position');
select throws_ok($$select pg_temp.control('set_loop')$$, '22023', 'invalid jukebox arguments', 'loop needs boolean');
select throws_ok($$select pg_temp.control('play', '00000000-0000-0000-0000-000000000608', -1)$$, '22023', 'invalid jukebox arguments', 'negative position denied');
select throws_ok($$select pg_temp.control('stop', '00000000-0000-0000-0000-000000000608')$$, '22023', 'invalid jukebox arguments', 'unrelated music argument denied');
select throws_ok($$select pg_temp.control('pause', null, 5)$$, '22023', 'invalid jukebox arguments', 'pause cannot forge position');
select throws_ok($$select pg_temp.control('resume', null, null, true)$$, '22023', 'invalid jukebox arguments', 'resume cannot forge loop');
select throws_ok($$select pg_temp.control('pause')$$, '22023', 'playable music required', 'empty state cannot pause');
select is((select count(*) from public.room_jukebox_states), 0::bigint, 'denied operations create no state');

select is((pg_temp.control('play', '00000000-0000-0000-0000-000000000608')).status, 'playing', 'play initializes state');
select is((select position_ms from public.room_jukebox_states where room_id = '00000000-0000-0000-0000-000000000606'), 0::bigint, 'play defaults to zero');
select is((select loop_enabled from public.room_jukebox_states where room_id = '00000000-0000-0000-0000-000000000606'), false, 'play defaults to no loop');
select ok((select state_changed_at between statement_timestamp() - interval '5 seconds' and clock_timestamp()
  from public.room_jukebox_states where room_id = '00000000-0000-0000-0000-000000000606'), 'timestamp comes from server clock');
select is((pg_temp.control('play', '00000000-0000-0000-0000-000000000609', 4000, true)).music_asset_id, '00000000-0000-0000-0000-000000000609'::uuid, 'play replaces selected music');
select is((select count(*) from public.room_jukebox_states), 1::bigint, 'repeat play preserves one row per room');
select is((select position_ms from public.room_jukebox_states), 4000::bigint, 'play accepts position');
select is((select loop_enabled from public.room_jukebox_states), true, 'play accepts loop');

-- Seed a known server clock to verify elapsed time without timing sleeps.
set local role postgres;
update public.room_jukebox_states set position_ms = 4000, state_changed_at = clock_timestamp() - interval '2 seconds';
set local role authenticated;
select ok((pg_temp.control('pause')).position_ms between 6000 and 8000, 'pause captures server elapsed position');
select is((select status from public.room_jukebox_states), 'paused', 'pause changes status');
create temporary table paused_snapshot as select * from public.room_jukebox_states;
select is((pg_temp.control('pause')).state_changed_at, (select state_changed_at from paused_snapshot), 'repeated pause leaves clock unchanged');
select is((pg_temp.control('set_loop', null, null, false)).position_ms, (select position_ms from paused_snapshot), 'loop change does not advance paused position');
select is((select loop_enabled from public.room_jukebox_states), false, 'loop can be disabled');
select is((pg_temp.control('seek', null, 9000)).status, 'paused', 'seek preserves pause');
select is((select position_ms from public.room_jukebox_states), 9000::bigint, 'seek uses requested position');
select is((pg_temp.control('resume')).position_ms, 9000::bigint, 'resume keeps paused position');
select is((select status from public.room_jukebox_states), 'playing', 'resume plays');
create temporary table playing_snapshot as select * from public.room_jukebox_states;
select is((pg_temp.control('resume')).state_changed_at, (select state_changed_at from playing_snapshot), 'repeated resume leaves clock unchanged');
select is((pg_temp.control('seek', null, 16000)).position_ms, 16000::bigint, 'seek is not clamped to metadata duration');
select is((select status from public.room_jukebox_states), 'playing', 'seek preserves playing');
set local role postgres;
update public.room_jukebox_states set position_ms = 16000, state_changed_at = clock_timestamp() - interval '2 seconds';
set local role authenticated;
select ok((pg_temp.control('set_loop', null, null, true)).position_ms between 18000 and 20000, 'loop change preserves elapsed timeline without metadata modulo');
select is((select loop_enabled from public.room_jukebox_states), true, 'loop enabled');

-- Master also cannot bypass the checked RPC with client writes.
select throws_ok($$update public.room_jukebox_states set position_ms = 50$$, '42501', null, 'master direct update denied');
select throws_ok($$insert into public.room_jukebox_states (room_id) values ('00000000-0000-0000-0000-000000000607')$$, '42501', null, 'master direct insert denied');
select throws_ok($$delete from public.room_jukebox_states$$, '42501', null, 'master direct delete denied');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000601', true);
select is((select count(*) from public.room_jukebox_states), 1::bigint, 'player reads active room state');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000602', true);
select is((select count(*) from public.room_jukebox_states), 1::bigint, 'spectator reads active room state');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000603', true);
select is((select count(*) from public.room_jukebox_states), 0::bigint, 'left member cannot read state');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000604', true);
select is((select count(*) from public.room_jukebox_states), 0::bigint, 'removed member cannot read state');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000605', true);
select is((select count(*) from public.room_jukebox_states), 0::bigint, 'other room member cannot read state');
set local role anon;
select throws_ok($$select * from public.room_jukebox_states$$, '42501', null, 'anonymous cannot read');
select throws_ok($$select pg_temp.control('stop')$$, '42501', null, 'anonymous execute privilege denied');
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000600', true);
select is((pg_temp.control('stop')).status, 'stopped', 'stop changes status');
select is((select music_asset_id from public.room_jukebox_states), null::uuid, 'stop clears music');
select is((select position_ms from public.room_jukebox_states), 0::bigint, 'stop resets position');
select is((select loop_enabled from public.room_jukebox_states), false, 'stop resets loop');
select is((pg_temp.control('stop')).status, 'stopped', 'repeated stop succeeds');
select is((select count(*) from public.room_jukebox_states), 1::bigint, 'stop never deletes row');
select throws_ok($$select pg_temp.control('resume')$$, '22023', 'playable music required', 'stop cannot resume removed music');
select throws_ok($$select public.control_room_jukebox('00000000-0000-0000-0000-000000000607', 'stop')$$, '42501', 'active room master required', 'non-member cannot stop another room');

select is((pg_temp.control('play', '00000000-0000-0000-0000-000000000608', 7000, true)).status, 'playing', 'music can play again after stop');
create temporary table before_deletion as select * from public.room_jukebox_states;
select lives_ok($$select public.prepare_music_asset_deletion('00000000-0000-0000-0000-000000000608')$$, 'owner prepares deletion of current music');
select is((select status from public.room_jukebox_states), 'stopped', 'deletion stops playing state');
select is((select music_asset_id from public.room_jukebox_states), null::uuid, 'deletion clears selected music');
select is((select position_ms from public.room_jukebox_states), 0::bigint, 'deletion clears position');
select is((select loop_enabled from public.room_jukebox_states), false, 'deletion clears loop');
select ok((select state_changed_at from public.room_jukebox_states) > (select state_changed_at from before_deletion), 'deletion updates server clock');
select is((select count(*) from public.room_jukebox_states), 1::bigint, 'deletion preserves state row');
select throws_ok($$select pg_temp.control('play', '00000000-0000-0000-0000-000000000608')$$, '23514', 'music deletion is pending', 'deleted track cannot be restored');
select lives_ok($$select pg_temp.control('play', '00000000-0000-0000-0000-000000000609', 4000, true)$$, 'remaining music is playable');
set local role postgres;
delete from public.music_assets where id = '00000000-0000-0000-0000-000000000609';
select is((select status from public.room_jukebox_states), 'stopped', 'FK deletion also stops music');
select is((select position_ms from public.room_jukebox_states), 0::bigint, 'FK deletion resets position');
select is((select loop_enabled from public.room_jukebox_states), false, 'FK deletion resets loop');
select is((select count(*) from public.room_jukebox_states), 1::bigint, 'FK deletion preserves state row');
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000605', true);
select is((public.control_room_jukebox('00000000-0000-0000-0000-000000000607', 'stop')).status, 'stopped', 'first stop initializes an empty room state');
select is((select count(*) from public.room_jukebox_states), 1::bigint, 'master only reads own active room');
set local role postgres;
select throws_ok($$update public.room_jukebox_states set position_ms = -1, music_asset_id = '00000000-0000-0000-0000-000000000610' where room_id = '00000000-0000-0000-0000-000000000607'$$, '23514', null, 'DB constraint rejects negative position');
select * from finish();
rollback;
