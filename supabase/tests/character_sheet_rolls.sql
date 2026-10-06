begin;

select plan(38);

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

insert into public.character_sheets (room_id, owner_id, name, system, attributes)
values ((select id from other_room), '00000000-0000-0000-0000-0000000000d4', '다른 룸 캐릭터', 'custom', '{"행운":10}');

set local role postgres;
insert into public.character_sheets(id, room_id, owner_id, name, system, attributes, skills) values
('10000000-0000-0000-0000-000000000001', (select id from test_room), '00000000-0000-0000-0000-0000000000d1', '엘리온', 'dnd_5e', '{"STR":16,"DEX":9}', '{}'),
('10000000-0000-0000-0000-000000000002', (select id from test_room), '00000000-0000-0000-0000-0000000000d1', '탐사자', 'coc_7e', '{}', '{"관찰력":60,"문자":"abc","소수":1.5}');
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d1', true);
-- Server-derived expressions and roll-time metadata.
create temporary table dnd_roll as select * from public.roll_character_sheet((select id from test_room), '10000000-0000-0000-0000-000000000001', 'attribute', 'STR');
create temporary table coc_roll as select * from public.roll_character_sheet((select id from test_room), '10000000-0000-0000-0000-000000000002', 'skill', '관찰력', 'private');
select is(
  (select character_sheet_id from dnd_roll),
  '10000000-0000-0000-0000-000000000001'::uuid,
  'DND log links the selected sheet'
);

select ok(
  (select stored.sheet_roll = returned.sheet_roll from public.dice_rolls stored join dnd_roll returned using(id)),
  'RPC metadata matches stored log'
);

select ok(
  (select total = (individual_results->>0)::bigint + 3 from dnd_roll),
  'DND total applies the server modifier'
);

select is(
  (select expression from dnd_roll),
  '1d20+3',
  'DND server modifier'
);

select is(
  (select sheet_roll->>'value' from dnd_roll),
  '16',
  'DND score snapshot'
);

select is(
  (select sheet_roll->>'modifier' from dnd_roll),
  '3',
  'DND modifier snapshot'
);

select is(
  (select expression from coc_roll),
  '1d100',
  'CoC expression'
);

select is(
  (select sheet_roll->>'value' from coc_roll),
  '60',
  'CoC target snapshot'
);

select is(
  (select visibility from coc_roll),
  'private',
  'private roll scope'
);

select ok(
  (select total between 1 and 100 from coc_roll),
  'CoC roll range'
);

select is(
  (select expression from public.roll_character_sheet((select id from test_room), '10000000-0000-0000-0000-000000000001', 'attribute', 'DEX')),
  '1d20-1',
  'negative modifier floors correctly'
);

select throws_ok(
  $q$select public.roll_character_sheet((select id from test_room), '10000000-0000-0000-0000-000000000002','skill','missing')$q$,
  '22023',
  'sheet roll item must be numeric',
  'missing item rejected'
);

select throws_ok(
  $q$select public.roll_character_sheet((select id from test_room), '10000000-0000-0000-0000-000000000002','skill','문자')$q$,
  '22023',
  'sheet roll item must be numeric',
  'string item rejected'
);

select throws_ok(
  $q$select public.roll_character_sheet((select id from test_room), '10000000-0000-0000-0000-000000000002','skill','소수')$q$,
  '22023',
  'invalid sheet roll item value',
  'fraction rejected'
);

select throws_ok(
  $q$select public.roll_character_sheet((select id from other_room), '10000000-0000-0000-0000-000000000001','attribute','STR')$q$,
  '42501',
  'dice roll permission required',
  'other room rejected'
);

select throws_ok(
  $q$select public.roll_character_sheet((select id from test_room), '10000000-0000-0000-0000-000000000099','attribute','STR')$q$,
  '42501',
  'character sheet roll permission required',
  'invalid character rejected'
);

-- Later edits must not rewrite history.
update public.character_sheets set attributes = '{"STR":8}' where id = '10000000-0000-0000-0000-000000000001';
update public.character_sheets set skills = '{"관찰력":40}' where id = '10000000-0000-0000-0000-000000000002';
select is(
  (select sheet_roll->>'value' from public.dice_rolls where id = (select id from dnd_roll)),
  '16',
  'DND snapshot survives editing'
);

select is(
  (select sheet_roll->>'value' from public.dice_rolls where id = (select id from coc_roll)),
  '60',
  'CoC snapshot survives editing'
);

select ok(
  (select sheet_roll is null and character_sheet_id is null from public.roll_dice((select id from test_room), '1d1')),
  'ordinary rolls keep empty references'
);

