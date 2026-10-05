-- BE #46: the client can read state, but only this master RPC can write it.
alter table public.room_jukebox_states
  add column position_ms bigint not null default 0 check (position_ms >= 0),
  add column state_changed_at timestamptz not null default clock_timestamp(),
  add column loop_enabled boolean not null default false;

-- Both explicit deletion preparation and FK SET NULL produce an UPDATE,
-- preserving the row and clearing every playback field for subscribers.
create or replace function private.guard_room_jukebox_music_reference()
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
    new.position_ms := 0;
    new.loop_enabled := false;
    new.state_changed_at := clock_timestamp();
  else
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

drop trigger guard_room_jukebox_music_reference on public.room_jukebox_states;
create trigger guard_room_jukebox_music_reference
before insert or update on public.room_jukebox_states
for each row execute function private.guard_room_jukebox_music_reference();

create function public.control_room_jukebox(
  target_room_id uuid,
  action text,
  target_music_asset_id uuid default null,
  target_position_ms bigint default null,
  target_loop_enabled boolean default null
)
returns public.room_jukebox_states
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_id uuid := (select auth.uid());
  caller_role text;
  music_id uuid;
  music public.music_assets;
  current_state public.room_jukebox_states;
  changed_at timestamptz;
begin
  if caller_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  -- Serialize controls even before the first state row exists. Do not take a
  -- jukebox row lock before the music lock: deletion locks music first too.
  perform 1 from public.rooms where id = target_room_id for no key update;
  select member.role into caller_role
  from public.room_members as member
  where member.room_id = target_room_id and member.user_id = caller_id
    and member.status = 'active'
  for share;
  if caller_role is distinct from 'master' then
    raise exception 'active room master required' using errcode = '42501';
  end if;

  if action is null or action not in ('play', 'pause', 'resume', 'stop', 'seek', 'set_loop') then
    raise exception 'invalid jukebox action' using errcode = '22023';
  end if;
  if target_position_ms < 0
    or (action = 'seek' and target_position_ms is null)
    or (action = 'set_loop' and target_loop_enabled is null)
    or (action = 'play' and target_music_asset_id is null)
    or (action <> 'play' and target_music_asset_id is not null)
    or (action not in ('play', 'seek') and target_position_ms is not null)
    or (action not in ('play', 'set_loop') and target_loop_enabled is not null) then
    raise exception 'invalid jukebox arguments' using errcode = '22023';
  end if;

  if action <> 'stop' then
    if action = 'play' then
      music_id := target_music_asset_id;
    else
      select state.music_asset_id into music_id
      from public.room_jukebox_states as state where state.room_id = target_room_id;
    end if;
    select * into music from public.music_assets where id = music_id for key share;
    if not found then
      raise exception 'playable music required' using errcode = '22023';
    end if;
    if action = 'play' and music.owner_id <> caller_id then
      raise exception 'music owner required' using errcode = '42501';
    end if;
    if music.deletion_pending then
      raise exception 'music deletion is pending' using errcode = '23514';
    end if;
  end if;

  select * into current_state from public.room_jukebox_states
  where room_id = target_room_id for update;
  if action not in ('play', 'stop')
    and (current_state.music_asset_id is null or current_state.music_asset_id is distinct from music_id) then
    raise exception 'playable music required' using errcode = '22023';
  end if;
  changed_at := clock_timestamp();

  if action = 'play' then
    current_state.music_asset_id := music_id;
    current_state.status := 'playing';
    current_state.position_ms := coalesce(target_position_ms, 0);
    current_state.loop_enabled := coalesce(target_loop_enabled, false);
  elsif action = 'stop' then
    current_state.music_asset_id := null;
    current_state.status := 'stopped';
    current_state.position_ms := 0;
    current_state.loop_enabled := false;
  else
    -- Repeated pause/resume must not advance a paused track or reset its clock.
    if (action = 'pause' and current_state.status = 'paused')
      or (action = 'resume' and current_state.status = 'playing') then
      return current_state;
    end if;
    if current_state.status not in ('playing', 'paused') then
      raise exception 'playing or paused music required' using errcode = '22023';
    end if;
    if current_state.status = 'playing' then
      current_state.position_ms := current_state.position_ms + greatest(0,
        floor(extract(epoch from (changed_at - current_state.state_changed_at)) * 1000)::bigint);
    end if;
    if action = 'pause' then
      current_state.status := 'paused';
    elsif action = 'resume' then
      current_state.status := 'playing';
    elsif action = 'seek' then
      current_state.position_ms := target_position_ms;
    elsif action = 'set_loop' then
      current_state.loop_enabled := target_loop_enabled;
    end if;
  end if;

  insert into public.room_jukebox_states
    (room_id, music_asset_id, status, position_ms, state_changed_at, loop_enabled)
  values (target_room_id, current_state.music_asset_id, current_state.status,
    current_state.position_ms, changed_at, current_state.loop_enabled)
  on conflict (room_id) do update set
    music_asset_id = excluded.music_asset_id,
    status = excluded.status,
    position_ms = excluded.position_ms,
    state_changed_at = excluded.state_changed_at,
    loop_enabled = excluded.loop_enabled
  returning * into current_state;
  return current_state;
end;
$$;

revoke all on function public.control_room_jukebox(uuid, text, uuid, bigint, boolean)
from public, anon, authenticated;
grant execute on function public.control_room_jukebox(uuid, text, uuid, bigint, boolean)
to authenticated;

alter publication supabase_realtime add table public.room_jukebox_states;
