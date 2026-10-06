-- Library sharing grants authenticated downloads only. A signed URL would
-- survive revocation until expiry, so this policy must not authorize signing.
-- Existing owner and map/token policies remain independent authorities.
create policy assets_download_shared_rooms
on storage.objects for select to authenticated
using (
  bucket_id = 'assets'
  and storage.allow_only_operation('object.get_authenticated')
  and exists (
    select 1 from public.assets
    where storage.objects.name in (assets.storage_path, assets.thumbnail_storage_path)
      and (select private.can_read_shared_asset(assets.id))
  )
);
