create table public.music_assets (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users (id) on delete cascade,
  title text not null check (length(btrim(title)) > 0),
  storage_path text not null unique,
  mime_type text not null check (mime_type in ('audio/mpeg', 'audio/ogg', 'audio/wav', 'audio/x-wav')),
  file_size_bytes bigint not null check (file_size_bytes > 0),
  duration_ms bigint not null check (duration_ms > 0),
  created_at timestamptz not null default now(),
  constraint music_assets_storage_path_owner check (
    split_part(storage_path, '/', 1) = owner_id::text
  )
);

alter table public.music_assets enable row level security;

create policy music_assets_select_own
on public.music_assets
for select
to authenticated
using (owner_id = (select auth.uid()));

insert into storage.buckets (id, name, public)
values ('music-assets', 'music-assets', false);

create policy music_assets_select_own
on storage.objects
for select
to authenticated
using (
  bucket_id = 'music-assets'
  and (storage.foldername(name))[1] = (select auth.uid()::text)
);
