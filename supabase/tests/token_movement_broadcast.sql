begin;

select no_plan();

select ok(not has_schema_privilege('authenticated', 'private', 'USAGE'), 'private schema remains inaccessible');

select ok(not has_function_privilege('anon', 'public.broadcast_token_movement(uuid,uuid,double precision,double precision)', 'EXECUTE'), 'unauthenticated callers cannot execute RPC');

select ok(not prosecdef, 'public RPC uses invoker privileges') from pg_proc where oid = 'public.broadcast_token_movement(uuid,uuid,double precision,double precision)'::regprocedure;

select ok(prosecdef and proconfig @> array['search_path=""'], 'private helper has definer privileges and empty search_path') from pg_proc where oid = 'private.broadcast_token_movement(uuid,uuid,double precision,double precision)'::regprocedure;

insert into auth.users (id, email, raw_user_meta_data) values ('60000000-0000-0000-0000-000000000001', 'movement-1@example.com', '{"nickname":"movement-1"}');

insert into auth.users (id, email, raw_user_meta_data) values ('60000000-0000-0000-0000-000000000002', 'movement-2@example.com', '{"nickname":"movement-2"}');

insert into auth.users (id, email, raw_user_meta_data) values ('60000000-0000-0000-0000-000000000003', 'movement-3@example.com', '{"nickname":"movement-3"}');

insert into auth.users (id, email, raw_user_meta_data) values ('60000000-0000-0000-0000-000000000004', 'movement-4@example.com', '{"nickname":"movement-4"}');

insert into auth.users (id, email, raw_user_meta_data) values ('60000000-0000-0000-0000-000000000005', 'movement-5@example.com', '{"nickname":"movement-5"}');

insert into auth.users (id, email, raw_user_meta_data) values ('60000000-0000-0000-0000-000000000006', 'movement-6@example.com', '{"nickname":"movement-6"}');

insert into public.rooms (id, creator_id, name, game_system) values ('60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000001', 'movement-10', 'test');

insert into public.rooms (id, creator_id, name, game_system) values ('60000000-0000-0000-0000-000000000011', '60000000-0000-0000-0000-000000000001', 'movement-11', 'test');

insert into public.room_members(room_id,user_id,role,status) values ('60000000-0000-0000-0000-000000000010','60000000-0000-0000-0000-000000000001','master','active');

insert into public.room_members(room_id,user_id,role,status) values ('60000000-0000-0000-0000-000000000010','60000000-0000-0000-0000-000000000002','player','active');

insert into public.room_members(room_id,user_id,role,status) values ('60000000-0000-0000-0000-000000000010','60000000-0000-0000-0000-000000000003','player','active');

insert into public.room_members(room_id,user_id,role,status) values ('60000000-0000-0000-0000-000000000010','60000000-0000-0000-0000-000000000004','spectator','active');

insert into public.room_members(room_id,user_id,role,status) values ('60000000-0000-0000-0000-000000000010','60000000-0000-0000-0000-000000000005','player','removed');

insert into public.room_members(room_id,user_id,role,status) values ('60000000-0000-0000-0000-000000000011','60000000-0000-0000-0000-000000000001','master','active');

insert into public.room_members(room_id,user_id,role,status) values ('60000000-0000-0000-0000-000000000011','60000000-0000-0000-0000-000000000002','player','active');

insert into public.assets(id,owner_id,category,storage_path) values ('60000000-0000-0000-0000-000000000020','60000000-0000-0000-0000-000000000001','map','60000000-0000-0000-0000-000000000001/20.png');

insert into public.room_maps(id,room_id,asset_id) values ('60000000-0000-0000-0000-000000000020', '60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000020');

insert into public.assets(id,owner_id,category,storage_path) values ('60000000-0000-0000-0000-000000000021','60000000-0000-0000-0000-000000000001','map','60000000-0000-0000-0000-000000000001/21.png');

insert into public.room_maps(id,room_id,asset_id) values ('60000000-0000-0000-0000-000000000021', '60000000-0000-0000-0000-000000000011', '60000000-0000-0000-0000-000000000021');

insert into public.room_tokens(id,map_id,owner_id,name,x,y) values ('60000000-0000-0000-0000-000000000030','60000000-0000-0000-0000-000000000020','60000000-0000-0000-0000-000000000002','movement-30',1,2);

insert into public.room_tokens(id,map_id,owner_id,name,x,y) values ('60000000-0000-0000-0000-000000000031','60000000-0000-0000-0000-000000000020','60000000-0000-0000-0000-000000000003','movement-31',1,2);

insert into public.room_tokens(id,map_id,owner_id,name,x,y) values ('60000000-0000-0000-0000-000000000032','60000000-0000-0000-0000-000000000020',null,'movement-32',1,2);

