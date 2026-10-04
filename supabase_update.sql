-- ============================================================
-- تسوق واربح — تحديث: تبسيط دورة الطلب + تسعيرة التوصيل
-- التشغيل: Supabase Dashboard → SQL Editor → الصق وشغّل
-- ============================================================
--
-- ⚠️ ملاحظة: أسماء الجداول/الأعمدة مبنية على البنية المستنتجة
-- من الواجهة (profiles / orders). قارنها مع جداولك قبل التشغيل
-- وبدّل الاسم إذا كان مختلف عندك.
--
-- التغييرات في الدورة:
--  1. العربون يروح للموصّل مباشرة (كان يروح للبائع)
--  2. سومة التوصيل محسوبة أوتوماتيكيا: داخل نفس الولاية حسب
--     المسافة، وبين الولايات حسب جدول الموصّل
--  3. التفاوض يبقى غير للحالة الاستثنائية (بين الولايات
--     والموصّل ما حددش سومة للولاية)

-- ---------- 1) أعمدة جديدة ----------
alter table profiles add column if not exists wilaya int;
alter table profiles add column if not exists ship_prices jsonb not null default '{}'::jsonb;
alter table orders   add column if not exists buyer_wilaya int;

-- ---------- 2) الموصّل يأكّد التوصيل (جديدة) ----------
-- تعوّض driver_offer في الحالة العادية.
-- الواجهة تحسب السومة وتبعثها جاهزة (p_fee).
create or replace function driver_confirm(p_order int, p_km numeric, p_fee numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
  v_driver uuid;
  v_buyer_wilaya int;
  v_seller_wilaya int;
  v_seller_id uuid;
begin
  select status, driver_id, buyer_wilaya, seller_id
    into v_status, v_driver, v_buyer_wilaya, v_seller_id
    from orders where id = p_order;
  if not found then raise exception 'الطلب ماشي موجود'; end if;
  if v_status <> 'open' then raise exception 'الطلب ماشي متاح'; end if;
  if v_driver is not null then raise exception 'الطلب عندو موصّل'; end if;
  if p_fee is null or p_fee <= 0 then raise exception 'السومة ماشي صحيحة'; end if;
  if v_buyer_wilaya is null then raise exception 'ولاية التسليم ناقصة'; end if;

  select wilaya into v_seller_wilaya from profiles where id = v_seller_id;
  -- داخل نفس الولاية: المسافة لازمة (السومة محسوبة منها)
  if v_seller_wilaya is not null
     and v_buyer_wilaya = v_seller_wilaya
     and (p_km is null or p_km <= 0) then
    raise exception 'دخل المسافة';
  end if;

  update orders
     set driver_id    = auth.uid(),
         km           = p_km,
         delivery_fee = p_fee,
         status       = 'topay'
   where id = p_order;
end;
$$;

-- ---------- 3) الموصّل يأكّد العربون (جديدة، تعوّض seller_confirm_deposit) ----------
create or replace function driver_confirm_deposit(p_order int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
  v_driver uuid;
  v_code text;
begin
  select status, driver_id into v_status, v_driver
    from orders where id = p_order;
  if not found then raise exception 'الطلب ماشي موجود'; end if;
  if v_driver is distinct from auth.uid() then raise exception 'ماشي الطلب تاعك'; end if;
  if v_status <> 'review' then raise exception 'ماشي وقت التأكيد'; end if;

  v_code := lpad((floor(random() * 900000) + 100000)::int::text, 6, '0');

  update orders
     set pickup_code = v_code,
         status = 'paid'
   where id = p_order;
end;
$$;

-- ---------- 4) الموصّل يرفض العربون (جديدة، تعوّض seller_reject_deposit) ----------
create or replace function driver_reject_deposit(p_order int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
  v_driver uuid;
begin
  select status, driver_id into v_status, v_driver
    from orders where id = p_order;
  if not found then raise exception 'الطلب ماشي موجود'; end if;
  if v_driver is distinct from auth.uid() then raise exception 'ماشي الطلب تاعك'; end if;
  if v_status <> 'review' then raise exception 'ماشي وقت الرفض'; end if;

  update orders set status = 'topay' where id = p_order;
end;
$$;

-- ============================================================
-- ---------- 5) تعديلات يدوية على الدوال الموجودة ----------
-- (انسخ التعديلات هذي لدوالك في SQL Editor)
-- ============================================================

-- 5.أ) create_order:
--     - زيد پارامتر جديد: p_wilaya int
--     - في الـ INSERT زيد: buyer_wilaya = p_wilaya

-- 5.ب) my_orders:
--     - زيد في الـ SELECT هذي الأعمدة الثلاثة:
--         o.buyer_wilaya,
--         (select p.wilaya from profiles p where p.id = o.seller_id) as seller_wilaya,
--         (select p.pay    from profiles p where p.id = o.driver_id) as driver_pay

-- 5.ج) دوال ما يتبدل فيها والو:
--     - buyer_pay      : تخزن إثبات الدفع برك (المستلم ولى الموصّل في العرض فقط)
--     - driver_settle  : التصفية ولات بلا خصم — الموصّل يحوّل مستحقات
--                        البائع كاملة (العربون عندو هو من قبل)

-- 5.د) دوال ما عادش تتعيط (تقدر تخليها ولا تحذفها):
--     - seller_confirm_deposit / seller_reject_deposit
--     - driver_offer تبقى مستعملة غير للحالة الاستثنائية
--       (توصيل بين الولايات والموصّل ما حددش سومة للولاية)
