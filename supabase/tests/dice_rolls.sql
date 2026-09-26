begin;

select plan(40);

select has_table('public', 'dice_rolls', 'dice rolls table exists');
select has_function('public', 'roll_dice', array['uuid', 'text'], 'dice roll function exists');

select ok(
  has_function_privilege('authenticated', 'public.roll_dice(uuid, text)', 'execute'),
  'authenticated users can execute dice rolls'
);

select ok(
  not has_function_privilege('anon', 'public.roll_dice(uuid, text)', 'execute'),
  'anonymous users cannot execute dice rolls'
);

select ok(
  not has_function_privilege('authenticated', 'public.dice_value_from_uint32(bigint, bigint)', 'execute'),
  'clients cannot call the internal dice mapping function'
);

select ok(
  has_table_privilege('authenticated', 'public.dice_rolls', 'select'),
  'authenticated users can read authorized dice rolls'
);

select ok(
  not has_table_privilege('authenticated', 'public.dice_rolls', 'insert'),
  'authenticated users cannot insert dice rolls directly'
);

select results_eq(
  $$select public.dice_value_from_uint32(raw_value, 6) from generate_series(0::bigint, 5::bigint) as values(raw_value) order by raw_value$$,
  $$values (1::bigint), (2::bigint), (3::bigint), (4::bigint), (5::bigint), (6::bigint)$$,
  'raw values map to every die face'
);

select is(
  public.dice_value_from_uint32(4294967291, 6),
  6::bigint,
  'the last unbiased d6 value is accepted'
);

select is(
  public.dice_value_from_uint32(4294967292, 6),
  null::bigint,
  'the first biased d6 value is rejected'
);

select is(
  public.dice_value_from_uint32(4294967295, 6),
  null::bigint,
  'the end of the d6 rejection range is rejected'
);

select is(
  public.dice_value_from_uint32(4294967295, 4294967296),
  4294967296::bigint,
  'the full unsigned 32-bit range maps without rejection'
);

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, confirmation_token, email_change,
  recovery_token, email_change_token_new
) values
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000c0', 'authenticated', 'authenticated', 'dice-master@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"다이스마스터"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000c1', 'authenticated', 'authenticated', 'dice-player@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"다이스플레이어"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000c2', 'authenticated', 'authenticated', 'dice-spectator@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"다이스관전자"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000c3', 'authenticated', 'authenticated', 'dice-outsider@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"다이스외부인"}', '', '', '', '');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c0', true);

create temporary table test_room as
select created.*
from public.create_room('주사위 테스트 룸', null, 'D&D 5e') as created;

set local role postgres;

insert into public.room_members (room_id, user_id, role) values
  ((select id from test_room), '00000000-0000-0000-0000-0000000000c1', 'player'),
  ((select id from test_room), '00000000-0000-0000-0000-0000000000c2', 'spectator');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c0', true);

create temporary table returned_roll as
select * from public.roll_dice((select id from test_room), '/roll 2d6+3');

