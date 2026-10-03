begin;

select plan(32);

select has_table('public', 'map_visibility', 'map visibility table exists');
select has_column('public', 'room_maps', 'fog_enabled', 'room maps can enable fog');
select has_column('public', 'map_visibility', 'inherits_common', 'personal visibility can restore common visibility');
select col_is_fk('public', 'map_visibility', 'map_id', 'map visibility references its map');
select col_is_fk('public', 'map_visibility', 'room_member_id', 'member visibility references its user');
select has_function('public', 'set_map_fog_enabled', array['uuid', 'boolean'], 'fog state function exists');

select ok(
  has_table_privilege('authenticated', 'public.map_visibility', 'select'),
  'authenticated users can read authorized visibility rows'
);

select ok(
  not has_table_privilege('authenticated', 'public.map_visibility', 'delete'),
  'clients cannot delete visibility rows that would bypass Realtime RLS'
);

select ok(
  has_function_privilege('authenticated', 'public.set_map_fog_enabled(uuid, boolean)', 'execute'),
  'authenticated users can request fog state changes'
);

select ok(
  not has_function_privilege('anon', 'public.set_map_fog_enabled(uuid, boolean)', 'execute'),
  'anonymous users cannot request fog state changes'
);

select results_eq(
  $$select count(*) from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename in ('room_maps', 'map_visibility')$$,
  $$values (2::bigint)$$,
  'map and visibility changes are published to Realtime'
);

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, confirmation_token, email_change,
  recovery_token, email_change_token_new
) values
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000d0', 'authenticated', 'authenticated', 'visibility-master@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"시야마스터"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000d1', 'authenticated', 'authenticated', 'visibility-player@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"시야플레이어"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000d2', 'authenticated', 'authenticated', 'visibility-other-player@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"다른시야플레이어"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000d3', 'authenticated', 'authenticated', 'visibility-spectator@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"시야관전자"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000d4', 'authenticated', 'authenticated', 'visibility-outsider@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"시야외부인"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000d7', 'authenticated', 'authenticated', 'visibility-co-master@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"시야공동마스터"}', '', '', '', '');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d0', true);

create temporary table test_room as
select created.*
from public.create_room('시야 정책 테스트 룸', null, 'D&D 5e') as created;

set local role postgres;

insert into public.room_members (room_id, user_id, role) values
  ((select id from test_room), '00000000-0000-0000-0000-0000000000d1', 'player'),
  ((select id from test_room), '00000000-0000-0000-0000-0000000000d2', 'player'),
  ((select id from test_room), '00000000-0000-0000-0000-0000000000d3', 'spectator'),
  ((select id from test_room), '00000000-0000-0000-0000-0000000000d7', 'master');

insert into public.assets (id, owner_id, category, storage_path)
values ('00000000-0000-0000-0000-0000000000d5', '00000000-0000-0000-0000-0000000000d0', 'map', '00000000-0000-0000-0000-0000000000d0/map.png');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d0', true);

insert into public.room_maps (id, room_id, asset_id)
values ('00000000-0000-0000-0000-0000000000d6', (select id from test_room), '00000000-0000-0000-0000-0000000000d5');

select lives_ok(
  $$insert into public.map_visibility (map_id, scope, revealed_areas) values ('00000000-0000-0000-0000-0000000000d6', 'all', '[{"x":0,"y":0,"width":100,"height":100}]')$$,
  'masters can create common visibility'
);

select lives_ok(
  $$insert into public.map_visibility (map_id, room_member_id, scope, revealed_areas) values ('00000000-0000-0000-0000-0000000000d6', '00000000-0000-0000-0000-0000000000d1', 'member', '[{"x":10,"y":20,"width":30,"height":40}]')$$,
  'masters can create player visibility'
);

select lives_ok(
  $$insert into public.map_visibility (map_id, room_member_id, scope, revealed_areas) values ('00000000-0000-0000-0000-0000000000d6', '00000000-0000-0000-0000-0000000000d2', 'member', '[{"x":50,"y":60,"width":70,"height":80}]')$$,
  'masters can create another player visibility'
);

