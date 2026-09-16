begin;

select plan(6);

select has_table('public', 'profiles', 'profiles table exists');
select col_is_pk('public', 'profiles', 'user_id', 'user_id is the primary key');
select col_is_fk('public', 'profiles', 'user_id', 'user_id references auth.users');
select has_trigger('auth', 'users', 'on_auth_user_created', 'signup trigger exists');

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
) values (
  '00000000-0000-0000-0000-000000000000',
  '00000000-0000-0000-0000-000000000001',
  'authenticated',
  'authenticated',
  'profile-test@example.com',
  '',
  now(),
  '{"provider":"email","providers":["email"]}',
  '{"nickname":"모험가"}',
  now(),
  now(),
  '',
  '',
  '',
  ''
);

select results_eq(
  $$select nickname from public.profiles where user_id = '00000000-0000-0000-0000-000000000001'$$,
  $$values ('모험가'::text)$$,
  'signup creates a profile'
);

select throws_ok(
  $$update public.profiles set nickname = 'ab' where user_id = '00000000-0000-0000-0000-000000000001'$$,
  '23514',
  null,
  'nickname must be 3 to 20 characters'
);

select * from finish();

rollback;
