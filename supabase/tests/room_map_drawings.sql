begin;

select plan(37);

select has_table('public', 'room_map_drawings', 'room map drawings table exists');
select col_is_pk('public', 'room_map_drawings', 'id', 'drawing id is the primary key');
select col_is_fk('public', 'room_map_drawings', 'map_id', 'drawing references its map');
select has_column('public', 'room_map_drawings', 'drawing_type', 'drawing stores its type');
select has_column('public', 'room_map_drawings', 'geometry', 'drawing stores its geometry');
select has_column('public', 'room_map_drawings', 'text_content', 'drawing stores optional text');
select has_column('public', 'room_map_drawings', 'color', 'drawing stores its color');
select has_column('public', 'room_map_drawings', 'stroke_width', 'drawing stores its stroke width');
select has_function(
  'private',
  'broadcast_room_map_drawing_changes',
  array[]::text[],
  'drawing Broadcast trigger function exists'
);
select has_trigger(
  'public',
  'room_map_drawings',
  'broadcast_room_map_drawing_changes',
  'drawing changes invoke the Broadcast trigger'
);

select ok(
  has_table_privilege('authenticated', 'public.room_map_drawings', 'select'),
  'authenticated users can read authorized drawing rows'
);
select ok(
  has_column_privilege('authenticated', 'public.room_map_drawings', 'map_id', 'insert')
    and has_column_privilege('authenticated', 'public.room_map_drawings', 'geometry', 'insert')
    and not has_column_privilege('authenticated', 'public.room_map_drawings', 'created_at', 'insert'),
  'authenticated users can insert drawing state but cannot choose timestamps'
);
select ok(
  has_column_privilege('authenticated', 'public.room_map_drawings', 'geometry', 'update')
    and has_column_privilege('authenticated', 'public.room_map_drawings', 'color', 'update')
    and not has_column_privilege('authenticated', 'public.room_map_drawings', 'map_id', 'update')
    and not has_column_privilege('authenticated', 'public.room_map_drawings', 'created_at', 'update'),
  'authenticated users can update drawing state but cannot move rows between maps or change timestamps'
);
select ok(
  not has_table_privilege('anon', 'public.room_map_drawings', 'select'),
  'anonymous users cannot read drawings'
);
select results_eq(
  $$select count(*) from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'room_map_drawings'$$,
  $$values (0::bigint)$$,
  'drawings avoid Postgres Changes because DELETE events bypass RLS'
);

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, confirmation_token, email_change,
  recovery_token, email_change_token_new
) values
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000150', 'authenticated', 'authenticated', 'drawing-master@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"그리기마스터"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000151', 'authenticated', 'authenticated', 'drawing-player@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"그리기플레이어"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000152', 'authenticated', 'authenticated', 'drawing-spectator@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"그리기관전자"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000153', 'authenticated', 'authenticated', 'drawing-outsider@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"그리기외부인"}', '', '', '', '');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000150', true);

create temporary table test_room as
select created.*
from public.create_room('그리기 정책 테스트 룸', null, 'D&D 5e') as created;

set local role postgres;

insert into public.room_members (room_id, user_id, role) values
  ((select id from test_room), '00000000-0000-0000-0000-000000000151', 'player'),
  ((select id from test_room), '00000000-0000-0000-0000-000000000152', 'spectator');

