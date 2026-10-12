-- Run AFTER the original supabase/schema.sql
-- ZackStore: Storage bucket + policies + default bot packages

insert into storage.buckets (id, name, public)
values ('zackstore-files', 'zackstore-files', false)
on conflict (id) do nothing;

-- Storage policies
 drop policy if exists "zackstore_storage_select" on storage.objects;
create policy "zackstore_storage_select"
on storage.objects for select
to anon, authenticated
using (
  bucket_id = 'zackstore-files'
  and (
    public.is_admin()
    or exists (
      select 1 from public.files f
      where f.storage_path = name
        and (f.public_access = true or f.owner_id = auth.uid())
    )
  )
);

drop policy if exists "zackstore_storage_insert_admin" on storage.objects;
create policy "zackstore_storage_insert_admin"
on storage.objects for insert
to authenticated
with check (
  bucket_id = 'zackstore-files'
  and public.is_admin()
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists "zackstore_storage_delete_admin" on storage.objects;
create policy "zackstore_storage_delete_admin"
on storage.objects for delete
to authenticated
using (bucket_id = 'zackstore-files' and public.is_admin());

-- Default ZackStore bot packages
insert into public.bot_packages (name, price, duration, features, available)
select v.name, v.price, v.duration, v.features::jsonb, true
from (values
  ('Bot 7 Hari', 15000, '7 Hari', '["Support dasar","Panel bot","Update ringan"]'),
  ('Bot 30 Hari', 35000, '30 Hari', '["Support prioritas","Panel bot","Update"]'),
  ('Bot 90 Hari', 85000, '90 Hari', '["Support prioritas","Panel bot","Update rutin"]'),
  ('Bot Permanen', 150000, 'Permanen', '["Akses permanen","Support","Update rutin","Bonus"]')
) as v(name,price,duration,features)
where not exists (
  select 1 from public.bot_packages b where lower(b.name)=lower(v.name)
);
