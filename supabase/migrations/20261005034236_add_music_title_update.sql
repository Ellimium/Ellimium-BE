create function public.rename_music_asset(target_music_asset_id uuid, new_title text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  music public.music_assets;
  caller_id uuid := (select auth.uid());
  normalized_title text := btrim(new_title);
begin
  if caller_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if normalized_title is null or length(normalized_title) = 0 then
    raise exception 'music title required' using errcode = '22023';
  end if;
  -- Match deletion's parent-row lock so rename cannot revive pending metadata.
  select * into music from public.music_assets
  where id = target_music_asset_id for update;
  if not found then
    raise exception 'music not found' using errcode = 'P0002';
  end if;
  if music.owner_id <> caller_id then
    raise exception 'music owner required' using errcode = '42501';
  end if;
  if music.deletion_pending then
    raise exception 'music deletion is pending' using errcode = '23514';
  end if;
  update public.music_assets set title = normalized_title
  where id = target_music_asset_id;
  return normalized_title;
end;
$$;
revoke all on function public.rename_music_asset(uuid, text) from public, anon, authenticated;
grant execute on function public.rename_music_asset(uuid, text) to authenticated;
