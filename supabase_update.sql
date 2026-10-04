-- ============================================================
-- تسوق واربح — تحديث: تبسيط دورة الطلب + تسعيرة التوصيل
-- التشغيل: Supabase Dashboard → SQL Editor → الصق وشغّل
-- ============================================================
--
-- التغييرات في الدورة:
--  1. العربون يروح للموصّل مباشرة (كان يروح للبائع)
--  2. سومة التوصيل محسوبة أوتوماتيكيا: داخل نفس الولاية حسب
--     المسافة، وبين الولايات حسب جدول الموصّل
--  3. التفاوض يبقى غير للحالة الاستثنائية (بين الولايات
--     والموصّل ما حددش سومة للولاية)

-- ---------- 1) أعمدة جديدة ----------
alter table public.profiles add column if not exists wilaya int;
alter table public.profiles add column if not exists ship_prices jsonb not null default '{}'::jsonb;
alter table public.orders   add column if not exists buyer_wilaya int;

-- ---------- 2) create_order: ولاية التسليم ----------
-- (احذف النسخة القديمة حيت السينيور تبدلات)
drop function if exists public.create_order(bigint, integer, text, bigint);

create function public.create_order(p_product bigint, p_qty integer, p_addr text, p_deal bigint default null, p_wilaya integer default null)
 returns bigint
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  p public.products%rowtype;
  v_saddr text;
  v_unit_fee int;
  v_com int := 0;
  v_promoter uuid;
  v_deal public.deals%rowtype;
  v_sold int;
  v_pc int;
  v_id bigint;
begin
  if v_uid is null then raise exception 'سجّل الدخول أولاً'; end if;
  if p_qty is null or p_qty < 1 then raise exception 'كمية غير صحيحة'; end if;
  if p_addr is null or char_length(trim(p_addr)) < 2 then raise exception 'أدخل عنوان التسليم'; end if;
  if p_wilaya is null then raise exception 'اختر ولاية التسليم'; end if;
  select * into p from public.products where id = p_product and active for update;
  if not found then raise exception 'المنتج غير متوفر'; end if;
  if p.seller_id = v_uid then raise exception 'لا يمكنك شراء منتجك'; end if;
  if p_qty < p.min_qty then raise exception 'أقل كمية للطلب هي %', p.min_qty; end if;
  if p_qty > p.stock then raise exception 'الكمية غير متوفرة'; end if;
  select addr into v_saddr from public.profiles where id = p.seller_id;
  v_unit_fee := public.site_fee(p.price);

  if p_deal is not null then
    select * into v_deal from public.deals
      where id = p_deal and product_id = p.id and status = 'agreed';
    if found and v_deal.promoter_id <> v_uid then
      select coalesce(sum(qty), 0) into v_sold from public.orders
        where deal_id = v_deal.id and status <> 'no';
      v_pc := case when v_deal.tier_qty > 0 and v_sold + p_qty >= v_deal.tier_qty
                   then v_deal.tier_com else v_deal.com end;
      v_com := least(v_pc * p_qty, p.price * p_qty);
      v_promoter := v_deal.promoter_id;
    end if;
  end if;

  insert into public.orders (product_id, product_name, seller_id, buyer_id, promoter_id, deal_id,
      qty, unit_price, total, platform_fee, promoter_com, buyer_addr, seller_addr, buyer_wilaya)
  values (p.id, p.name, p.seller_id, v_uid, v_promoter, case when v_promoter is null then null else v_deal.id end,
      p_qty, p.price, (p.price + v_unit_fee) * p_qty, v_unit_fee * p_qty, v_com,
      trim(p_addr), coalesce(v_saddr, ''), p_wilaya)
  returning id into v_id;

  insert into public.order_secrets (order_id, pickup_code, delivery_code)
    values (v_id, public._code(), public._code());
  update public.products set stock = stock - p_qty where id = p.id;
  return v_id;
end $function$;

-- ---------- 3) الموصّل يأكّد التوصيل (جديدة) ----------
-- تعوّض driver_offer في الحالة العادية.
-- الواجهة تحسب السومة وتبعثها جاهزة (p_fee).
-- (نحذف النسخ القديمة الغالطة أولاً إن وجدت)
drop function if exists public.driver_confirm(int, numeric, numeric);

