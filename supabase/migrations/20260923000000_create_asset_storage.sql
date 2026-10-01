create table public.assets (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users (id) on delete cascade,
  category text not null check (category in ('map', 'token', 'item', 'other')),
  storage_path text not null unique,
  thumbnail_storage_path text,
  created_at timestamptz not null default now(),
  constraint assets_storage_path_owner check (split_part(storage_path, '/', 1) = owner_id::text),
  constraint assets_thumbnail_storage_path_owner check (
    thumbnail_storage_path is null
    or split_part(thumbnail_storage_path, '/', 1) = owner_id::text
  )
);

alter table public.assets enable row level security;

create policy assets_manage_own
on public.assets
for all
to authenticated
using (owner_id = (select auth.uid()))
with check (owner_id = (select auth.uid()));

insert into storage.buckets (id, name, public)
values ('assets', 'assets', false);

create policy assets_manage_own
on storage.objects
for all
to authenticated
using (
  bucket_id = 'assets'
  and (storage.foldername(name))[1] = (select auth.uid()::text)
)
with check (
  bucket_id = 'assets'
  and (storage.foldername(name))[1] = (select auth.uid()::text)
);