insert into public.assets (id, owner_id, category, storage_path)
values (
  '00000000-0000-0000-0000-000000000154',
  '00000000-0000-0000-0000-000000000150',
  'map',
  '00000000-0000-0000-0000-000000000150/drawing-map.png'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000150', true);

insert into public.room_maps (id, room_id, asset_id)
values (
  '00000000-0000-0000-0000-000000000155',
  (select id from test_room),
  '00000000-0000-0000-0000-000000000154'
);

select lives_ok(
  $$insert into public.room_map_drawings (id, map_id, drawing_type, geometry, text_content, color, stroke_width) values
    ('00000000-0000-0000-0000-000000000160', '00000000-0000-0000-0000-000000000155', 'line', '{"start":{"x":1,"y":2},"end":{"x":3,"y":4}}', null, '#112233', 2),
    ('00000000-0000-0000-0000-000000000161', '00000000-0000-0000-0000-000000000155', 'circle', '{"center":{"x":5,"y":6},"radius":7}', null, '#223344', 3),
    ('00000000-0000-0000-0000-000000000162', '00000000-0000-0000-0000-000000000155', 'rectangle', '{"x":8,"y":9,"width":10,"height":11}', null, '#334455', 4),
    ('00000000-0000-0000-0000-000000000163', '00000000-0000-0000-0000-000000000155', 'freehand', '{"points":[{"x":12,"y":13},{"x":14,"y":15}]}', null, '#445566', 5),
    ('00000000-0000-0000-0000-000000000164', '00000000-0000-0000-0000-000000000155', 'text', '{"x":16,"y":17}', '지도 메모', '#556677', 6)$$,
  'masters can create every supported drawing type'
);

select results_eq(
  $$select drawing_type, color, stroke_width, text_content from public.room_map_drawings order by id$$,
  $$values
    ('line'::text, '#112233'::text, 2::numeric, null::text),
    ('circle'::text, '#223344'::text, 3::numeric, null::text),
    ('rectangle'::text, '#334455'::text, 4::numeric, null::text),
    ('freehand'::text, '#445566'::text, 5::numeric, null::text),
    ('text'::text, '#556677'::text, 6::numeric, '지도 메모'::text)$$,
  'drawing types and common style fields are persisted'
);

select results_eq(
  $$update public.room_map_drawings set geometry = '{"start":{"x":20,"y":21},"end":{"x":22,"y":23}}', color = '#AABBCC', stroke_width = 8 where id = '00000000-0000-0000-0000-000000000160' returning geometry, color, stroke_width$$,
  $$values ('{"end":{"x":22,"y":23},"start":{"x":20,"y":21}}'::jsonb, '#AABBCC'::text, 8::numeric)$$,
  'masters can update drawing geometry and style'
);

select lives_ok(
  $$delete from public.room_map_drawings where id = '00000000-0000-0000-0000-000000000164'$$,
  'masters can delete drawings'
);

select throws_ok(
  $$insert into public.room_map_drawings (map_id, drawing_type, geometry, color, stroke_width) values ('00000000-0000-0000-0000-000000000155', 'polygon', '{}', '#112233', 2)$$,
  '23514',
  null,
  'unsupported drawing types are rejected'
);

select throws_ok(
  $$insert into public.room_map_drawings (map_id, drawing_type, geometry, color, stroke_width) values ('00000000-0000-0000-0000-000000000155', 'line', '[]', '#112233', 2)$$,
  '23514',
  null,
  'drawing geometry must be an object'
);

select throws_ok(
  $$insert into public.room_map_drawings (map_id, drawing_type, geometry, color, stroke_width) values ('00000000-0000-0000-0000-000000000155', 'line', '{}', 'red', 2)$$,
  '23514',
  null,
  'drawing colors must be six digit hex values'
);

select throws_ok(
  $$insert into public.room_map_drawings (map_id, drawing_type, geometry, color, stroke_width) values ('00000000-0000-0000-0000-000000000155', 'line', '{}', '#112233', 0)$$,
  '23514',
  null,
  'drawing stroke width must be positive'
);

select throws_ok(
  $$insert into public.room_map_drawings (map_id, drawing_type, geometry, text_content, color, stroke_width) values ('00000000-0000-0000-0000-000000000155', 'text', '{}', null, '#112233', 2)$$,
  '23514',
  null,
  'text drawings require content'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000151', true);

select results_eq(
  $$select count(*) from public.room_map_drawings$$,
  $$values (4::bigint)$$,
  'active players can read room drawings'
);

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000151","is_anonymous":false}', true);
select set_config('realtime.topic', 'room:' || (select id from test_room) || ':drawings', true);

select results_eq(
  $$select count(*) > 0 from realtime.messages where topic = (select realtime.topic()) and extension = 'broadcast'$$,
  $$values (true)$$,
  'active room members receive persisted drawing changes over private Broadcast'
);

select throws_ok(
  $$insert into public.room_map_drawings (map_id, drawing_type, geometry, color, stroke_width) values ('00000000-0000-0000-0000-000000000155', 'line', '{}', '#112233', 2)$$,
  '42501',
  'new row violates row-level security policy for table "room_map_drawings"',
  'players cannot draw before permission is granted'
);

select results_eq(
  $$update public.room_map_drawings set color = '#ABCDEF' where id = '00000000-0000-0000-0000-000000000160' returning color$$,
  $$select null::text where false$$,
  'players cannot update drawings before permission is granted'
);

select results_eq(
  $$delete from public.room_map_drawings where id = '00000000-0000-0000-0000-000000000160' returning id$$,
  $$select null::uuid where false$$,
  'players cannot delete drawings before permission is granted'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000150', true);
select public.set_room_feature_permission(
  (select id from test_room),
  'drawing',
  true,
  'player',
  null
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000151', true);

select lives_ok(
  $$insert into public.room_map_drawings (id, map_id, drawing_type, geometry, color, stroke_width) values ('00000000-0000-0000-0000-000000000165', '00000000-0000-0000-0000-000000000155', 'freehand', '{"points":[{"x":1,"y":1},{"x":2,"y":2}]}', '#123456', 3)$$,
  'allowed players can create drawings'
);

select results_eq(
  $$update public.room_map_drawings set color = '#654321' where id = '00000000-0000-0000-0000-000000000160' returning color$$,
  $$values ('#654321'::text)$$,
  'allowed players can update drawings'
);

select results_eq(
  $$delete from public.room_map_drawings where id = '00000000-0000-0000-0000-000000000161' returning id$$,
  $$values ('00000000-0000-0000-0000-000000000161'::uuid)$$,
  'allowed players can delete drawings'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000150', true);
select public.set_room_feature_permission(
  (select id from test_room),
  'drawing',
  true,
  'spectator',
  null
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000152', true);

select results_eq(
  $$select count(*) from public.room_map_drawings$$,
  $$values (4::bigint)$$,
  'active spectators can read room drawings'
);

select throws_ok(
  $$insert into public.room_map_drawings (map_id, drawing_type, geometry, color, stroke_width) values ('00000000-0000-0000-0000-000000000155', 'circle', '{}', '#112233', 2)$$,
  '42501',
  'new row violates row-level security policy for table "room_map_drawings"',
  'spectators cannot draw even when the generic feature flag is allowed'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000153', true);

select results_eq(
  $$select count(*) from public.room_map_drawings$$,
  $$values (0::bigint)$$,
  'outsiders cannot read room drawings'
);

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000153","is_anonymous":false}', true);
select set_config('realtime.topic', 'room:' || (select id from test_room) || ':drawings', true);

select results_eq(
  $$select count(*) from realtime.messages where topic = (select realtime.topic()) and extension = 'broadcast'$$,
  $$values (0::bigint)$$,
  'outsiders cannot receive drawing Broadcast messages'
);

select throws_ok(
  $$insert into public.room_map_drawings (map_id, drawing_type, geometry, color, stroke_width) values ('00000000-0000-0000-0000-000000000155', 'rectangle', '{}', '#112233', 2)$$,
  '42501',
  'new row violates row-level security policy for table "room_map_drawings"',
  'outsiders cannot create drawings'
);

select * from finish();

rollback;
