begin;

select plan(30);

select has_table('public', 'character_sheets', 'character sheets table exists');
select col_is_pk('public', 'character_sheets', 'id', 'character sheet id is the primary key');
select col_is_fk('public', 'character_sheets', 'room_id', 'character sheet references its room');
select col_is_fk('public', 'character_sheets', 'owner_id', 'character sheet references its owner');
select ok(
  (select relrowsecurity from pg_class where oid = 'public.character_sheets'::regclass),
  'character sheets use row level security'
);
select ok(
  has_table_privilege('authenticated', 'public.character_sheets', 'select'),
  'authenticated users can select authorized character sheets'
);
select ok(
  has_table_privilege('authenticated', 'public.character_sheets', 'insert'),
  'authenticated users can insert authorized character sheets'
);
select ok(
  not has_table_privilege('authenticated', 'public.character_sheets', 'update'),
  'authenticated users cannot update character sheets yet'
);
select ok(
  not has_table_privilege('authenticated', 'public.character_sheets', 'delete'),
  'authenticated users cannot delete character sheets'
);
select ok(
  not has_table_privilege('anon', 'public.character_sheets', 'select'),
  'anonymous users cannot select character sheets'
);
select ok(
  not has_table_privilege('anon', 'public.character_sheets', 'insert'),
  'anonymous users cannot insert character sheets'
);

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, confirmation_token, email_change,
  recovery_token, email_change_token_new
) values
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000d0', 'authenticated', 'authenticated', 'sheet-master@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"시트마스터"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000d1', 'authenticated', 'authenticated', 'sheet-player@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"시트플레이어"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000d2', 'authenticated', 'authenticated', 'sheet-peer@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"같은룸플레이어"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000d3', 'authenticated', 'authenticated', 'sheet-spectator@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"시트관전자"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000d4', 'authenticated', 'authenticated', 'other-sheet-master@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"다른룸마스터"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000d5', 'authenticated', 'authenticated', 'sheet-outsider@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"시트외부인"}', '', '', '', '');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d0', true);

create temporary table test_room as
select created.* from public.create_room('캐릭터 시트 테스트 룸', null, 'D&D 5e') as created;

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d4', true);

create temporary table other_room as
select created.* from public.create_room('다른 캐릭터 시트 룸', null, 'CoC 7th') as created;

set local role postgres;

insert into public.room_members (room_id, user_id, role) values
  ((select id from test_room), '00000000-0000-0000-0000-0000000000d1', 'player'),
  ((select id from test_room), '00000000-0000-0000-0000-0000000000d2', 'player'),
  ((select id from test_room), '00000000-0000-0000-0000-0000000000d3', 'spectator');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d1', true);

select lives_ok(
  $$insert into public.character_sheets (room_id, owner_id, name, system, attributes) values ((select id from test_room), '00000000-0000-0000-0000-0000000000d1', '엘리온', 'dnd_5e', '{"STR":16,"DEX":14,"CON":13,"INT":12,"WIS":10,"CHA":8}')$$,
  'players can save D&D 5e sheets'
);

select lives_ok(
  $$insert into public.character_sheets (room_id, owner_id, name, system, attributes) values ((select id from test_room), '00000000-0000-0000-0000-0000000000d1', '탐사자', 'coc_7e', '{"STR":50,"CON":55,"SIZ":60,"DEX":65,"APP":45,"INT":70,"POW":75,"EDU":80}')$$,
  'players can save CoC 7th sheets'
);

select lives_ok(
  $$insert into public.character_sheets (room_id, owner_id, name, system, attributes) values ((select id from test_room), '00000000-0000-0000-0000-0000000000d1', '자유 양식', 'custom', '{"공포":12,"메모":"사용자 정의 값"}')$$,
  'players can save custom sheets'
);