select ok(
  exists (
    select 1
    from returned_roll as returned
    join public.dice_rolls as stored using (id)
    where returned.roller_id = '00000000-0000-0000-0000-0000000000c0'
      and returned.expression = '/roll 2d6+3'
      and jsonb_array_length(returned.individual_results) = 2
      and returned.total = (
        select sum(value::bigint) + 3
        from jsonb_array_elements_text(returned.individual_results) as results(value)
      )
  ),
  'masters receive the same standard roll that is stored'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', true);

select lives_ok(
  $$select public.roll_dice((select id from test_room), '4d6kH3')$$,
  'players can roll with keep highest'
);

select ok(
  exists (
    select 1
    from public.dice_rolls
    where roller_id = '00000000-0000-0000-0000-0000000000c1'
      and expression = '4d6kH3'
      and total = (
        select sum(value::bigint)
        from (
          select value
          from jsonb_array_elements_text(individual_results) as results(value)
          order by value::bigint desc
          limit 3
        ) as kept
      )
  ),
  'keep highest totals the highest results'
);

select lives_ok(
  $$select public.roll_dice((select id from test_room), '4d6kL2-1')$$,
  'players can roll with keep lowest and a penalty'
);

select ok(
  exists (
    select 1
    from public.dice_rolls
    where roller_id = '00000000-0000-0000-0000-0000000000c1'
      and expression = '4d6kL2-1'
      and total = (
        select sum(value::bigint) - 1
        from (
          select value
          from jsonb_array_elements_text(individual_results) as results(value)
          order by value::bigint
          limit 2
        ) as kept
      )
  ),
  'keep lowest totals the lowest results before the penalty'
);

select lives_ok(
  $$select public.roll_dice((select id from test_room), '100d1')$$,
  'the maximum dice count is accepted'
);

select ok(
  exists (
    select 1
    from public.dice_rolls
    where expression = '100d1'
      and jsonb_array_length(individual_results) = 100
      and total = 100
  ),
  'the maximum dice count stores every result'
);

select lives_ok(
  $$select public.roll_dice((select id from test_room), '1d4294967296')$$,
  'the maximum side count is accepted'
);

select ok(
  exists (
    select 1
    from public.dice_rolls
    where expression = '1d4294967296'
      and (individual_results ->> 0)::bigint between 1 and 4294967296
      and total = (individual_results ->> 0)::bigint
  ),
  'the maximum side count remains within range'
);

select lives_ok(
  $$select public.roll_dice((select id from test_room), '1d1-9223372036854775808')$$,
  'a modifier at the bigint minimum is accepted when the total fits'
);

select results_eq(
  $$select total from public.dice_rolls where expression = '1d1-9223372036854775808'$$,
  $$values ('-9223372036854775807'::bigint)$$,
  'the bigint boundary total is stored without overflow'
);

select throws_ok(
  $$select public.roll_dice((select id from test_room), '2d')$$,
  '22023',
  'invalid dice expression',
  'invalid syntax is rejected'
);

select throws_ok(
  $$select public.roll_dice((select id from test_room), '0d6')$$,
  '22023',
  'dice count must be between 1 and 100',
  'zero dice are rejected'
);

select throws_ok(
  $$select public.roll_dice((select id from test_room), '101d6')$$,
  '22023',
  'dice count must be between 1 and 100',
  'more than 100 dice are rejected'
);

select throws_ok(
  $$select public.roll_dice((select id from test_room), '1d0')$$,
  '22023',
  'dice sides must be between 1 and 4294967296',
  'zero-sided dice are rejected'
);

select throws_ok(
  $$select public.roll_dice((select id from test_room), '1d4294967297')$$,
  '22023',
  'dice sides must be between 1 and 4294967296',
  'side counts beyond the random range are rejected'
);

select throws_ok(
  $$select public.roll_dice((select id from test_room), '4d6kH0')$$,
  '22023',
  'keep count must be between 1 and dice count',
  'zero kept dice are rejected'
);

select throws_ok(
  $$select public.roll_dice((select id from test_room), '4d6kL5')$$,
  '22023',
  'keep count must be between 1 and dice count',
  'keeping more than the dice count is rejected'
);

select throws_ok(
  $$select public.roll_dice((select id from test_room), '1d1+9223372036854775808')$$,
  '22023',
  'dice modifier is outside the supported range',
  'modifiers above bigint are rejected'
);

select throws_ok(
  $$select public.roll_dice((select id from test_room), '1d1-9223372036854775809')$$,
  '22023',
  'dice modifier is outside the supported range',
  'modifiers below bigint are rejected'
);

select throws_ok(
  $$select public.roll_dice((select id from test_room), '1d4294967296+9223372036854775807')$$,
  '22023',
  'dice total is outside the supported range',
  'possible totals above bigint are rejected'
);

select results_eq(
  $$select count(*) from public.dice_rolls where room_id = (select id from test_room)$$,
  $$values (6::bigint)$$,
  'invalid rolls do not leave logs'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c2', true);

select throws_ok(
  $$select public.roll_dice((select id from test_room), '1d20')$$,
  '42501',
  'dice roll permission required',
  'spectators cannot roll dice'
);

select results_eq(
  $$select count(*) from public.dice_rolls where room_id = (select id from test_room)$$,
  $$values (6::bigint)$$,
  'spectators can read existing dice rolls'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c3', true);

select throws_ok(
  $$select public.roll_dice((select id from test_room), '1d20')$$,
  '42501',
  'dice roll permission required',
  'non-members cannot roll dice'
);

select results_eq(
  $$select count(*) from public.dice_rolls$$,
  $$values (0::bigint)$$,
  'non-members cannot read dice rolls'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', true);

select throws_ok(
  $$insert into public.dice_rolls (room_id, roller_id, expression, individual_results, total) values ((select id from test_room), '00000000-0000-0000-0000-0000000000c1', '1d20', '[20]', 20)$$,
  '42501',
  null,
  'clients cannot insert chosen dice results'
);

select results_eq(
  $$select count(*) from public.dice_rolls where room_id = (select id from test_room)$$,
  $$values (6::bigint)$$,
  'permission failures do not leave logs'
);

select * from finish();

rollback;
