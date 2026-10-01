begin;

select plan(12);

select has_table('public', 'assets', 'assets table exists');
select col_is_pk('public', 'assets', 'id', 'asset id is the primary key');
select col_is_fk('public', 'assets', 'owner_id', 'asset owner references auth.users');
select results_eq(
  $$select public from storage.buckets where id = 'assets'$$,
  $$values (false)$$,
  'assets bucket is private'
);

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, confirmation_token, email_change,
  recovery_token, email_change_token_new
) values
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000050', 'authenticated', 'authenticated', 'asset-owner@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"자산소유자"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000051', 'authenticated', 'authenticated', 'asset-other@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"다른사용자"}', '', '', '', '');

insert into public.assets (owner_id, category, storage_path) values
  ('00000000-0000-0000-0000-000000000050', 'token', '00000000-0000-0000-0000-000000000050/existing.png'),
  ('00000000-0000-0000-0000-000000000051', 'map', '00000000-0000-0000-0000-000000000051/existing.png');
insert into storage.objects (bucket_id, name) values
  ('assets', '00000000-0000-0000-0000-000000000050/existing.png'),
  ('assets', '00000000-0000-0000-0000-000000000051/existing.png');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000050', true);

select results_eq(
  $$select storage_path from public.assets order by storage_path$$,
  $$values ('00000000-0000-0000-0000-000000000050/existing.png'::text)$$,
  'users can only read their own unreferenced assets'
);

select throws_ok(
  $$insert into public.assets (owner_id, category, storage_path) values ('00000000-0000-0000-0000-000000000050', 'item', '00000000-0000-0000-0000-000000000050/new.png')$$,
  '42501',
  null,
  'users cannot bypass the upload function for asset metadata'
);

select throws_ok(
  $$insert into public.assets (owner_id, category, storage_path) values ('00000000-0000-0000-0000-000000000051', 'item', '00000000-0000-0000-0000-000000000051/new.png')$$,
  '42501',
  null,
  'users cannot create another user asset metadata'
);

set local role postgres;
select throws_ok(
  $$insert into public.assets (owner_id, category, storage_path) values ('00000000-0000-0000-0000-000000000050', 'item', '00000000-0000-0000-0000-000000000051/invalid.png')$$,
  '23514',
  null,
  'asset metadata paths must belong to their owner'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000050', true);

select results_eq(
  $$select name from storage.objects where bucket_id = 'assets' order by name$$,
  $$values ('00000000-0000-0000-0000-000000000050/existing.png'::text)$$,
  'users can only read files in their own asset folder'
);

select throws_ok(
  $$insert into storage.objects (bucket_id, name) values ('assets', '00000000-0000-0000-0000-000000000050/new.png')$$,
  '42501',
  null,
  'users cannot bypass the upload function for asset files'
);

select throws_ok(
  $$insert into storage.objects (bucket_id, name) values ('assets', '00000000-0000-0000-0000-000000000051/new.png')$$,
  '42501',
  null,
  'users cannot upload into another user asset folder'
);

set local role anon;
select set_config('request.jwt.claim.sub', '', true);

select results_eq(
  $$select (select count(*) from public.assets), (select count(*) from storage.objects where bucket_id = 'assets')$$,
  $$values (0::bigint, 0::bigint)$$,
  'anonymous users cannot read assets or asset files'
);

select * from finish();

rollback;
