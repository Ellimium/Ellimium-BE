begin;
select plan(43);

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000301', 'share-owner@example.com', '{"nickname":"Owner"}'),
  ('00000000-0000-0000-0000-000000000302', 'share-player@example.com', '{"nickname":"Player"}'),
  ('00000000-0000-0000-0000-000000000303', 'share-spectator@example.com', '{"nickname":"Spectator"}'),
  ('00000000-0000-0000-0000-000000000304', 'share-outsider@example.com', '{"nickname":"Outsider"}'),
  ('00000000-0000-0000-0000-000000000305', 'share-left@example.com', '{"nickname":"Left"}'),
  ('00000000-0000-0000-0000-000000000306', 'share-removed@example.com', '{"nickname":"Removed"}');
insert into public.rooms (id, creator_id, name, game_system) values
  ('00000000-0000-0000-0000-000000000311', '00000000-0000-0000-0000-000000000301', 'Share A', 'Test'),
  ('00000000-0000-0000-0000-000000000312', '00000000-0000-0000-0000-000000000301', 'Share B', 'Test'),
  ('00000000-0000-0000-0000-000000000313', '00000000-0000-0000-0000-000000000304', 'Foreign room', 'Test');
insert into public.room_members (room_id, user_id, role, status) values
  ('00000000-0000-0000-0000-000000000311', '00000000-0000-0000-0000-000000000301', 'player', 'active'),
  ('00000000-0000-0000-0000-000000000312', '00000000-0000-0000-0000-000000000301', 'master', 'active'),
  ('00000000-0000-0000-0000-000000000311', '00000000-0000-0000-0000-000000000302', 'master', 'active'),
  ('00000000-0000-0000-0000-000000000311', '00000000-0000-0000-0000-000000000303', 'spectator', 'active'),
  ('00000000-0000-0000-0000-000000000312', '00000000-0000-0000-0000-000000000304', 'player', 'active'),
  ('00000000-0000-0000-0000-000000000311', '00000000-0000-0000-0000-000000000305', 'player', 'left'),
  ('00000000-0000-0000-0000-000000000311', '00000000-0000-0000-0000-000000000306', 'player', 'removed');
insert into public.assets (id, owner_id, category, storage_path) values
  ('00000000-0000-0000-0000-000000000321', '00000000-0000-0000-0000-000000000301', 'item', '00000000-0000-0000-0000-000000000301/shared.png'),
  ('00000000-0000-0000-0000-000000000322', '00000000-0000-0000-0000-000000000301', 'other', '00000000-0000-0000-0000-000000000301/private.png'),
  ('00000000-0000-0000-0000-000000000323', '00000000-0000-0000-0000-000000000304', 'token', '00000000-0000-0000-0000-000000000304/foreign.png');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000302', true);
select is((select count(*) from public.room_asset_shares), 0::bigint, 'existing assets have no library shares');
select is((select count(*) from public.assets where id in ('00000000-0000-0000-0000-000000000321', '00000000-0000-0000-0000-000000000322')), 0::bigint, 'unshared metadata is private');

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000301', true);
select lives_ok($$insert into public.room_asset_shares (asset_id, room_id) values ('00000000-0000-0000-0000-000000000321', '00000000-0000-0000-0000-000000000311')$$, 'owner player can share to their active room');
select throws_ok($$insert into public.room_asset_shares (asset_id, room_id) values ('00000000-0000-0000-0000-000000000321', '00000000-0000-0000-0000-000000000311')$$, '23505', null, 'duplicate share is rejected');
select throws_ok($$insert into public.room_asset_shares (asset_id, room_id) values ('00000000-0000-0000-0000-000000000321', '00000000-0000-0000-0000-000000000313')$$, '42501', null, 'owner cannot share to a foreign room');
select throws_ok($$insert into public.room_asset_shares (asset_id, room_id) values ('00000000-0000-0000-0000-000000000321', '00000000-0000-0000-0000-000000000399')$$, '42501', null, 'missing room is denied');
select throws_ok($$insert into public.room_asset_shares (asset_id, room_id) values ('00000000-0000-0000-0000-000000000399', '00000000-0000-0000-0000-000000000311')$$, '42501', null, 'missing asset is denied');
select throws_ok($$insert into public.room_asset_shares (asset_id, room_id) values ('00000000-0000-0000-0000-000000000323', '00000000-0000-0000-0000-000000000311')$$, '42501', null, 'foreign asset is denied');
select lives_ok($$insert into public.room_asset_shares (asset_id, room_id) values ('00000000-0000-0000-0000-000000000321', '00000000-0000-0000-0000-000000000312')$$, 'same asset can be shared to another room');
select is((select count(*) from public.room_asset_shares), 2::bigint, 'owner sees all share destinations');
select throws_ok($$update public.room_asset_shares set room_id = '00000000-0000-0000-0000-000000000313'$$, '42501', null, 'shares are immutable; delete and insert to change destination');

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000302', true);
select is((select count(*) from public.room_asset_shares), 1::bigint, 'member sees only their room share');
select is((select count(*) from public.assets where id = '00000000-0000-0000-0000-000000000321'), 1::bigint, 'member sees shared metadata without policy recursion');
select is((select count(*) from public.assets where id = '00000000-0000-0000-0000-000000000322'), 0::bigint, 'other owner assets remain private');
select throws_ok($$insert into public.room_asset_shares (asset_id, room_id) values ('00000000-0000-0000-0000-000000000321', '00000000-0000-0000-0000-000000000313')$$, '42501', null, 'nonowner cannot reshare visible asset');
select throws_ok($$insert into public.room_asset_shares (asset_id, room_id) values ('00000000-0000-0000-0000-000000000321', '00000000-0000-0000-0000-000000000311')$$, '42501', null, 'active room master still cannot insert another owner share');
select results_eq($$with removed as (delete from public.room_asset_shares returning *) select count(*) from removed$$, $$values (0::bigint)$$, 'room master cannot revoke another owner share');
select results_eq($$with moved as (update public.assets set folder_id = null where id = '00000000-0000-0000-0000-000000000321' returning *) select count(*) from moved$$, $$values (0::bigint)$$, 'read access does not allow folder movement');

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000303', true);
select is((select count(*) from public.assets where id = '00000000-0000-0000-0000-000000000321'), 1::bigint, 'active spectator sees shared metadata');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000304', true);
select is((select count(*) from public.room_asset_shares), 1::bigint, 'second room member sees only second room share');
select is((select count(*) from public.assets where id = '00000000-0000-0000-0000-000000000321'), 1::bigint, 'second room independently grants metadata access');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000305', true);
select is((select count(*) from public.room_asset_shares), 0::bigint, 'departed member cannot read shares');
select is((select count(*) from public.assets where id = '00000000-0000-0000-0000-000000000321'), 0::bigint, 'departed member cannot read metadata');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000306', true);
select is((select count(*) from public.room_asset_shares), 0::bigint, 'removed member cannot read shares');
select is((select count(*) from public.assets where id = '00000000-0000-0000-0000-000000000321'), 0::bigint, 'removed member cannot read metadata');

