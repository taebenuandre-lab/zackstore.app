-- ZackStore FINAL migration
-- Jalankan SEKALI setelah seluruh migration sebelumnya (base + V2 + V4 + V6).
-- Frontend menggunakan orders.bot_id sebagai canonical field. Jangan kembalikan package_id ke frontend.

create extension if not exists pgcrypto;

-- ============================================================
-- 1. LOGIN HISTORY / PROFILE HARDENING
-- ============================================================
alter table public.profiles add column if not exists whatsapp text;
alter table public.profiles add column if not exists avatar_url text;
alter table public.profiles add column if not exists suspended boolean not null default false;
alter table public.profiles add column if not exists balance numeric not null default 0;
alter table public.profiles add column if not exists last_login_at timestamptz;

create table if not exists public.login_history (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  device text,
  ip_address text,
  created_at timestamptz not null default now()
);
create index if not exists login_history_user_created_idx on public.login_history(user_id,created_at desc);
alter table public.login_history enable row level security;
drop policy if exists login_history_select_own on public.login_history;
create policy login_history_select_own on public.login_history for select to authenticated using(user_id=auth.uid() or public.is_admin());
drop policy if exists login_history_insert_own on public.login_history;
create policy login_history_insert_own on public.login_history for insert to authenticated with check(user_id=auth.uid());

