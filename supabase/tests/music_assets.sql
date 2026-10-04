begin;

select plan(15);

select has_table('public', 'music_assets', 'music_assets table exists');
select col_is_pk('public', 'music_assets', 'id', 'music asset id is the primary key');
select col_is_fk('public', 'music_assets', 'owner_id', 'music asset owner references auth.users');
select results_eq(
  $$select public from storage.buckets where id = 'music-assets'$$,
  $$values (false)$$,
  'music assets bucket is private'
);

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, confirmation_token, email_change,
  recovery_token, email_change_token_new
) values
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000150', 'authenticated', 'authenticated', 'music-owner@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"Music Owner"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000151', 'authenticated', 'authenticated', 'music-other@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"Music Other"}', '', '', '', '');

insert into public.music_assets (id, owner_id, title, storage_path, mime_type, file_size_bytes, duration_ms) values
  ('00000000-0000-0000-0000-000000000152', '00000000-0000-0000-0000-000000000150', 'Owner track', '00000000-0000-0000-0000-000000000150/track.mp3', 'audio/mpeg', 1024, 1234),
  ('00000000-0000-0000-0000-000000000153', '00000000-0000-0000-0000-000000000151', 'Other track', '00000000-0000-0000-0000-000000000151/track.ogg', 'audio/ogg', 2048, 2345);
insert into storage.objects (bucket_id, name) values
  ('music-assets', '00000000-0000-0000-0000-000000000150/track.mp3'),
  ('music-assets', '00000000-0000-0000-0000-000000000151/track.ogg');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000150', true);

select results_eq(
  $$select title from public.music_assets order by title$$,
  $$values ('Owner track'::text)$$,
  'owners can only read their own music metadata'
);
select throws_ok(
  $$insert into public.music_assets (owner_id, title, storage_path, mime_type, file_size_bytes, duration_ms) values ('00000000-0000-0000-0000-000000000150', 'Bypass', '00000000-0000-0000-0000-000000000150/bypass.mp3', 'audio/mpeg', 10, 10)$$,
  '42501', null,
  'users cannot bypass the upload function for music metadata'
);
select results_eq(
  $$update public.music_assets set title = 'Changed' where id = '00000000-0000-0000-0000-000000000152' returning title$$,
  $$select null::text where false$$,
  'users cannot update music metadata directly'
);
select results_eq(
  $$delete from public.music_assets where id = '00000000-0000-0000-0000-000000000152' returning title$$,
  $$select null::text where false$$,
  'users cannot delete music metadata directly'
);
select results_eq(
  $$select name from storage.objects where bucket_id = 'music-assets' order by name$$,
  $$values ('00000000-0000-0000-0000-000000000150/track.mp3'::text)$$,
  'owners can only read files in their own music folder'
);
select throws_ok(
  $$insert into storage.objects (bucket_id, name) values ('music-assets', '00000000-0000-0000-0000-000000000150/bypass.mp3')$$,
  '42501', null,
  'users cannot bypass the upload function for music files'
);

set local role postgres;
select throws_ok(
  $$insert into public.music_assets (owner_id, title, storage_path, mime_type, file_size_bytes, duration_ms) values ('00000000-0000-0000-0000-000000000150', 'Wrong path', '00000000-0000-0000-0000-000000000151/wrong.mp3', 'audio/mpeg', 10, 10)$$,
  '23514', null,
  'music metadata paths must belong to their owner'
);
select throws_ok(
  $$insert into public.music_assets (owner_id, title, storage_path, mime_type, file_size_bytes, duration_ms) values ('00000000-0000-0000-0000-000000000150', 'Invalid duration', '00000000-0000-0000-0000-000000000150/invalid.mp3', 'audio/mpeg', 10, 0)$$,
  '23514', null,
  'music duration must be positive'
);
select throws_ok(
  $$insert into public.music_assets (owner_id, title, storage_path, mime_type, file_size_bytes, duration_ms) values ('00000000-0000-0000-0000-000000000150', 'Invalid size', '00000000-0000-0000-0000-000000000150/invalid-size.mp3', 'audio/mpeg', 0, 10)$$,
  '23514', null,
  'music file size must be positive'
);
select throws_ok(
  $$insert into public.music_assets (owner_id, title, storage_path, mime_type, file_size_bytes, duration_ms) values ('00000000-0000-0000-0000-000000000150', 'Invalid MIME', '00000000-0000-0000-0000-000000000150/invalid.bin', 'application/octet-stream', 10, 10)$$,
  '23514', null,
  'music MIME type must be supported'
);

set local role anon;
select set_config('request.jwt.claim.sub', '', true);
select results_eq(
  $$select (select count(*) from public.music_assets), (select count(*) from storage.objects where bucket_id = 'music-assets')$$,
  $$values (0::bigint, 0::bigint)$$,
  'anonymous users cannot read music metadata or files'
);

select * from finish();

rollback;