select results_eq(
  $$update public.map_visibility set revealed_areas = '[{"x":1,"y":2,"width":3,"height":4}]' where room_member_id = '00000000-0000-0000-0000-0000000000d1' returning revealed_areas$$,
  $$values ('[{"x":1,"y":2,"width":3,"height":4}]'::jsonb)$$,
  'masters can change player visibility'
);

select results_eq(
  $$update public.map_visibility set inherits_common = true where room_member_id = '00000000-0000-0000-0000-0000000000d1' returning inherits_common$$,
  $$values (true)$$,
  'masters can restore common visibility for a player'
);

select throws_ok(
  $$update public.map_visibility set inherits_common = true where scope = 'all'$$,
  '23514',
  null,
  'common visibility cannot inherit itself'
);

select throws_ok(
  $$insert into public.map_visibility (map_id, room_member_id, scope, revealed_areas) values ('00000000-0000-0000-0000-0000000000d6', '00000000-0000-0000-0000-0000000000d3', 'member', '[]')$$,
  '42501',
  null,
  'masters cannot create personal visibility for spectators'
);

select throws_ok(
  $$update public.map_visibility set revealed_areas = '[{"x":0,"y":0,"width":0,"height":10}]' where scope = 'all'$$,
  '23514',
  null,
  'invalid revealed rectangles are rejected'
);

select results_eq(
  $$update public.room_maps set fog_enabled = true where id = '00000000-0000-0000-0000-0000000000d6' returning fog_enabled$$,
  $$values (true)$$,
  'map asset owners can enable fog directly'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d7', true);

select lives_ok(
  $$select public.set_map_fog_enabled('00000000-0000-0000-0000-0000000000d6', false)$$,
  'co-masters can change fog through the authorized function'
);

select results_eq(
  $$select fog_enabled from public.room_maps where id = '00000000-0000-0000-0000-0000000000d6'$$,
  $$values (false)$$,
  'co-master fog changes are persisted'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d0', true);

select results_eq(
  $$select count(*) from public.map_visibility$$,
  $$values (3::bigint)$$,
  'masters can read every visibility row'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d1', true);

select throws_ok(
  $$select public.set_map_fog_enabled('00000000-0000-0000-0000-0000000000d6', true)$$,
  '42501',
  'master role required',
  'players cannot change fog through the function'
);

select results_eq(
  $$select scope, room_member_id, inherits_common from public.map_visibility order by scope, room_member_id nulls first$$,
  $$values ('all'::text, null::uuid, false), ('member'::text, '00000000-0000-0000-0000-0000000000d1'::uuid, true)$$,
  'players can read common visibility and their personal inheritance state only'
);

select results_eq(
  $$select count(*) from public.map_visibility where room_member_id = '00000000-0000-0000-0000-0000000000d2'$$,
  $$values (0::bigint)$$,
  'players cannot query another players visibility directly'
);

select results_eq(
  $$update public.map_visibility set revealed_areas = '[]' where scope = 'all' returning id$$,
  $$select null::uuid where false$$,
  'players cannot change visibility'
);

select results_eq(
  $$select fog_enabled from public.room_maps where id = '00000000-0000-0000-0000-0000000000d6'$$,
  $$values (false)$$,
  'players can read the fog state'
);

select results_eq(
  $$update public.room_maps set fog_enabled = false where id = '00000000-0000-0000-0000-0000000000d6' returning fog_enabled$$,
  $$select null::boolean where false$$,
  'players cannot change the fog state'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d2', true);

select results_eq(
  $$select room_member_id from public.map_visibility where scope = 'member'$$,
  $$values ('00000000-0000-0000-0000-0000000000d2'::uuid)$$,
  'each player receives only their personal visibility'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d3', true);

select results_eq(
  $$select scope from public.map_visibility$$,
  $$values ('all'::text)$$,
  'spectators receive common visibility only'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d4', true);

select results_eq(
  $$select count(*) from public.map_visibility$$,
  $$values (0::bigint)$$,
  'outsiders cannot read visibility'
);

select * from finish();

rollback;
