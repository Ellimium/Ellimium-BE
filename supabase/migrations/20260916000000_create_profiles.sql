create table public.profiles (
  user_id uuid primary key references auth.users (id) on delete cascade,
  nickname text not null,
  avatar_path text,
  constraint profiles_nickname_length check (char_length(nickname) between 3 and 20)
);

alter table public.profiles enable row level security;

create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (user_id, nickname)
  values (new.id, new.raw_user_meta_data ->> 'nickname');

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