-- ============================================================
-- 2. WALLET TOP UP
-- ============================================================
create table if not exists public.wallet_topups (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  amount numeric not null check(amount > 0),
  method text not null default 'QRIS',
  proof_path text,
  status text not null default 'pending' check(status in ('pending','approved','rejected')),
  rejection_reason text,
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists wallet_topups_user_idx on public.wallet_topups(user_id,created_at desc);
create index if not exists wallet_topups_status_idx on public.wallet_topups(status,created_at desc);
alter table public.wallet_topups enable row level security;
drop policy if exists wallet_topups_select_own on public.wallet_topups;
create policy wallet_topups_select_own on public.wallet_topups for select to authenticated using(user_id=auth.uid() or public.is_admin());
drop policy if exists wallet_topups_insert_own on public.wallet_topups;
create policy wallet_topups_insert_own on public.wallet_topups for insert to authenticated with check(user_id=auth.uid());
drop policy if exists wallet_topups_admin_update on public.wallet_topups;
create policy wallet_topups_admin_update on public.wallet_topups for update to authenticated using(public.is_admin()) with check(public.is_admin());

-- Storage policies for wallet proof uploads in existing private bucket.
drop policy if exists wallet_proof_insert_own on storage.objects;
create policy wallet_proof_insert_own on storage.objects for insert to authenticated
with check(bucket_id='zackstore-files' and (storage.foldername(name))[1]=auth.uid()::text);
drop policy if exists wallet_proof_select_own on storage.objects;
create policy wallet_proof_select_own on storage.objects for select to authenticated
using(bucket_id='zackstore-files' and ((storage.foldername(name))[1]=auth.uid()::text or public.is_admin()));

-- ============================================================
-- 3. REFERRAL CLAIMS (fix V6 unique-code conflict)
-- ============================================================
create table if not exists public.referral_claims (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  referrer_id uuid not null references auth.users(id) on delete cascade,
  referred_id uuid not null unique references auth.users(id) on delete cascade,
  status text not null default 'pending' check(status in ('pending','qualified','rejected','cancelled')),
  reward_amount numeric not null default 0,
  qualified_at timestamptz,
  created_at timestamptz not null default now(),
  unique(code,referred_id)
);
create index if not exists referral_claims_referrer_idx on public.referral_claims(referrer_id,created_at desc);
create index if not exists referral_claims_code_idx on public.referral_claims(upper(code));
alter table public.referral_claims enable row level security;
drop policy if exists referral_claims_select_own on public.referral_claims;
create policy referral_claims_select_own on public.referral_claims for select to authenticated using(referrer_id=auth.uid() or referred_id=auth.uid() or public.is_admin());

create or replace function public.claim_referral(p_code text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_code public.referrals%rowtype;
  v_existing uuid;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  select * into v_code from public.referrals
    where upper(code)=upper(btrim(p_code)) and referrer_id<>auth.uid() and status in ('active','pending')
    order by created_at asc limit 1;
  if not found then raise exception 'referral_code_not_found'; end if;
  if exists(select 1 from public.referral_claims where referred_id=auth.uid()) then raise exception 'referral_already_claimed'; end if;
  if exists(select 1 from public.referral_claims where code=upper(btrim(p_code)) and referred_id=auth.uid()) then raise exception 'referral_already_claimed'; end if;
  insert into public.referral_claims(code,referrer_id,referred_id,status)
  values(upper(btrim(p_code)),v_code.referrer_id,auth.uid(),'pending');
  insert into public.notifications(user_id,title,message,type)
  values(auth.uid(),'Referral berhasil','Kode referral berhasil dikaitkan ke akunmu. Bonus akan diproses setelah syarat terpenuhi.','referral');
  return jsonb_build_object('ok',true,'code',upper(btrim(p_code)));
end;
$$;
grant execute on function public.claim_referral(text) to authenticated;

-- ============================================================
-- 4. RENTAL EXTENSION
-- ============================================================
create table if not exists public.rental_extensions (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  multiplier integer not null check(multiplier between 1 and 12),
  amount numeric not null check(amount >= 0),
  starts_at timestamptz not null default now(),
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
create index if not exists rental_extensions_order_idx on public.rental_extensions(order_id,created_at desc);
alter table public.rental_extensions enable row level security;
drop policy if exists rental_extensions_select_own on public.rental_extensions;
create policy rental_extensions_select_own on public.rental_extensions for select to authenticated using(user_id=auth.uid() or public.is_admin());

create or replace function public.extend_rental_with_wallet(p_order_id uuid,p_multiplier integer)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_order public.orders%rowtype;
  v_bot public.bot_packages%rowtype;
  v_profile public.profiles%rowtype;
  v_amount numeric;
  v_days numeric;
  v_base_exp timestamptz;
  v_new_exp timestamptz;
  v_duration text;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if p_multiplier < 1 or p_multiplier > 12 then raise exception 'invalid_multiplier'; end if;
  select * into v_order from public.orders where id=p_order_id and user_id=auth.uid() for update;
  if not found then raise exception 'order_not_found'; end if;
  if v_order.status not in ('active','paid') or v_order.payment_status<>'paid' then raise exception 'rental_not_active'; end if;
  select * into v_bot from public.bot_packages where id=v_order.bot_id;
  if not found then raise exception 'bot_not_found'; end if;
  v_amount=greatest(0,coalesce(v_bot.price,0))*p_multiplier;
  select * into v_profile from public.profiles where id=auth.uid() for update;
  if coalesce(v_profile.balance,0)<v_amount then raise exception 'wallet_insufficient'; end if;
  v_duration=coalesce(v_bot.duration,'30 hari');
  if v_duration ~* '(jam|hour)' then v_days=coalesce(substring(v_duration from '([0-9]+(?:\.[0-9]+)?)')::numeric,24)/24;
  elsif v_duration ~* '(minggu|week)' then v_days=coalesce(substring(v_duration from '([0-9]+(?:\.[0-9]+)?)')::numeric,1)*7;
  else v_days=coalesce(substring(v_duration from '([0-9]+(?:\.[0-9]+)?)')::numeric,30)*(case when v_duration ~* '(bulan|month)' then 30 else 1 end);
  end if;
  v_base_exp=greatest(coalesce(v_order.expires_at,now()),now());
  v_new_exp=v_base_exp+(v_days*p_multiplier)*interval '1 day';
  update public.profiles set balance=coalesce(balance,0)-v_amount where id=auth.uid();
  insert into public.wallet_transactions(user_id,amount,type,description,reference_id) values(auth.uid(),-v_amount,'debit','Perpanjangan rental #'||left(p_order_id::text,8),p_order_id);
  update public.orders set expires_at=v_new_exp,status='active',bot_status='online' where id=p_order_id;
  insert into public.rental_extensions(order_id,user_id,multiplier,amount,starts_at,expires_at) values(p_order_id,auth.uid(),p_multiplier,v_amount,v_base_exp,v_new_exp);
  insert into public.notifications(user_id,title,message,type) values(auth.uid(),'Rental diperpanjang','Masa aktif bot berhasil diperpanjang.','rental');
  return jsonb_build_object('ok',true,'amount',v_amount,'expires_at',v_new_exp);
end;
$$;
grant execute on function public.extend_rental_with_wallet(uuid,integer) to authenticated;

-- ============================================================
-- 5. ADMIN WALLET RPCs
-- ============================================================
create or replace function public.admin_adjust_wallet(p_user_id uuid,p_amount numeric,p_description text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  if p_amount=0 then raise exception 'invalid_amount'; end if;
  update public.profiles set balance=greatest(0,coalesce(balance,0)+p_amount) where id=p_user_id;
  if not found then raise exception 'user_not_found'; end if;
  insert into public.wallet_transactions(user_id,amount,type,description,reference_id)
  values(p_user_id,p_amount,'admin_adjustment',coalesce(p_description,'Admin wallet adjustment'),null);
  insert into public.notifications(user_id,title,message,type)
  values(p_user_id,'Saldo wallet diperbarui','Saldo wallet kamu diperbarui oleh admin sebesar '||p_amount::text||'.','wallet');
  return jsonb_build_object('ok',true,'amount',p_amount);
end;
$$;
grant execute on function public.admin_adjust_wallet(uuid,numeric,text) to authenticated;

create or replace function public.admin_verify_wallet_topup(p_topup_id uuid,p_approve boolean,p_rejection_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare v public.wallet_topups%rowtype;
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  select * into v from public.wallet_topups where id=p_topup_id for update;
  if not found then raise exception 'topup_not_found'; end if;
  if v.status<>'pending' then raise exception 'topup_already_reviewed'; end if;
  if p_approve then
    update public.wallet_topups set status='approved',reviewed_by=auth.uid(),reviewed_at=now(),rejection_reason=null where id=v.id;
    update public.profiles set balance=coalesce(balance,0)+v.amount where id=v.user_id;
    insert into public.wallet_transactions(user_id,amount,type,description,reference_id) values(v.user_id,v.amount,'credit','Top up wallet disetujui',v.id);
    insert into public.notifications(user_id,title,message,type) values(v.user_id,'Top up disetujui','Saldo wallet bertambah '||v.amount::text||'.','wallet');
  else
    update public.wallet_topups set status='rejected',reviewed_by=auth.uid(),reviewed_at=now(),rejection_reason=p_rejection_reason where id=v.id;
    insert into public.notifications(user_id,title,message,type) values(v.user_id,'Top up ditolak',coalesce(p_rejection_reason,'Bukti pembayaran ditolak.'),'wallet');
  end if;
  return jsonb_build_object('ok',true,'approved',p_approve);
end;
$$;
grant execute on function public.admin_verify_wallet_topup(uuid,boolean,text) to authenticated;

-- ============================================================
-- 6. BACKEND AUTO EXPIRE RPC
-- ============================================================
create or replace function public.expire_due_rentals()
returns integer
language plpgsql
security definer
set search_path=public
as $$
declare v_count integer;
begin
  update public.orders
  set status='completed',bot_status='offline'
  where status='active' and expires_at is not null and expires_at<=now();
  get diagnostics v_count=row_count;
  insert into public.notifications(user_id,title,message,type)
  select user_id,'Bot expired','Masa sewa bot telah berakhir.','expired'
  from public.orders where status='completed' and expires_at is not null and expires_at<=now()
    and updated_at>=now()-interval '2 minutes';
  return v_count;
end;
$$;
grant execute on function public.expire_due_rentals() to authenticated;

-- ============================================================
-- 7. REFERRAL QUALIFICATION: sync old admin reward flow into claims
-- ============================================================
-- Existing admin_verify_payment remains source of truth. This trigger mirrors
-- a qualified legacy referral row into referral_claims when possible.
create or replace function public.sync_referral_claim_on_legacy()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.referred_id is not null and not exists(select 1 from public.referral_claims where referred_id=new.referred_id) then
    insert into public.referral_claims(code,referrer_id,referred_id,status,reward_amount,qualified_at)
    values(upper(new.code),new.referrer_id,new.referred_id,new.status,coalesce(new.reward_amount,new.bonus,0),new.qualified_at)
    on conflict(referred_id) do update set status=excluded.status,reward_amount=excluded.reward_amount,qualified_at=excluded.qualified_at;
  end if;
  return new;
end;$$;
drop trigger if exists trg_sync_referral_claim on public.referrals;
create trigger trg_sync_referral_claim after insert or update on public.referrals for each row execute function public.sync_referral_claim_on_legacy();

-- ============================================================
-- 8. SAFE INDEXES
-- ============================================================
create index if not exists orders_user_status_expiry_idx on public.orders(user_id,status,expires_at);
create index if not exists payments_status_created_idx on public.payments(status,created_at desc);
create index if not exists notifications_user_read_idx on public.notifications(user_id,read,created_at desc);
create index if not exists wallet_transactions_user_created_idx on public.wallet_transactions(user_id,created_at desc);

-- NOTE: If pg_cron is enabled in the project, schedule:
-- select cron.schedule('zackstore-expire-rentals','*/5 * * * *','select public.expire_due_rentals();');
-- Otherwise the frontend continues to run its expiry check as a fallback.

-- ============================================================
-- 9. FINAL PAYMENT + REFERRAL REWARD HARDENING
--    New referral_claims is the canonical claim table. Legacy
--    referrals remains supported for existing data.
-- ============================================================
create or replace function public.admin_verify_payment(
  p_payment_id uuid,
  p_order_id uuid,
  p_approve boolean,
  p_rejection_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_order public.orders%rowtype;
  v_payment public.payments%rowtype;
  v_bot public.bot_packages%rowtype;
  v_expires timestamptz;
  v_duration text;
  v_reward numeric := 0;
  v_claim public.referral_claims%rowtype;
  v_ref public.referrals%rowtype;
  v_rewarded boolean := false;
begin
  if not public.is_admin() then raise exception 'admin_only'; end if;

  select * into v_payment
  from public.payments
  where id=p_payment_id and order_id=p_order_id
  for update;
  if not found then raise exception 'payment_not_found'; end if;

  select * into v_order from public.orders where id=p_order_id for update;
  if not found then raise exception 'order_not_found'; end if;
  if v_payment.status <> 'pending' then raise exception 'payment_already_reviewed'; end if;

  if p_approve then
    select * into v_bot from public.bot_packages where id=v_order.bot_id;
    if not found then raise exception 'bot_not_found'; end if;

    v_duration := coalesce(v_bot.duration,'');
    if v_duration ~* '(jam|hour)' then
      v_expires := now()+((coalesce(substring(v_duration from '([0-9]+(?:\.[0-9]+)?)')::numeric,1))*interval '1 hour');
    elsif v_duration ~* '(minggu|week)' then
      v_expires := now()+((coalesce(substring(v_duration from '([0-9]+(?:\.[0-9]+)?)')::numeric,1))*interval '7 days');
    elsif v_duration ~* '(bulan|month)' then
      v_expires := now()+((coalesce(substring(v_duration from '([0-9]+(?:\.[0-9]+)?)')::numeric,1))*interval '30 days');
    else
      v_expires := now()+((coalesce(substring(v_duration from '([0-9]+(?:\.[0-9]+)?)')::numeric,30))*interval '1 day');
    end if;

    update public.payments
    set status='verified', reviewed_by=auth.uid(), reviewed_at=now(), rejection_reason=null
    where id=p_payment_id;

    update public.orders
    set payment_status='paid', status='active', starts_at=now(), expires_at=v_expires, bot_status='online'
    where id=p_order_id;

    if v_order.voucher_code is not null and btrim(v_order.voucher_code)<>'' then
      insert into public.voucher_usages(voucher_id,user_id,order_id)
      select id,v_order.user_id,p_order_id
      from public.vouchers
      where upper(code)=upper(v_order.voucher_code)
      limit 1
      on conflict do nothing;
    end if;

    -- Read the configured referral reward.
    select coalesce((value->>'reward')::numeric,0)
      into v_reward
    from public.app_settings
    where key='referral';
    v_reward := greatest(0,coalesce(v_reward,0));

    -- Prefer the new claim table. The reward is protected by changing
    -- the claim to qualified before any future review can reward it again.
    select * into v_claim
    from public.referral_claims
    where referred_id=v_order.user_id and status='pending'
    order by created_at asc
    limit 1
    for update;

    if found then
      if v_reward>0 then
        update public.profiles
        set balance=coalesce(balance,0)+v_reward
        where id=v_claim.referrer_id;

        insert into public.wallet_transactions(user_id,amount,type,description,reference_id)
        values(v_claim.referrer_id,v_reward,'referral','Bonus referral order #'||left(p_order_id::text,8),p_order_id);
      end if;

      update public.referral_claims
      set status='qualified', reward_amount=v_reward, qualified_at=now()
      where id=v_claim.id;
      v_rewarded := true;

      insert into public.notifications(user_id,title,message,type)
      values(
        v_claim.referrer_id,
        'Bonus referral masuk',
        case when v_reward>0
          then 'Kamu menerima bonus referral sebesar '||v_reward::text||'.'
          else 'Referral berhasil memenuhi syarat.'
        end,
        'referral'
      );
    else
      -- Backward compatibility for old referral rows created before
      -- referral_claims existed.
      select * into v_ref
      from public.referrals
      where referred_id=v_order.user_id and status='pending'
      order by created_at asc
      limit 1
      for update;

      if found then
        if v_reward>0 then
          update public.profiles
          set balance=coalesce(balance,0)+v_reward
          where id=v_ref.referrer_id;

          insert into public.wallet_transactions(user_id,amount,type,description,reference_id)
          values(v_ref.referrer_id,v_reward,'referral','Bonus referral order #'||left(p_order_id::text,8),p_order_id);
        end if;

        update public.referrals
        set status='qualified', reward_amount=v_reward, qualified_at=now()
        where id=v_ref.id;

        -- Keep the new claim table synchronized for old accounts.
        insert into public.referral_claims(code,referrer_id,referred_id,status,reward_amount,qualified_at)
        values(upper(v_ref.code),v_ref.referrer_id,v_ref.referred_id,'qualified',v_reward,now())
        on conflict(referred_id) do update
          set status='qualified', reward_amount=excluded.reward_amount, qualified_at=excluded.qualified_at;

        v_rewarded := true;

        insert into public.notifications(user_id,title,message,type)
        values(
          v_ref.referrer_id,
          'Bonus referral masuk',
          case when v_reward>0
            then 'Kamu menerima bonus referral sebesar '||v_reward::text||'.'
            else 'Referral berhasil memenuhi syarat.'
          end,
          'referral'
        );
      end if;
    end if;

    insert into public.notifications(user_id,title,message,type)
    values(
      v_order.user_id,
      'Pembayaran diterima',
      'Pesanan #'||left(p_order_id::text,8)||' aktif sampai '||to_char(v_expires,'DD Mon YYYY HH24:MI'),
      'payment'
    );
  else
    update public.payments
    set status='rejected', reviewed_by=auth.uid(), reviewed_at=now(), rejection_reason=p_rejection_reason
    where id=p_payment_id;

    update public.orders set payment_status='rejected' where id=p_order_id;

    insert into public.notifications(user_id,title,message,type)
    values(
      v_order.user_id,
      'Pembayaran ditolak',
      'Bukti pembayaran pesanan #'||left(p_order_id::text,8)||' ditolak.'||
        case when p_rejection_reason is not null and btrim(p_rejection_reason)<>''
          then ' Alasan: '||p_rejection_reason else '' end,
      'payment'
    );
  end if;

  return jsonb_build_object(
    'ok',true,
    'order_id',p_order_id,
    'approved',p_approve,
    'referral_rewarded',v_rewarded
  );
end;
$$;

grant execute on function public.admin_verify_payment(uuid,uuid,boolean,text) to authenticated;

-- Wallet payment must also reject cancelled orders.
create or replace function public.pay_order_with_wallet(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_order public.orders%rowtype;
  v_balance numeric;
  v_amount numeric;
  v_bot public.bot_packages%rowtype;
  v_duration text;
  v_expires timestamptz;
  v_reward numeric := 0;
  v_claim public.referral_claims%rowtype;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  select * into v_order from public.orders where id=p_order_id and user_id=auth.uid() for update;
  if not found then raise exception 'order_not_found'; end if;
  if v_order.status='cancelled' then raise exception 'order_cancelled'; end if;
  if v_order.payment_status='paid' or v_order.status in ('active','completed') then raise exception 'order_already_paid'; end if;
  v_amount:=greatest(0,coalesce(v_order.final_price,v_order.price,0));
  select balance into v_balance from public.profiles where id=auth.uid() for update;
  if coalesce(v_balance,0)<v_amount then raise exception 'wallet_insufficient'; end if;
  select * into v_bot from public.bot_packages where id=v_order.bot_id;
  if not found then raise exception 'bot_not_found'; end if;
  v_duration:=coalesce(v_bot.duration,'');
  if v_duration ~* '(jam|hour)' then
    v_expires:=now()+((coalesce(substring(v_duration from '([0-9]+(?:\.[0-9]+)?)')::numeric,1))*interval '1 hour');
  elsif v_duration ~* '(minggu|week)' then
    v_expires:=now()+((coalesce(substring(v_duration from '([0-9]+(?:\.[0-9]+)?)')::numeric,1))*interval '7 days');
  elsif v_duration ~* '(bulan|month)' then
    v_expires:=now()+((coalesce(substring(v_duration from '([0-9]+(?:\.[0-9]+)?)')::numeric,1))*interval '30 days');
  else
    v_expires:=now()+((coalesce(substring(v_duration from '([0-9]+(?:\.[0-9]+)?)')::numeric,30))*interval '1 day');
  end if;
  update public.profiles set balance=coalesce(balance,0)-v_amount where id=auth.uid();
  insert into public.wallet_transactions(user_id,amount,type,description,reference_id)
  values(auth.uid(),-v_amount,'debit','Pembayaran rental #'||left(p_order_id::text,8),p_order_id);
  update public.orders set payment_status='paid',status='active',payment_method='Wallet',starts_at=now(),expires_at=v_expires,bot_status='online' where id=p_order_id;
  insert into public.payments(order_id,user_id,amount,method,status,note,verified_at)
  values(p_order_id,auth.uid(),v_amount,'Wallet','verified','Dibayar menggunakan saldo wallet',now());

  select coalesce((value->>'reward')::numeric,0) into v_reward from public.app_settings where key='referral';
  v_reward:=greatest(0,coalesce(v_reward,0));
  select * into v_claim from public.referral_claims where referred_id=auth.uid() and status='pending' order by created_at asc limit 1 for update;
  if found then
    if v_reward>0 then
      update public.profiles set balance=coalesce(balance,0)+v_reward where id=v_claim.referrer_id;
      insert into public.wallet_transactions(user_id,amount,type,description,reference_id)
      values(v_claim.referrer_id,v_reward,'referral','Bonus referral order #'||left(p_order_id::text,8),p_order_id);
    end if;
    update public.referral_claims set status='qualified',reward_amount=v_reward,qualified_at=now() where id=v_claim.id;
    insert into public.notifications(user_id,title,message,type)
    values(v_claim.referrer_id,'Bonus referral masuk',case when v_reward>0 then 'Kamu menerima bonus referral sebesar '||v_reward::text||'.' else 'Referral berhasil memenuhi syarat.' end,'referral');
  end if;
  insert into public.notifications(user_id,title,message,type)
  values(auth.uid(),'Pembayaran Wallet berhasil','Pesanan #'||left(p_order_id::text,8)||' berhasil dibayar dan rental aktif.','payment');
  return jsonb_build_object('ok',true,'message','Saldo wallet berhasil digunakan','amount',v_amount,'expires_at',v_expires,'referral_rewarded',found);
end;
$$;
grant execute on function public.pay_order_with_wallet(uuid) to authenticated;

-- Admin wallet adjustment hardening
create or replace function public.admin_adjust_wallet(p_user_id uuid, p_amount numeric, p_description text default 'Penyesuaian saldo oleh admin')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  new_balance numeric;
begin
  if not public.is_admin() then
    raise exception 'admin_only';
  end if;
  if p_user_id is null or p_amount is null or p_amount = 0 then
    raise exception 'invalid_wallet_adjustment';
  end if;
  if not exists (select 1 from public.profiles where id=p_user_id) then
    raise exception 'user_not_found';
  end if;
  update public.profiles
    set balance = greatest(0, coalesce(balance,0) + p_amount)
  where id=p_user_id
  returning balance into new_balance;
  insert into public.wallet_transactions(user_id,amount,type,description)
  values(p_user_id,p_amount,'admin_adjustment',coalesce(nullif(trim(p_description),''),'Penyesuaian saldo oleh admin'));
  insert into public.notifications(user_id,title,message,type)
  values(p_user_id,'Saldo wallet diperbarui',case when p_amount>0 then 'Admin menambahkan '||to_char(p_amount,'FM999G999G999G999')||' ke wallet kamu.' else 'Admin menyesuaikan saldo wallet kamu sebesar '||to_char(abs(p_amount),'FM999G999G999G999')||'.' end,'wallet');
  return jsonb_build_object('balance',new_balance,'amount',p_amount);
end;
$$;
revoke all on function public.admin_adjust_wallet(uuid,numeric,text) from public;
grant execute on function public.admin_adjust_wallet(uuid,numeric,text) to authenticated;
