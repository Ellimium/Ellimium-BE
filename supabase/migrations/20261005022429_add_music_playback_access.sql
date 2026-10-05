-- BE #45 supplies the current music reference; BE #46 adds playback state/RPCs.
create table public.room_jukebox_states (
  room_id uuid primary key references public.rooms (id) on delete cascade,
  music_asset_id uuid references public.music_assets (id) on delete set null
);

create index room_jukebox_states_music_asset_idx
on public.room_jukebox_states (music_asset_id)
where music_asset_id is not null;

alter table public.room_jukebox_states enable row level security;
revoke all on table public.room_jukebox_states from anon, authenticated;
grant select on table public.room_jukebox_states to authenticated;

create policy room_jukebox_states_select_active_members
on public.room_jukebox_states
for select
to authenticated
using ((select public.is_active_room_member(room_id)));

-- Cross-owner access only applies to the referenced object, never the library.
-- Keep this lookup outside the Data API and bypass owner-only metadata RLS.
create function private.can_access_music_object(object_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select (select auth.uid()) is not null and exists (
    select 1
    from public.music_assets as music
    where music.storage_path = object_name
      and (
        music.owner_id = (select auth.uid())
        or exists (
          select 1
          from public.room_jukebox_states as jukebox
          join public.room_members as member on member.room_id = jukebox.room_id
          where jukebox.music_asset_id = music.id
            and member.user_id = (select auth.uid())
            and member.status = 'active'
        )
      )
  );
$$;

revoke all on function private.can_access_music_object(text) from public, anon, authenticated;
grant execute on function private.can_access_music_object(text) to authenticated;

drop policy music_assets_select_own on storage.objects;
create policy music_assets_select_playable
on storage.objects
for select
to authenticated
using (
  bucket_id = 'music-assets'
  and private.can_access_music_object(name)
);
