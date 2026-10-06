begin;

select plan(18);

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, confirmation_token, email_change,
  recovery_token, email_change_token_new
) values
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000201', 'authenticated', 'authenticated', 'folder-owner@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"폴더소유자"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000202', 'authenticated', 'authenticated', 'folder-other@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"다른소유자"}', '', '', '', '');

insert into public.asset_folders (id, owner_id, name) values
  ('00000000-0000-0000-0000-000000000214', '00000000-0000-0000-0000-000000000202', 'Other root');
insert into public.assets (id, owner_id, category, storage_path) values
  ('00000000-0000-0000-0000-000000000221', '00000000-0000-0000-0000-000000000201', 'item', '00000000-0000-0000-0000-000000000201/folder-test.png'),
  ('00000000-0000-0000-0000-000000000222', '00000000-0000-0000-0000-000000000202', 'item', '00000000-0000-0000-0000-000000000202/folder-test.png');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000201', true);

select lives_ok($$
  insert into public.asset_folders (id, name) values ('00000000-0000-0000-0000-000000000211', 'Root');
  insert into public.asset_folders (id, name, parent_id, depth) values ('00000000-0000-0000-0000-000000000212', 'Child', '00000000-0000-0000-0000-000000000211', 2);
  insert into public.asset_folders (id, name, parent_id, depth) values ('00000000-0000-0000-0000-000000000213', 'Grandchild', '00000000-0000-0000-0000-000000000212', 3);
$$, 'owner can create a three-level hierarchy');
select results_eq($$select count(*) from public.asset_folders$$, $$values (3::bigint)$$, 'other owner folders are hidden');
select throws_ok($$insert into public.asset_folders (name) values ('   ')$$, '23514', null, 'blank folder names are rejected');
select throws_ok($$insert into public.asset_folders (name, parent_id, depth) values ('Fourth', '00000000-0000-0000-0000-000000000213', 4)$$, '23514', null, 'fourth level is rejected');
select throws_ok($$insert into public.asset_folders (name, parent_id, depth) values ('Forged depth', '00000000-0000-0000-0000-000000000213', 2)$$, '23503', null, 'depth must match the parent');
select throws_ok($$insert into public.asset_folders (name, parent_id, depth) values ('Foreign parent', '00000000-0000-0000-0000-000000000214', 2)$$, '23503', null, 'parent must have the same owner');
select throws_ok($$insert into public.asset_folders (owner_id, name) values ('00000000-0000-0000-0000-000000000202', 'Foreign owner')$$, '42501', null, 'RLS rejects creating folders for another owner');
select lives_ok($$update public.asset_folders set name = 'Renamed' where id = '00000000-0000-0000-0000-000000000213'$$, 'owner can rename a folder');
select throws_ok($$update public.asset_folders set parent_id = null where id = '00000000-0000-0000-0000-000000000213'$$, '42501', null, 'clients cannot alter the hierarchy');
select results_eq($$with changed as (update public.asset_folders set name = 'Forbidden' where id = '00000000-0000-0000-0000-000000000214' returning id) select count(*) from changed$$, $$values (0::bigint)$$, 'RLS prevents renaming other owner folders');
select throws_ok($$delete from public.asset_folders where id = '00000000-0000-0000-0000-000000000211'$$, '23503', null, 'folder with a child cannot be deleted');
select results_eq($$select folder_id from public.assets where id = '00000000-0000-0000-0000-000000000221'$$, $$values (null::uuid)$$, 'uploads default to unclassified');
select lives_ok($$update public.assets set folder_id = '00000000-0000-0000-0000-000000000213' where id = '00000000-0000-0000-0000-000000000221'$$, 'owner can move an asset into a folder');
select throws_ok($$delete from public.asset_folders where id = '00000000-0000-0000-0000-000000000213'$$, '23503', null, 'folder with an asset cannot be deleted');
select throws_ok($$update public.assets set folder_id = '00000000-0000-0000-0000-000000000214' where id = '00000000-0000-0000-0000-000000000221'$$, '23503', null, 'asset cannot move into another owner folder');
select throws_ok($$update public.assets set category = 'map' where id = '00000000-0000-0000-0000-000000000221'$$, '42501', null, 'asset movement does not allow metadata edits');
select results_eq($$with changed as (update public.assets set folder_id = '00000000-0000-0000-0000-000000000213' where id = '00000000-0000-0000-0000-000000000222' returning id) select count(*) from changed$$, $$values (0::bigint)$$, 'RLS prevents moving other owner assets');
select lives_ok($$
  update public.assets set folder_id = null where id = '00000000-0000-0000-0000-000000000221';
  delete from public.asset_folders where id = '00000000-0000-0000-0000-000000000213';
$$, 'asset can return to unclassified and the empty folder can be deleted');

select * from finish();

rollback;