insert into public.room_tokens(id,map_id,owner_id,name,x,y) values ('60000000-0000-0000-0000-000000000033','60000000-0000-0000-0000-000000000021','60000000-0000-0000-0000-000000000002','movement-33',1,2);

set local role authenticated;

select set_config('request.jwt.claim.sub', '60000000-0000-0000-0000-000000000001', true);

select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000001","is_anonymous":false}', true);

select lives_ok($$select public.broadcast_token_movement('60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000030', 10, 20)$$, 'master can broadcast own-room token 30');

select lives_ok($$select public.broadcast_token_movement('60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000031', 10, 20)$$, 'master can broadcast own-room token 31');

select lives_ok($$select public.broadcast_token_movement('60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000032', 10, 20)$$, 'master can broadcast own-room token 32');

select throws_ok($$select public.broadcast_token_movement('60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000033', 10, 20)$$, '42501', 'token movement permission required', 'master cannot broadcast foreign-room token');

set local role authenticated;

select set_config('request.jwt.claim.sub', '60000000-0000-0000-0000-000000000002', true);

select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000002","is_anonymous":false}', true);

select lives_ok($$select public.broadcast_token_movement('60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000030', -1.5, 2.25)$$, 'assigned player can broadcast finite coordinates');

select throws_ok($$select public.broadcast_token_movement('60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000031', 10, 20)$$, '42501', 'token movement permission required', 'player cannot broadcast token 31');

select throws_ok($$select public.broadcast_token_movement('60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000032', 10, 20)$$, '42501', 'token movement permission required', 'player cannot broadcast token 32');

select throws_ok($$select public.broadcast_token_movement('60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000033', 10, 20)$$, '42501', 'token movement permission required', 'player cannot broadcast token 33');

select throws_ok($$select public.broadcast_token_movement('60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000099', 10, 20)$$, '42501', 'token movement permission required', 'player cannot broadcast token 99');

select throws_ok($$select public.broadcast_token_movement('60000000-0000-0000-0000-000000000011', '60000000-0000-0000-0000-000000000030', 10, 20)$$, '42501', 'token movement permission required', 'room must match token');

select throws_ok($$select public.broadcast_token_movement('60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000030', null, 20)$$, '22023', 'finite token coordinates required', 'reject invalid x null');

select throws_ok($$select public.broadcast_token_movement('60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000030', 10, null)$$, '22023', 'finite token coordinates required', 'reject invalid y null');

select throws_ok($$select public.broadcast_token_movement('60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000030', 'NaN'::float8, 20)$$, '22023', 'finite token coordinates required', 'reject invalid x NaN::float8');

select throws_ok($$select public.broadcast_token_movement('60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000030', 10, 'NaN'::float8)$$, '22023', 'finite token coordinates required', 'reject invalid y NaN::float8');

select throws_ok($$select public.broadcast_token_movement('60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000030', 'Infinity'::float8, 20)$$, '22023', 'finite token coordinates required', 'reject invalid x Infinity::float8');

select throws_ok($$select public.broadcast_token_movement('60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000030', 10, 'Infinity'::float8)$$, '22023', 'finite token coordinates required', 'reject invalid y Infinity::float8');

select throws_ok($$select public.broadcast_token_movement('60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000030', '-Infinity'::float8, 20)$$, '22023', 'finite token coordinates required', 'reject invalid x -Infinity::float8');

select throws_ok($$select public.broadcast_token_movement('60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000030', 10, '-Infinity'::float8)$$, '22023', 'finite token coordinates required', 'reject invalid y -Infinity::float8');

set local role authenticated;

select set_config('request.jwt.claim.sub', '60000000-0000-0000-0000-000000000004', true);

select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000004","is_anonymous":false}', true);

select throws_ok($$select public.broadcast_token_movement('60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000030', 10, 20)$$, '42501', 'token movement permission required', 'reject member 4');

set local role authenticated;

select set_config('request.jwt.claim.sub', '60000000-0000-0000-0000-000000000005', true);

select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000005","is_anonymous":false}', true);

select throws_ok($$select public.broadcast_token_movement('60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000030', 10, 20)$$, '42501', 'token movement permission required', 'reject member 5');

set local role authenticated;

select set_config('request.jwt.claim.sub', '60000000-0000-0000-0000-000000000006', true);

select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000006","is_anonymous":false}', true);

select throws_ok($$select public.broadcast_token_movement('60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000030', 10, 20)$$, '42501', 'token movement permission required', 'reject member 6');

set local role authenticated;

select set_config('request.jwt.claim.sub', '60000000-0000-0000-0000-000000000002', true);

select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000002","is_anonymous":true}', true);

select throws_ok($$select public.broadcast_token_movement('60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000030', 10, 20)$$, '42501', 'token movement permission required', 'anonymous claims are rejected even for an assigned member');

set local role authenticated;