-- Public metadata follows log access, while full sheets and private details stay protected.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d2', true);
select is(
  (select count(*) from public.character_sheets where id = '10000000-0000-0000-0000-000000000001'),
  0::bigint,
  'peer cannot read sheet'
);

select is(
  (select sheet_roll->>'character_name' from public.dice_rolls where id = (select id from dnd_roll)),
  '엘리온',
  'peer can read public snapshot'
);

select is(
  (select count(*) from public.dice_rolls where id = (select id from coc_roll)),
  0::bigint,
  'peer cannot read private snapshot'
);

select is(
  (select count(*) from public.dice_roll_notifications where id = (select id from coc_roll)),
  1::bigint,
  'peer gets only private notification'
);

select throws_ok(
  $q$select public.roll_character_sheet((select id from test_room), '10000000-0000-0000-0000-000000000001','attribute','STR')$q$,
  '42501',
  'character sheet roll permission required',
  'peer cannot roll another character'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d0', true);
select lives_ok(
  $q$select public.roll_character_sheet((select id from test_room), '10000000-0000-0000-0000-000000000001','attribute','STR')$q$,
  'master can use player sheet'
);

select is(
  (select count(*) from public.dice_rolls where id = (select id from coc_roll)),
  1::bigint,
  'master sees private snapshot'
);

set local role postgres;
select ok(
  not has_function_privilege('anon','public.roll_character_sheet(uuid,uuid,text,text,text)','execute'),
  'anon has no RPC permission'
);

select ok(
  not has_function_privilege('authenticated','private.insert_dice_roll(uuid,text,uuid,jsonb)','execute'),
  'metadata helper is internal'
);

select ok(
  not exists(select 1 from information_schema.columns where table_schema='public' and table_name='dice_roll_notifications' and column_name in ('sheet_roll','character_sheet_id')),
  'notifications have no sheet metadata'
);


set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d1', true);
select throws_ok(
  $q$select public.roll_character_sheet((select id from test_room), '10000000-0000-0000-0000-000000000001','attribute','STR',null)$q$,
  '22023',
  'invalid dice visibility',
  'null visibility rejected'
);

select throws_ok(
  $q$select public.roll_character_sheet((select id from test_room), '10000000-0000-0000-0000-000000000001',null,'STR')$q$,
  '22023',
  'unsupported sheet roll item',
  'null kind rejected'
);

select throws_ok(
  $q$select public.roll_character_sheet((select id from test_room), '10000000-0000-0000-0000-000000000001','attribute',null)$q$,
  '22023',
  'unsupported sheet roll item',
  'null key rejected'
);

select set_config('app.dice_roll_visibility', 'public', true);
select public.roll_character_sheet((select id from test_room), '10000000-0000-0000-0000-000000000002','skill','관찰력','private');
select is(
  current_setting('app.dice_roll_visibility'),
  'public',
  'visibility context restored'
);

select is(
  (select visibility from public.roll_dice((select id from test_room),'1d1')),
  'public',
  'ordinary roll after private sheet roll stays public'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d0', true);
select public.set_room_feature_permission((select id from test_room),'dice',false,'player');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d1', true);
select throws_ok(
  $q$select public.roll_character_sheet((select id from test_room), '10000000-0000-0000-0000-000000000001','attribute','STR')$q$,
  '42501',
  'dice roll permission required',
  'revoked dice permission rejects sheet roll'
);

set local role postgres;
insert into public.room_members(room_id,user_id,role) values ((select id from other_room),'00000000-0000-0000-0000-0000000000d1','player');
set local role authenticated;
select throws_ok(
  $q$select public.roll_character_sheet((select id from other_room), '10000000-0000-0000-0000-000000000001','attribute','STR')$q$,
  '42501',
  'character sheet roll permission required',
  'cross-room sheet rejected even when member of both'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d0', true);
create temporary table deletion_roll as select * from public.roll_character_sheet((select id from test_room),'10000000-0000-0000-0000-000000000001','attribute','STR');
set local role postgres;
delete from public.character_sheets where id = '10000000-0000-0000-0000-000000000001';
select ok(
  (select character_sheet_id is null and sheet_roll->>'character_name' = '엘리온' from public.dice_rolls where id = (select id from deletion_roll)),
  'sheet deletion preserves snapshot and clears reference'
);

select set_config('request.jwt.claim.sub', '', true);
select throws_ok(
  $q$select public.roll_character_sheet((select id from test_room),'10000000-0000-0000-0000-000000000002','skill','관찰력')$q$,
  '42501',
  'authentication required',
  'missing identity rejected'
);


select * from finish();
rollback;