select results_eq(
  $$select system, attributes from public.character_sheets where owner_id = '00000000-0000-0000-0000-0000000000d1' order by system$$,
  $$values ('coc_7e'::text, '{"STR":50,"CON":55,"SIZ":60,"DEX":65,"APP":45,"INT":70,"POW":75,"EDU":80}'::jsonb), ('custom', '{"공포":12,"메모":"사용자 정의 값"}'::jsonb), ('dnd_5e', '{"STR":16,"DEX":14,"CON":13,"INT":12,"WIS":10,"CHA":8}'::jsonb)$$,
  'each template preserves its attributes when requeried'
);

select throws_ok(
  $$insert into public.character_sheets (room_id, owner_id, name, system) values ((select id from test_room), '00000000-0000-0000-0000-0000000000d1', '잘못된 시스템', 'unknown')$$,
  '23514',
  null,
  'unknown systems are rejected'
);

select throws_ok(
  $$insert into public.character_sheets (room_id, owner_id, name, system, attributes) values ((select id from test_room), '00000000-0000-0000-0000-0000000000d1', '잘못된 능력치', 'custom', '[]')$$,
  '23514',
  null,
  'non-object attributes are rejected'
);

select throws_ok(
  $$insert into public.character_sheets (room_id, owner_id, name, system) values ((select id from test_room), '00000000-0000-0000-0000-0000000000d2', '소유자 위조', 'custom')$$,
  '42501',
  null,
  'players cannot create sheets for another user'
);

select throws_ok(
  $$insert into public.character_sheets (room_id, owner_id, name, system) values ((select id from other_room), '00000000-0000-0000-0000-0000000000d1', '다른 룸 침입', 'custom')$$,
  '42501',
  null,
  'players cannot create sheets in another room'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d2', true);

select lives_ok(
  $$insert into public.character_sheets (room_id, owner_id, name, system, attributes) values ((select id from test_room), '00000000-0000-0000-0000-0000000000d2', '동료 캐릭터', 'custom', '{"행운":7}')$$,
  'another player can save their own sheet'
);

select results_eq(
  $$select name from public.character_sheets order by name$$,
  $$values ('동료 캐릭터'::text)$$,
  'players can read only their own sheets in the same room'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d1', true);

select results_eq(
  $$select count(*) from public.character_sheets$$,
  $$values (3::bigint)$$,
  'sheet owners can requery all of their sheets'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d0', true);

select results_eq(
  $$select name from public.character_sheets order by name$$,
  $$values ('동료 캐릭터'::text), ('엘리온'), ('자유 양식'), ('탐사자')$$,
  'room masters can read every sheet in their room'
);

select throws_ok(
  $$insert into public.character_sheets (room_id, owner_id, name, system) values ((select id from test_room), '00000000-0000-0000-0000-0000000000d0', '마스터 생성', 'custom')$$,
  '42501',
  null,
  'masters cannot create player sheets'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d3', true);

select results_eq(
  $$select count(*) from public.character_sheets$$,
  $$values (0::bigint)$$,
  'spectators cannot read character sheets'
);

select throws_ok(
  $$insert into public.character_sheets (room_id, owner_id, name, system) values ((select id from test_room), '00000000-0000-0000-0000-0000000000d3', '관전자 생성', 'custom')$$,
  '42501',
  null,
  'spectators cannot create character sheets'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d4', true);

select results_eq(
  $$select count(*) from public.character_sheets$$,
  $$values (0::bigint)$$,
  'members of another room cannot read character sheets'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d5', true);

select results_eq(
  $$select count(*) from public.character_sheets$$,
  $$values (0::bigint)$$,
  'non-members cannot read character sheets'
);

set local role postgres;

update public.room_members
set status = 'left'
where room_id = (select id from test_room)
  and user_id = '00000000-0000-0000-0000-0000000000d1';

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d1', true);

select results_eq(
  $$select count(*) from public.character_sheets$$,
  $$values (0::bigint)$$,
  'departed owners cannot read their former room sheets'
);

set local role anon;
select set_config('request.jwt.claim.sub', '', true);

select throws_ok(
  $$select count(*) from public.character_sheets$$,
  '42501',
  null,
  'anonymous users cannot read character sheets'
);

select * from finish();

rollback;