select set_config('request.jwt.claim.sub', '60000000-0000-0000-0000-000000000001', true);

select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000001","is_anonymous":false}', true);

select public.set_room_feature_permission('60000000-0000-0000-0000-000000000010', 'token_move', false, null, '60000000-0000-0000-0000-000000000002');

set local role authenticated;

select set_config('request.jwt.claim.sub', '60000000-0000-0000-0000-000000000002', true);

select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000002","is_anonymous":false}', true);

select throws_ok($$select public.broadcast_token_movement('60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000030', 10, 20)$$, '42501', 'token movement permission required', 'current permission is checked on each call');

set local role authenticated;

select set_config('request.jwt.claim.sub', '60000000-0000-0000-0000-000000000001', true);

select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000001","is_anonymous":false}', true);

select public.set_room_feature_permission('60000000-0000-0000-0000-000000000010', 'token_move', true, null, '60000000-0000-0000-0000-000000000002');

update public.room_tokens set owner_id='60000000-0000-0000-0000-000000000003' where id='60000000-0000-0000-0000-000000000030';

set local role authenticated;

select set_config('request.jwt.claim.sub', '60000000-0000-0000-0000-000000000002', true);

select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000002","is_anonymous":false}', true);

select throws_ok($$select public.broadcast_token_movement('60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000030', 10, 20)$$, '42501', 'token movement permission required', 'reassignment immediately removes send permission');

set local role authenticated;

select set_config('request.jwt.claim.sub', '60000000-0000-0000-0000-000000000003', true);

select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000003","is_anonymous":false}', true);

select lives_ok($$select public.broadcast_token_movement('60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000030', 10, 20)$$, 'new assignee can send');

set local role authenticated;

select set_config('request.jwt.claim.sub', '60000000-0000-0000-0000-000000000001', true);

select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000001","is_anonymous":false}', true);

update public.room_tokens set owner_id='60000000-0000-0000-0000-000000000002' where id='60000000-0000-0000-0000-000000000030';

select public.set_room_member_role('60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000002', 'spectator');

set local role authenticated;

select set_config('request.jwt.claim.sub', '60000000-0000-0000-0000-000000000002', true);

select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000002","is_anonymous":false}', true);

select throws_ok($$select public.broadcast_token_movement('60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000030', 10, 20)$$, '42501', 'token movement permission required', 'role change blocks next send despite personal permission override');

set local role authenticated;

select set_config('request.jwt.claim.sub', '60000000-0000-0000-0000-000000000001', true);

select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000001","is_anonymous":false}', true);

select public.set_room_member_role('60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000002', 'player');

update public.room_tokens set owner_id='60000000-0000-0000-0000-000000000002' where id='60000000-0000-0000-0000-000000000030';

select public.force_remove_room_member('60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000002');

set local role authenticated;

select set_config('request.jwt.claim.sub', '60000000-0000-0000-0000-000000000002', true);

select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000002","is_anonymous":false}', true);

select throws_ok($$select public.broadcast_token_movement('60000000-0000-0000-0000-000000000010', '60000000-0000-0000-0000-000000000030', 10, 20)$$, '42501', 'token movement permission required', 'force removal blocks next send');

set local role authenticated;

select set_config('request.jwt.claim.sub', '60000000-0000-0000-0000-000000000001', true);

select set_config('request.jwt.claims', '{"sub":"60000000-0000-0000-0000-000000000001","is_anonymous":false}', true);

select set_config('realtime.topic', 'room:60000000-0000-0000-0000-000000000010:token-movements', true);

select throws_ok($$insert into realtime.messages(topic,extension,event,payload,private) values ('room:60000000-0000-0000-0000-000000000010:token-movements','broadcast','token-move','{}',true)$$,'42501',null,'even masters cannot insert a movement directly');

select set_config('realtime.topic', 'room:60000000-0000-0000-0000-000000000010:tokens', true);

select throws_ok($$insert into realtime.messages(topic,extension,event,payload,private) values ('room:60000000-0000-0000-0000-000000000010:tokens','broadcast','token-move','{}',true)$$,'42501',null,'legacy direct inserts are blocked');

set local role postgres;

select results_eq($$select count(*) from public.room_tokens where id in ('60000000-0000-0000-0000-000000000030','60000000-0000-0000-0000-000000000031','60000000-0000-0000-0000-000000000032','60000000-0000-0000-0000-000000000033') and x=1 and y=2$$,$$values (4::bigint)$$,'temporary broadcasts never mutate persisted positions');

select ok(not exists(select 1 from realtime.messages where topic='room:60000000-0000-0000-0000-000000000010:token-movements' and (payload->>'token_id') not in ('60000000-0000-0000-0000-000000000030','60000000-0000-0000-0000-000000000031','60000000-0000-0000-0000-000000000032')), 'denied tokens produce no stored broadcast');

select * from finish();

rollback;