create function public.driver_confirm(p_order bigint, p_km numeric, p_fee numeric)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_status text;
  v_driver uuid;
  v_buyer_wilaya int;
  v_seller_wilaya int;
  v_seller_id uuid;
begin
  if v_uid is null then raise exception 'سجّل الدخول أولاً'; end if;
  select status, driver_id, buyer_wilaya, seller_id
    into v_status, v_driver, v_buyer_wilaya, v_seller_id
    from public.orders where id = p_order for update;
  if not found then raise exception 'الطلب غير موجود'; end if;
  if v_status <> 'open' then raise exception 'الطلب غير متاح'; end if;
  if v_driver is not null then raise exception 'الطلب عنده موصّل'; end if;
  if p_fee is null or p_fee <= 0 then raise exception 'سومة غير صحيحة'; end if;
  if v_buyer_wilaya is null then raise exception 'ولاية التسليم ناقصة'; end if;

  select wilaya into v_seller_wilaya from public.profiles where id = v_seller_id;
  -- داخل نفس الولاية: المسافة لازمة (السومة محسوبة منها)
  if v_seller_wilaya is not null
     and v_buyer_wilaya = v_seller_wilaya
     and (p_km is null or p_km <= 0) then
    raise exception 'أدخل المسافة';
  end if;

  update public.orders
     set driver_id    = v_uid,
         km           = p_km,
         delivery_fee = p_fee,
         status       = 'topay'
   where id = p_order;
end $function$;

-- ---------- 4) الموصّل يأكّد العربون (جديدة، تعوّض seller_confirm_deposit) ----------
drop function if exists public.driver_confirm_deposit(int);

create function public.driver_confirm_deposit(p_order bigint)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_status text;
  v_driver uuid;
begin
  if v_uid is null then raise exception 'سجّل الدخول أولاً'; end if;
  select status, driver_id into v_status, v_driver
    from public.orders where id = p_order;
  if not found then raise exception 'الطلب غير موجود'; end if;
  if v_driver is distinct from v_uid then raise exception 'ليس طلبك'; end if;
  if v_status <> 'review' then raise exception 'ليس وقت التأكيد'; end if;

  update public.order_secrets set pickup_code = public._code() where order_id = p_order;
  update public.orders set status = 'paid' where id = p_order;
end $function$;

-- ---------- 5) الموصّل يرفض العربون (جديدة، تعوّض seller_reject_deposit) ----------
drop function if exists public.driver_reject_deposit(int);

create function public.driver_reject_deposit(p_order bigint)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_status text;
  v_driver uuid;
begin
  if v_uid is null then raise exception 'سجّل الدخول أولاً'; end if;
  select status, driver_id into v_status, v_driver
    from public.orders where id = p_order;
  if not found then raise exception 'الطلب غير موجود'; end if;
  if v_driver is distinct from v_uid then raise exception 'ليس طلبك'; end if;
  if v_status <> 'review' then raise exception 'ليس وقت الرفض'; end if;

  update public.orders set status = 'topay' where id = p_order;
end $function$;

-- ============================================================
-- ---------- 6) تعديل أخير: my_orders ----------
-- زيد هذي الأسطر الثلاثة داخل jsonb_build_object:
--     'buyer_wilaya', o.buyer_wilaya,
--     'seller_wilaya', s.wilaya,
--     'driver_pay', case when f.fb and o.status in ('topay','review') then dr.pay end,
-- (النسخة الكاملة المعدلة تجدها في المحادثة / جاهزة للصق)
-- ============================================================

-- دوال ما يتبدل فيها والو:
--   - buyer_pay      : تخزن إثبات الدفع برك (المستلم ولى الموصّل في العرض فقط)
--   - driver_settle  : التصفية ولات بلا خصم — الموصّل يحوّل مستحقات
--                      البائع كاملة (العربون عندو هو من قبل)
-- دوال ما عادش تتعيط (تقدر تخليها):
--   - seller_confirm_deposit / seller_reject_deposit
--   - driver_offer تبقى مستعملة غير للحالة الاستثنائية
--     (توصيل بين الولايات والموصّل ما حددش سومة للولاية)
