begin;

select plan(8);

select results_eq(
  $$select public from storage.buckets where id = 'avatars'$$,
  $$values (false)$$,
  'avatars bucket is private'
);

insert into storage.objects (bucket_id, name) values
  ('avatars', '00000000-0000-0000-0000-000000000020/existing.png'),
  ('avatars', '00000000-0000-0000-0000-000000000021/existing.png');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000020', true);

select results_eq(
  $$select name from storage.objects where bucket_id = 'avatars' order by name$$,
  $$values ('00000000-0000-0000-0000-000000000020/existing.png'::text)$$,
  'authenticated users can only read their own avatars'
);

select lives_ok(
  $$insert into storage.objects (bucket_id, name) values ('avatars', '00000000-0000-0000-0000-000000000020/new.png')$$,
  'authenticated users can upload their own avatar'
);

select throws_ok(
  $$insert into storage.objects (bucket_id, name) values ('avatars', '00000000-0000-0000-0000-000000000021/new.png')$$,
  '42501',
  null,
  'authenticated users cannot upload another user avatar'
);

select lives_ok(
  $$update storage.objects set metadata = '{"updated":true}' where bucket_id = 'avatars' and name = '00000000-0000-0000-0000-000000000020/existing.png'$$,
  'authenticated users can update their own avatar'
);

select results_eq(
  $$update storage.objects set metadata = '{"updated":true}' where bucket_id = 'avatars' and name = '00000000-0000-0000-0000-000000000021/existing.png' returning name$$,
  $$select null::text where false$$,
  'authenticated users cannot update another user avatar'
);

select throws_ok(
  $$update storage.objects set name = '00000000-0000-0000-0000-000000000021/moved.png' where bucket_id = 'avatars' and name = '00000000-0000-0000-0000-000000000020/existing.png'$$,
  '42501',
  null,
  'authenticated users cannot move an avatar into another user folder'
);

set local role anon;
select set_config('request.jwt.claim.sub', '', true);

select results_eq(
  $$select count(*) from storage.objects where bucket_id = 'avatars'$$,
  $$values (0::bigint)$$,
  'anonymous users cannot read avatars'
);

select * from finish();

rollback;
