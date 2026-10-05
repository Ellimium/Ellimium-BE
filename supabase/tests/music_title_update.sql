begin;
select plan(12);
select ok(has_function_privilege('authenticated', 'public.rename_music_asset(uuid,text)', 'execute'), 'authenticated can request rename');
select ok(not has_function_privilege('anon', 'public.rename_music_asset(uuid,text)', 'execute'), 'anonymous cannot rename');
insert into auth.users (id, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000400', '{"nickname":"Rename Owner"}'),
  ('00000000-0000-0000-0000-000000000401', '{"nickname":"Rename Other"}');
insert into public.music_assets (id, owner_id, title, storage_path, mime_type, file_size_bytes, duration_ms) values
  ('00000000-0000-0000-0000-000000000420', '00000000-0000-0000-0000-000000000400', 'Original', '00000000-0000-0000-0000-000000000400/music.mp3', 'audio/mpeg', 100, 100);
set local role authenticated;
select set_config('request.jwt.claim.sub', '', true);
select throws_ok($$select public.rename_music_asset('00000000-0000-0000-0000-000000000420', 'New')$$, '42501', 'authentication required', 'user id required');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000401', true);
select throws_ok($$select public.rename_music_asset('00000000-0000-0000-0000-000000000420', 'New')$$, '42501', 'music owner required', 'non-owner denied');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000400', true);
select throws_ok($$select public.rename_music_asset('00000000-0000-0000-0000-000000000420', '   ')$$, '22023', 'music title required', 'blank title denied');
select throws_ok($$select public.rename_music_asset('00000000-0000-0000-0000-000000000420', null)$$, '22023', 'music title required', 'null title denied');
select throws_ok($$select public.rename_music_asset('00000000-0000-0000-0000-000000000499', 'New')$$, 'P0002', 'music not found', 'missing music denied');
select is(public.rename_music_asset('00000000-0000-0000-0000-000000000420', '  전투 음악  '), '전투 음악', 'owner rename trims title');
select is((select title from public.music_assets where id = '00000000-0000-0000-0000-000000000420'), '전투 음악', 'title saved');
select results_eq($$select storage_path, mime_type, file_size_bytes, duration_ms, deletion_pending from public.music_assets$$,
  $$values ('00000000-0000-0000-0000-000000000400/music.mp3'::text, 'audio/mpeg'::text, 100::bigint, 100::bigint, false)$$, 'other metadata unchanged');
select lives_ok($$update public.music_assets set owner_id = '00000000-0000-0000-0000-000000000401' where id = '00000000-0000-0000-0000-000000000420'$$, 'RLS filters direct write');
set local role postgres;
update public.music_assets set deletion_pending = true where id = '00000000-0000-0000-0000-000000000420';
set local role authenticated;
select throws_ok($$select public.rename_music_asset('00000000-0000-0000-0000-000000000420', 'Revive')$$, '23514', 'music deletion is pending', 'pending deletion cannot be renamed');
select * from finish();
rollback;
