create function private.prevent_room_token_map_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.map_id is distinct from old.map_id then
    raise exception 'room token map cannot be changed' using errcode = '23514';
  end if;

  return new;
end;
$$;

revoke all on function private.prevent_room_token_map_change()
from public, anon, authenticated;

create trigger prevent_room_token_map_change
before update of map_id on public.room_tokens
for each row execute function private.prevent_room_token_map_change();
