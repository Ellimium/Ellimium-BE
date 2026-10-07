begin;

select plan(23);

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, confirmation_token, email_change,
  recovery_token, email_change_token_new
) values
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000301', 'authenticated', 'authenticated', 'gm-settings-owner@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"설정소유자"}', '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000302', 'authenticated', 'authenticated', 'gm-settings-other@example.com', '', now(), '{"provider":"email","providers":["email"]}', '{"nickname":"다른사용자"}', '', '', '', '');

-- A player in the same room must not inherit the GM's personal settings.
insert into public.rooms (id, creator_id, name, game_system) values
  ('00000000-0000-0000-0000-000000000303', '00000000-0000-0000-0000-000000000301', 'GM settings test', 'D&D 5e');
insert into public.room_members (room_id, user_id, role) values
  ('00000000-0000-0000-0000-000000000303', '00000000-0000-0000-0000-000000000301', 'master'),
  ('00000000-0000-0000-0000-000000000303', '00000000-0000-0000-0000-000000000302', 'player');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000301', true);

select lives_ok($$insert into public.gm_screen_settings (panel_id) values ('chat')$$, 'owner can create a panel setting');
select results_eq($$select user_id, collapsed, visible, position from public.gm_screen_settings where panel_id = 'chat'$$,
  $$values ('00000000-0000-0000-0000-000000000301'::uuid, false, true, 0)$$, 'defaults use the current user and an expanded visible panel');
select lives_ok($$insert into public.gm_screen_settings (panel_id, collapsed, visible, position) values ('jukebox', true, false, 2)$$, 'owner can save another panel');
select lives_ok($$
  insert into public.gm_screen_settings (user_id, panel_id, collapsed, visible, position)
  values ('00000000-0000-0000-0000-000000000301', 'chat', true, false, 1)
  on conflict (user_id, panel_id) do update
  set collapsed = excluded.collapsed, visible = excluded.visible, position = excluded.position;
$$, 'upsert saves collapse, visibility and placement');

-- Clear and restore the request identity before reading saved settings.
select set_config('request.jwt.claim.sub', '', true);
select results_eq($$select count(*) from public.gm_screen_settings$$, $$values (0::bigint)$$, 'missing identity cannot read saved settings');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000301', true);
select results_eq($$select panel_id, collapsed, visible, position from public.gm_screen_settings order by position, panel_id$$,
  $$values ('chat'::text, true, false, 1), ('jukebox'::text, true, false, 2)$$, 'saved settings can be read again in placement order');
select throws_ok($$insert into public.gm_screen_settings (user_id, panel_id) values ('00000000-0000-0000-0000-000000000302', 'chat')$$, '42501', null, 'cannot create another user setting');
select throws_ok($$update public.gm_screen_settings set user_id = '00000000-0000-0000-0000-000000000302' where panel_id = 'chat'$$, '42501', null, 'cannot transfer ownership');
select throws_ok($$insert into public.gm_screen_settings (panel_id) values ('   ')$$, '23514', null, 'blank panel identifier is rejected');
select throws_ok($$insert into public.gm_screen_settings (panel_id) values (repeat('x', 65))$$, '23514', null, 'oversized panel identifier is rejected');
select throws_ok($$update public.gm_screen_settings set position = -1 where panel_id = 'chat'$$, '23514', null, 'negative placement is rejected');

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000302', true);
select results_eq($$select count(*) from public.gm_screen_settings$$, $$values (0::bigint)$$, 'same-room player cannot read GM settings');
select results_eq($$update public.gm_screen_settings set visible = true returning panel_id$$, $$select null::text where false$$, 'same-room player cannot update GM settings');
select results_eq($$delete from public.gm_screen_settings returning panel_id$$, $$select null::text where false$$, 'same-room player cannot delete GM settings');
select lives_ok($$insert into public.gm_screen_settings (panel_id) values ('chat')$$, 'another user can store independent preferences for the same panel');

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000301', true);
select throws_ok($$
  insert into public.gm_screen_settings (user_id, panel_id, visible)
  values ('00000000-0000-0000-0000-000000000302', 'chat', false)
  on conflict (user_id, panel_id) do update set visible = excluded.visible;
$$, '42501', null, 'cannot overwrite another user setting through upsert');
select results_eq($$select collapsed, visible, position from public.gm_screen_settings where panel_id = 'chat'$$, $$values (true, false, 1)$$, 'other user operations leave the GM setting unchanged');
select results_eq($$delete from public.gm_screen_settings where panel_id = 'jukebox' returning panel_id$$, $$values ('jukebox'::text)$$, 'owner can remove a saved preference to restore the UI default');

set local role anon;
select set_config('request.jwt.claim.sub', '', true);
select throws_ok($$select * from public.gm_screen_settings$$, '42501', null, 'anonymous reads are denied');
select throws_ok($$insert into public.gm_screen_settings (panel_id) values ('chat')$$, '42501', null, 'anonymous inserts are denied');
select throws_ok($$update public.gm_screen_settings set visible = true$$, '42501', null, 'anonymous updates are denied');
select throws_ok($$delete from public.gm_screen_settings$$, '42501', null, 'anonymous deletes are denied');

set local role postgres;
delete from auth.users where id = '00000000-0000-0000-0000-000000000302';
select results_eq($$select count(*) from public.gm_screen_settings where user_id = '00000000-0000-0000-0000-000000000302'$$, $$values (0::bigint)$$, 'account deletion removes personal settings');

select * from finish();
rollback;
