#!/bin/sh
set -eu

cd "$(dirname "$0")/../.."
task_tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/ellimium-asset-folder-upgrade.XXXXXX")
trap 'rm -rf "$task_tmp_dir"' EXIT HUP INT TERM
upgrade_sql="$task_tmp_dir/asset_folders_upgrade.sql"

# The CLI mounts test files without migrations; embed the actual migration
# in a temporary test file instead of duplicating the schema here.
cat > "$upgrade_sql" <<'SQL'
begin;

select plan(5);

-- Recreate the pre-folder schema inside this transaction only.
-- ROLLBACK restores the current schema, grants, and all local data.
drop policy assets_move_own on public.assets;
alter table public.assets drop column folder_id;
drop table public.asset_folders;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, confirmation_token, email_change,
  recovery_token, email_change_token_new
) values (
  '00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000241',
  'authenticated', 'authenticated', 'folder-upgrade@example.com', '', now(),
  '{"provider":"email","providers":["email"]}', '{"nickname":"기존자산소유자"}', '', '', '', ''
);

insert into public.assets (id, owner_id, category, storage_path, thumbnail_storage_path) values (
  '00000000-0000-0000-0000-000000000242', '00000000-0000-0000-0000-000000000241',
  'map', '00000000-0000-0000-0000-000000000241/old-map.png',
  '00000000-0000-0000-0000-000000000241/old-thumbnail.png'
);
create temporary table asset_before_upgrade as
select id, owner_id, category, storage_path, thumbnail_storage_path, created_at
from public.assets where id = '00000000-0000-0000-0000-000000000242';

SQL
cat supabase/migrations/20261006020520_add_asset_folders.sql >> "$upgrade_sql"
cat >> "$upgrade_sql" <<'SQL'


select results_eq(
  $$select id, owner_id, category, storage_path, thumbnail_storage_path, created_at from public.assets where id = '00000000-0000-0000-0000-000000000242'$$,
  $$select * from asset_before_upgrade$$,
  'migration preserves all existing asset metadata'
);
select results_eq(
  $$select folder_id from public.assets where id = '00000000-0000-0000-0000-000000000242'$$,
  $$values (null::uuid)$$,
  'existing asset becomes unclassified'
);

-- The upload function inserts metadata without specifying a folder.
set local role service_role;
select lives_ok($$
  insert into public.assets (id, owner_id, category, storage_path) values (
    '00000000-0000-0000-0000-000000000243', '00000000-0000-0000-0000-000000000241',
    'token', '00000000-0000-0000-0000-000000000241/new-token.png'
  )
$$, 'existing upload metadata insert still works');
select results_eq(
  $$select folder_id from public.assets where id = '00000000-0000-0000-0000-000000000243'$$,
  $$values (null::uuid)$$,
  'new upload defaults to unclassified'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000241', true);
select results_eq(
  $$select count(*) from public.assets where owner_id = '00000000-0000-0000-0000-000000000241' and folder_id is null$$,
  $$values (2::bigint)$$,
  'owner can read both old and new unclassified assets'
);

select * from finish();

rollback;
SQL

npx supabase test db --local "$upgrade_sql"
