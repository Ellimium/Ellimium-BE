alter table public.music_assets
add column deletion_pending boolean not null default false;

alter table public.room_jukebox_states
add column status text not null default 'stopped'
check (status in ('playing', 'paused', 'stopped'));

-- Client writes stay disabled; BE #46 will provide the master-only state RPCs.
create function private.guard_room_jukebox_music_reference()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  pending boolean;
begin
  if new.music_asset_id is null then
    new.status := 'stopped';
  else
    -- Serialize selecting a track with its owner starting deletion.
    select music.deletion_pending into pending
    from public.music_assets as music
    where music.id = new.music_asset_id
    for key share;
    if pending then
      raise exception 'music deletion is pending' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;
revoke all on function private.guard_room_jukebox_music_reference()
from public, anon, authenticated;

create trigger guard_room_jukebox_music_reference
before insert or update of music_asset_id, status on public.room_jukebox_states
for each row execute function private.guard_room_jukebox_music_reference();

create or replace function private.can_access_music_object(object_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select (select auth.uid()) is not null and exists (
    select 1 from public.music_assets as music
    where music.storage_path = object_name
      and not music.deletion_pending
      and (
        music.owner_id = (select auth.uid())
        or exists (
          select 1 from public.room_jukebox_states as jukebox
          join public.room_members as member on member.room_id = jukebox.room_id
          where jukebox.music_asset_id = music.id
            and member.user_id = (select auth.uid())
            and member.status = 'active'
        )
      )
  );
$$;

-- Preserve the path for retry until both Storage and metadata cleanup succeed.
create function public.prepare_music_asset_deletion(target_music_asset_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  music public.music_assets;
  caller_id uuid := (select auth.uid());
begin
  if caller_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  select * into music from public.music_assets
  where id = target_music_asset_id for update;
  if not found then return null; end if;
  if music.owner_id <> caller_id then
    raise exception 'music owner required' using errcode = '42501';
  end if;
  update public.music_assets set deletion_pending = true
  where id = target_music_asset_id;
  update public.room_jukebox_states
  set music_asset_id = null, status = 'stopped'
  where music_asset_id = target_music_asset_id;
  return music.storage_path;
end;
$$;
revoke all on function public.prepare_music_asset_deletion(uuid) from public, anon, authenticated;
grant execute on function public.prepare_music_asset_deletion(uuid) to authenticated;

-- Only the server may finalize after Storage.remove; direct client calls fail.
create function public.finish_music_asset_deletion(target_music_asset_id uuid, target_owner_id uuid)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
begin
  delete from public.music_assets
  where id = target_music_asset_id and owner_id = target_owner_id and deletion_pending;
  if found then return true; end if;
  if exists (select 1 from public.music_assets where id = target_music_asset_id) then
    raise exception 'music deletion was not prepared for this owner' using errcode = '42501';
  end if;
  return false;
end;
$$;
revoke all on function public.finish_music_asset_deletion(uuid, uuid) from public, anon, authenticated;
grant execute on function public.finish_music_asset_deletion(uuid, uuid) to service_role;