set local role postgres;
update public.room_members set status = 'left' where room_id = '00000000-0000-0000-0000-000000000311' and user_id = '00000000-0000-0000-0000-000000000301';
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000301', true);
select throws_ok($$insert into public.room_asset_shares (asset_id, room_id) values ('00000000-0000-0000-0000-000000000322', '00000000-0000-0000-0000-000000000311')$$, '42501', null, 'departed owner cannot create new shares');
select is((select count(*) from public.room_asset_shares), 2::bigint, 'departed owner still sees their share destinations');
select results_eq($$with removed as (delete from public.room_asset_shares where room_id = '00000000-0000-0000-0000-000000000311' returning *) select count(*) from removed$$, $$values (1::bigint)$$, 'departed owner can revoke the first room share');
select is((select count(*) from public.room_asset_shares), 1::bigint, 'other room share survives revocation');
select is((select count(*) from public.assets where id = '00000000-0000-0000-0000-000000000321'), 1::bigint, 'owner retains metadata access');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000302', true);
select is((select count(*) from public.assets where id = '00000000-0000-0000-0000-000000000321'), 0::bigint, 'revoked room member loses metadata access');
select is((select count(*) from public.room_asset_shares), 0::bigint, 'revoked room member cannot see other destinations');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000304', true);
select is((select count(*) from public.assets where id = '00000000-0000-0000-0000-000000000321'), 1::bigint, 'other room member retains access');

set local role postgres;
update public.room_members set status = 'removed' where room_id = '00000000-0000-0000-0000-000000000312' and user_id = '00000000-0000-0000-0000-000000000304';
set local role authenticated;
select is((select count(*) from public.assets where id = '00000000-0000-0000-0000-000000000321'), 0::bigint, 'membership removal immediately removes metadata access with same JWT');
select is((select count(*) from public.room_asset_shares), 0::bigint, 'nonmember cannot see remaining share');

set local role anon;
select set_config('request.jwt.claim.sub', '', true);
select throws_ok($$select * from public.room_asset_shares$$, '42501', null, 'anon cannot read share table');
select throws_ok($$insert into public.room_asset_shares (asset_id, room_id) values ('00000000-0000-0000-0000-000000000321', '00000000-0000-0000-0000-000000000311')$$, '42501', null, 'anon cannot share');
select throws_ok($$delete from public.room_asset_shares$$, '42501', null, 'anon cannot unshare');
select is((select count(*) from public.assets where id = '00000000-0000-0000-0000-000000000321'), 0::bigint, 'anon cannot read shared metadata');

set local role postgres;
delete from public.rooms where id = '00000000-0000-0000-0000-000000000312';
select is((select count(*) from public.room_asset_shares), 0::bigint, 'room deletion cleans share relations');
insert into public.room_asset_shares (asset_id, room_id) values ('00000000-0000-0000-0000-000000000321', '00000000-0000-0000-0000-000000000311');
delete from public.assets where id = '00000000-0000-0000-0000-000000000321';
select is((select count(*) from public.room_asset_shares), 0::bigint, 'asset deletion cleans share relations');
select ok(not has_function_privilege('anon', 'private.can_read_shared_asset(uuid)', 'EXECUTE'), 'anon cannot execute privileged helper');
select ok(not has_table_privilege('authenticated', 'public.room_asset_shares', 'UPDATE'), 'clients cannot alter share identity');

select * from finish();
rollback;
