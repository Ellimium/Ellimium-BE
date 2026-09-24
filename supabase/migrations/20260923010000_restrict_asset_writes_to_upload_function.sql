drop policy assets_manage_own on public.assets;

create policy assets_select_own
on public.assets
for select
to authenticated
using (owner_id = (select auth.uid()));

drop policy assets_manage_own on storage.objects;

create policy assets_select_own
on storage.objects
for select
to authenticated
using (
  bucket_id = 'assets'
  and (storage.foldername(name))[1] = (select auth.uid()::text)
);
