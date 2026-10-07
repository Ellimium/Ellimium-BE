create table public.gm_screen_settings (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  panel_id text not null,
  collapsed boolean not null default false,
  visible boolean not null default true,
  position integer not null default 0,
  primary key (user_id, panel_id),
  constraint gm_screen_settings_panel_id_check
    check (panel_id = btrim(panel_id) and char_length(panel_id) between 1 and 64),
  constraint gm_screen_settings_position_check check (position >= 0)
);

alter table public.gm_screen_settings enable row level security;

revoke all on table public.gm_screen_settings from public, anon, authenticated;
grant select, insert, update, delete on table public.gm_screen_settings to authenticated;

create policy gm_screen_settings_select_own
on public.gm_screen_settings for select to authenticated
using ((select auth.uid()) = user_id);

create policy gm_screen_settings_insert_own
on public.gm_screen_settings for insert to authenticated
with check ((select auth.uid()) = user_id);

create policy gm_screen_settings_update_own
on public.gm_screen_settings for update to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

create policy gm_screen_settings_delete_own
on public.gm_screen_settings for delete to authenticated
using ((select auth.uid()) = user_id);
