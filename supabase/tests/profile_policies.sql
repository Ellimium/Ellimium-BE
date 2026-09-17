begin;

select plan(4);

insert into auth.users (
  instance_id,
  id,
  aud,
  role,
  email,
  encrypted_password,
  email_confirmed_at,
  raw_app_meta_data,
  raw_user_meta_data,
  created_at,
  updated_at,
  confirmation_token,
  email_change,
  recovery_token,
  email_change_token_new
) values
  (
    '00000000-0000-0000-0000-000000000000',
    '00000000-0000-0000-0000-000000000010',
    'authenticated',
    'authenticated',
    'profile-owner@example.com',
    '',
    now(),
    '{"provider":"email","providers":["email"]}',
    '{"nickname":"소유자"}',
    now(),
    now(),
    '',
    '',
    '',
    ''
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    '00000000-0000-0000-0000-000000000011',
    'authenticated',
    'authenticated',
    'profile-other@example.com',
    '',
    now(),
    '{"provider":"email","providers":["email"]}',
    '{"nickname":"다른이"}',
    now(),
    now(),
    '',
    '',
    '',
    ''
  );

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000010', true);

select results_eq(
  $$select user_id from public.profiles order by user_id$$,
  $$values ('00000000-0000-0000-0000-000000000010'::uuid)$$,
  'authenticated users can only read their own profile'
);

select results_eq(
  $$update public.profiles set nickname = '새닉네임' where user_id = '00000000-0000-0000-0000-000000000010' returning nickname$$,
  $$values ('새닉네임'::text)$$,
  'authenticated users can update their own profile'
);

select results_eq(
  $$update public.profiles set nickname = '침입자' where user_id = '00000000-0000-0000-0000-000000000011' returning user_id$$,
  $$select null::uuid where false$$,
  'authenticated users cannot update another profile'
);

set local role anon;
select set_config('request.jwt.claim.sub', '', true);

select results_eq(
  $$select count(*) from public.profiles$$,
  $$values (0::bigint)$$,
  'anonymous users cannot read profiles'
);

select * from finish();

rollback;
