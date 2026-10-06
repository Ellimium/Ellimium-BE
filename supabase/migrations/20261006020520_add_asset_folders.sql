create table public.asset_folders (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name text not null check (length(btrim(name)) > 0),
  parent_id uuid,
  depth integer not null default 1 check (depth between 1 and 3),
  parent_depth integer generated always as (
    case when parent_id is not null then depth - 1 end
  ) stored,
  created_at timestamptz not null default now(),
  unique (id, owner_id),
  unique (id, owner_id, depth),
  constraint asset_folders_root_depth check (
    (parent_id is null and depth = 1)
    or (parent_id is not null and depth > 1)
  ),
  -- Each edge goes to the same owner's folder exactly one level above.
  -- This also prevents cycles and incorrect client-supplied depths.
  constraint asset_folders_parent foreign key (parent_id, owner_id, parent_depth)
    references public.asset_folders (id, owner_id, depth) on delete restrict
);

create index asset_folders_owner_parent_idx on public.asset_folders (owner_id, parent_id);
create index asset_folders_parent_idx on public.asset_folders (parent_id, owner_id, parent_depth);

alter table public.asset_folders enable row level security;

create policy asset_folders_manage_own
on public.asset_folders
for all
to authenticated
using (owner_id = (select auth.uid()))
with check (owner_id = (select auth.uid()));

revoke all on public.asset_folders from public, anon, authenticated;
grant select, insert, delete on public.asset_folders to authenticated;
-- Folder reparenting is outside this issue; clients can only rename folders.
grant update (name) on public.asset_folders to authenticated;
grant all on public.asset_folders to service_role;

-- NULL represents unclassified assets, including existing rows and new uploads.
alter table public.assets
  add column folder_id uuid,
  add constraint assets_folder_owner foreign key (folder_id, owner_id)
    references public.asset_folders (id, owner_id) on delete restrict;

create index assets_folder_owner_idx on public.assets (folder_id, owner_id);

create policy assets_move_own
on public.assets
for update
to authenticated
using (owner_id = (select auth.uid()))
with check (owner_id = (select auth.uid()));

-- Keep metadata and Storage writes restricted to the upload function.
revoke update on public.assets from public, anon, authenticated;
grant update (folder_id) on public.assets to authenticated;
