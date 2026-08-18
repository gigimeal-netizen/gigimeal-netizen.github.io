-- ============================================================================
-- BOM 원가계산 리뉴얼 — 1단계: 스키마 + 기존 데이터 이관
-- 스펙: 2026-08-18_BOM원가계산_스펙.md
--
-- ★ 실행 방법 (처음이면 그대로 따라 하면 된다)
--   1. supabase.com 로그인 → 이 프로젝트 선택
--   2. 왼쪽 메뉴에서 "SQL Editor" 클릭 → "New query" 클릭
--   3. 이 파일 **전체**를 복사해서 붙여넣기 (PART D는 주석 처리돼 있어 실행되지 않는다)
--   4. 오른쪽 아래 "Run" 클릭 (또는 Ctrl+Enter)
--   5. 결과창에 표가 하나 나온다 → "판정" 열이 전부 OK면 성공 (PART C의 C-3 결과)
--
--   ※ 여러 쿼리를 한 번에 실행하면 SQL 에디터는 **마지막 쿼리 결과만** 보여준다.
--     그래서 확인표(C-3)를 일부러 맨 뒤에 뒀다. C-1/C-2 목록을 보고 싶으면
--     그 쿼리만 마우스로 드래그해서 선택한 뒤 Run 하면 그 결과만 나온다.
--
-- ★ 안전성
--   - 기존 테이블(recipes / ingredients / products / composite_products …)을
--     **읽기만 하고 전혀 수정하지 않는다.** 새 테이블에 insert만 한다.
--   - 그래서 문제가 생기면 PART D(롤백)로 새 테이블만 지우면 원래 상태로 완전히 돌아간다.
--   - 이 시점에 앱(account.html)은 아직 새 테이블을 쓰지 않는다 — 화면은 아무것도 안 바뀐다.
--
-- ★ 두 번 실행해도 안전한가?
--   PART B에 중복 방지 가드가 있다 — 이미 이관된 행이 있으면 그 부분을 건너뛴다.
--   그래도 되도록 한 번만 실행할 것.
--
-- ★ 검증
--   PART C의 쿼리를 실행해서 개수가 맞는지 확인한다. 원가 값 자체의 대조는
--   2단계(롤업 엔진)에서 앱 안에서 신·구 계산을 비교하는 방식으로 한다.
-- ============================================================================


-- ============================================================================
-- PART A — 새 테이블 / 함수 / 트리거
-- ============================================================================

-- 이름 정규화: account.html의 normalizeForMatch()와 동일한 규칙이어야 한다
-- (공백 전부 제거 + 소문자). 마이그레이션의 이름 매칭이 앱의 자동 매칭과 어긋나면
-- 같은 재료가 두 개로 갈라지므로 반드시 같은 규칙을 써야 한다.
create or replace function normalize_for_match(s text)
returns text language sql immutable as $$
  select lower(regexp_replace(coalesce(s, ''), '\s+', '', 'g'));
$$;

-- 통합 품목 마스터 (스펙 §4.1)
create table items (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,

  name text not null,
  kind text not null default 'purchased',      -- 'purchased' | 'made'
  category text not null default '',
  is_active boolean not null default true,

  -- 원가 산정 방식 (스펙 §3.3)
  cost_mode text not null default 'manual',    -- 'manual' | 'auto'
  -- ★ nullable이 중요하다 — null(미입력)과 0(0원으로 확정)을 구분해야 한다.
  --   묵은반죽에 의도적으로 0을 넣는 경우와 아직 안 넣은 경우가 다르다 (스펙 §10-6).
  manual_cost_per_gram numeric,
  manual_cost_per_ea numeric,

  -- 구매 정보 (kind='purchased')
  supplier_item_name text not null default '', -- 실제 구매품명("앵커버터") — name은 레시피 표시용("버터")
  purchase_amount numeric not null default 0,
  purchase_unit text not null default 'g',     -- 'g'|'kg'|'ml'|'l'|'ea'
  purchase_price numeric not null default 0,
  -- 개수 구매 시 (스펙 §12). usable이 주 입력, unit은 보조.
  usable_weight_g numeric,                     -- 1개당 실제 쓰는 무게(손질 후) — 계란이면 50
  unit_weight_g numeric,                       -- 1개 무게(구매 기준, 껍질 포함) — 계란이면 60

  -- 제조 정보 (kind='made')
  recipe_id uuid references recipes(id) on delete set null,  -- 배합 편집은 계산기에서 (스펙 §6.4)
  batch_yield_g numeric,                       -- null이면 하위 라인 무게 합계로 자동
  process_loss_pct numeric not null default 0,

  -- 판매 정보
  is_sellable boolean not null default false,
  selling_price numeric not null default 0,

  -- 마이그레이션 대응 관계 (구 테이블 → 새 테이블). 중복 실행 방지와 검증에 쓴다.
  -- 구 테이블을 완전히 제거하는 마지막 단계에서 같이 지워도 된다.
  legacy_ingredient_id uuid,
  legacy_product_id uuid,
  legacy_composite_id uuid,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index items_owner_idx on items(owner_id);
create index items_recipe_idx on items(recipe_id);
create index items_name_norm_idx on items(owner_id, normalize_for_match(name));

-- 품목 간 포함 관계 (스펙 §4.2)
create table bom_lines (
  id uuid primary key default gen_random_uuid(),
  parent_item_id uuid not null references items(id) on delete cascade,
  -- on delete restrict: 어딘가에 쓰이는 품목을 지우면 원가가 조용히 틀어진다.
  -- 지우려면 먼저 이 품목을 쓰는 배합에서 빼야 한다 (스펙 §10-4).
  child_item_id uuid references items(id) on delete restrict,

  display_name text not null default '',  -- 이 배합에서만 쓰는 표시명 (비우면 child.name)
  qty numeric not null default 0,
  qty_unit text not null default 'g',     -- 'pct' | 'g' | 'ea'
  loss_pct numeric not null default 0,    -- 투입 로스(성형/재단)
  is_flour boolean not null default false,-- qty_unit='pct'일 때 100% 기준 밀가루인지
  stage text not null default 'final',    -- 'pre'(사전발효) | 'final'
  sort_order integer not null default 0,

  created_at timestamptz not null default now()
);
create index bom_lines_parent_idx on bom_lines(parent_item_id);
create index bom_lines_child_idx on bom_lines(child_item_id);

-- 재료 가격 이력 (스펙 §7)
create table item_price_history (
  id bigint generated always as identity primary key,
  item_id uuid not null references items(id) on delete cascade,
  purchase_amount numeric not null default 0,
  purchase_unit text not null default 'g',
  purchase_price numeric not null default 0,
  price_per_gram numeric not null default 0,   -- 그 시점 환산 단가를 보존(나중에 규칙이 바뀌어도 기록은 유지)
  effective_date date not null default current_date,
  source text not null default 'manual',       -- 'manual' | 'csv' | 'ledger'
  note text not null default '',
  created_at timestamptz not null default now()
);
create index item_price_history_item_idx on item_price_history(item_id, effective_date desc);

-- RLS ------------------------------------------------------------------------
-- 스펙 §6.5: 원가/단가는 어떤 경우에도 공유하지 않는다 — 전부 owner-only.
-- 공유받은 레시피는 지금처럼 recipes.flours/ingredients만 읽으므로 여기 접근할 일이 없다.
alter table items enable row level security;
alter table bom_lines enable row level security;
alter table item_price_history enable row level security;

create policy "owner full access" on items for all
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- bom_lines / item_price_history는 owner_id가 없어서 부모(items)로 확인한다.
-- items 정책은 컬럼만 직접 보고 이 테이블들을 되조회하지 않으므로 순환이 없다
-- (composite_product_components가 쓰는 것과 같은 패턴).
create policy "owner full access via parent" on bom_lines for all
  using (exists (select 1 from items i where i.id = parent_item_id and i.owner_id = auth.uid()))
  with check (exists (select 1 from items i where i.id = parent_item_id and i.owner_id = auth.uid()));

create policy "owner full access via parent" on item_price_history for all
  using (exists (select 1 from items i where i.id = item_id and i.owner_id = auth.uid()))
  with check (exists (select 1 from items i where i.id = item_id and i.owner_id = auth.uid()));

-- 순환 참조 방지 (스펙 §4.3) --------------------------------------------------
-- cost_mode='auto'끼리 서로를 물면 원가 롤업이 무한 재귀한다. 클라이언트 검사만으로는
-- 부족하다(여러 탭/기기에서 동시 편집 가능) — DB에서 막는다.
-- SECURITY DEFINER: 재귀 CTE가 RLS에 걸려 일부 행을 못 보면 순환을 놓칠 수 있으므로.
create or replace function check_bom_cycle()
returns trigger language plpgsql security definer as $$
begin
  if new.child_item_id is null then return new; end if;

  if new.child_item_id = new.parent_item_id then
    raise exception '품목은 자기 자신을 포함할 수 없어요';
  end if;

  if exists (
    with recursive descendants as (
      select child_item_id as id from bom_lines
        where parent_item_id = new.child_item_id and child_item_id is not null
      union
      select b.child_item_id from bom_lines b
        join descendants d on b.parent_item_id = d.id
        where b.child_item_id is not null
    )
    select 1 from descendants where id = new.parent_item_id
  ) then
    raise exception '순환 참조가 생겨요 — 이 품목은 상위 품목 안에 이미 포함돼 있어요';
  end if;

  return new;
end; $$;

create trigger bom_lines_no_cycle before insert or update on bom_lines
  for each row execute function check_bom_cycle();


-- ============================================================================
-- PART B — 기존 데이터 이관
--   새 테이블에 insert만 한다. 기존 테이블은 읽기만.
-- ============================================================================

-- 이미 이관했으면 통째로 건너뛴다(중복 실행 방지).
do $migrate$
begin
if exists (select 1 from items limit 1) then
  raise notice '이미 이관된 데이터가 있어 PART B를 건너뜁니다.';
  return;
end if;

-- B-1. ingredients → items (구매 품목) ---------------------------------------
insert into items (
  owner_id, name, kind, cost_mode, category, is_active,
  purchase_amount, purchase_unit, purchase_price, legacy_ingredient_id
)
select
  ig.owner_id, ig.name, 'purchased', 'manual', ig.category, ig.is_active,
  ig.purchase_amount, ig.purchase_unit_type, ig.purchase_price, ig.id
from ingredients ig;

-- B-1b. 현재 단가를 가격 이력의 첫 행으로 기록 (스펙 §7.2)
--       구매량이 0인(= 아직 아무것도 입력 안 한) 품목은 이력을 만들지 않는다.
insert into item_price_history (item_id, purchase_amount, purchase_unit, purchase_price, price_per_gram, effective_date, source, note)
select
  i.id, i.purchase_amount, i.purchase_unit, i.purchase_price,
  case
    when i.purchase_unit = 'ea' then 0
    when i.purchase_amount * (case i.purchase_unit when 'kg' then 1000 when 'l' then 1000 else 1 end) > 0
      then i.purchase_price / (i.purchase_amount * (case i.purchase_unit when 'kg' then 1000 when 'l' then 1000 else 1 end))
    else 0
  end,
  coalesce(ig.updated_at::date, current_date), 'manual', '이관 시점의 단가'
from items i
join ingredients ig on ig.id = i.legacy_ingredient_id
where i.purchase_amount > 0;

-- B-2. recipes → items (제조 품목) --------------------------------------------
-- 모든 레시피가 대응 품목을 하나씩 갖는다. 배합 내용은 B-4에서 bom_lines로.
insert into items (owner_id, name, kind, cost_mode, recipe_id, is_sellable)
select r.owner_id, r.recipe_name, 'made', 'auto', r.id, false
from recipes r;

-- B-3. 레시피 재료 중 아직 품목이 없는 이름 → 구매 품목 자동 생성 (스펙 §8.1)
--   ingredientId가 비어 있고 이름도 기존 품목과 안 맞는 행들이 대상이다.
--   단가 0으로 만들어두면 앱의 "단가 미입력" 안내에 잡혀 사용자가 채워 넣게 된다.
--   ※ 여기서 "물"/"정수"처럼 사실상 같은 재료가 여러 개로 갈라질 수 있다(스펙 §10-2).
--     이건 예상된 일이고, 앱에서 "비슷한 이름 병합 제안"으로 정리한다.
with recipe_rows as (
  select r.owner_id, elem->>'name' as raw_name
  from recipes r
  cross join lateral jsonb_array_elements(coalesce(r.flours, '[]'::jsonb) || coalesce(r.ingredients, '[]'::jsonb)) as elem
  where coalesce(elem->>'name', '') <> ''
),
-- ★ distinct가 아니라 distinct on (owner, norm)이어야 한다.
--   "버터"와 "버 터"는 raw_name이 달라 distinct를 통과하지만 정규화하면 같은 이름이다.
--   그대로 두면 정규화 이름이 같은 품목이 두 개 생기고, B-4의 이름 조인이 곱해진다.
wanted as (
  select distinct on (owner_id, normalize_for_match(raw_name))
         owner_id, raw_name, normalize_for_match(raw_name) as norm
  from recipe_rows
  order by owner_id, normalize_for_match(raw_name), raw_name
)
insert into items (owner_id, name, kind, cost_mode, category, purchase_amount, purchase_price)
select w.owner_id, w.raw_name, 'purchased', 'manual', '미분류', 0, 0
from wanted w
where not exists (
  select 1 from items i
  where i.owner_id = w.owner_id
    and i.kind = 'purchased'
    and normalize_for_match(i.name) = w.norm
);

-- B-4. recipes.flours / recipes.ingredients (jsonb) → bom_lines ---------------
--   연결 우선순위: ① 기존 ingredientId → ② 정규화된 이름 매칭
--   (②는 B-3에서 만들어 둔 품목까지 포함하므로 반드시 하나는 잡힌다)
-- ★ 이름 조인은 반드시 (owner, 정규화이름)당 한 행만 나오게 미리 접어야 한다.
--   items에 정규화 이름이 같은 구매 품목이 둘 이상 있으면(기존 ingredients 데이터에
--   "버터"와 "버 터"가 같이 있는 경우 등) left join이 행을 곱해서 배합 라인이 중복 생성된다.
with name_lookup as (
  select distinct on (owner_id, normalize_for_match(name))
         owner_id, normalize_for_match(name) as norm, id
  from items
  where kind = 'purchased'
  order by owner_id, normalize_for_match(name), created_at, id
),
src_rows as (
  select
    r.owner_id, r.recipe_type, parent.id as parent_id,
    src.elem, src.ord, src.is_flour
  from recipes r
  join items parent on parent.recipe_id = r.id
  cross join lateral (
    select elem, ord, true as is_flour
      from jsonb_array_elements(coalesce(r.flours, '[]'::jsonb)) with ordinality as t(elem, ord)
    union all
    select elem, 1000 + ord, false
      from jsonb_array_elements(coalesce(r.ingredients, '[]'::jsonb)) with ordinality as t(elem, ord)
  ) src
  where coalesce(src.elem->>'name', '') <> ''
)
insert into bom_lines (parent_item_id, child_item_id, display_name, qty, qty_unit, is_flour, stage, sort_order)
select
  s.parent_id,
  coalesce(by_id.id, nl.id),
  '',                                   -- 표시명은 child.name과 같으므로 비워둔다
  case
    when s.recipe_type in ('confection', 'other')
      then coalesce((s.elem->>'weight')::numeric, 0)
    else coalesce((s.elem->>'pct')::numeric, 0)
  end,
  case when s.recipe_type in ('confection', 'other') then 'g' else 'pct' end,
  s.is_flour,
  case when s.elem->>'stage' = 'pre' then 'pre' else 'final' end,
  s.ord::int
from src_rows s
-- 잘못된 uuid 문자열이 들어 있어도 캐스팅에서 터지지 않게 형태를 먼저 확인한다
left join items by_id
  on by_id.legacy_ingredient_id = (
       case when s.elem->>'ingredientId' ~ '^[0-9a-fA-F-]{36}$'
            then (s.elem->>'ingredientId')::uuid end)
left join name_lookup nl
  on nl.owner_id = s.owner_id
 and nl.norm = normalize_for_match(s.elem->>'name')
where coalesce(by_id.id, nl.id) is not null;

-- B-5. products → items(판매 제품) + bom_lines --------------------------------
insert into items (owner_id, name, kind, cost_mode, is_sellable, selling_price, legacy_product_id)
select p.owner_id, p.name, 'made', 'auto', true, p.selling_price, p.id
from products p;

insert into bom_lines (parent_item_id, child_item_id, qty, qty_unit, loss_pct, sort_order)
select pi.id, ri.id, p.portion_weight, 'g', p.loss_rate_pct, 0
from products p
join items pi on pi.legacy_product_id = p.id
join items ri on ri.recipe_id = p.recipe_id;

-- B-6. composite_products → items(판매 제품) + bom_lines ----------------------
insert into items (owner_id, name, kind, cost_mode, is_sellable, selling_price, legacy_composite_id)
select cp.owner_id, cp.name, 'made', 'auto', true, cp.selling_price, cp.id
from composite_products cp;

-- 구성요소는 recipe_id 또는 ingredient_id 중 하나를 가리킨다(스키마상 배타적).
insert into bom_lines (parent_item_id, child_item_id, qty, qty_unit, loss_pct, sort_order)
select
  ci.id,
  coalesce(ri.id, ii.id),
  c.weight_g, 'g', c.loss_rate_pct,
  row_number() over (partition by c.composite_product_id order by c.created_at)
from composite_product_components c
join items ci on ci.legacy_composite_id = c.composite_product_id
left join items ri on ri.recipe_id = c.recipe_id
left join items ii on ii.legacy_ingredient_id = c.ingredient_id
where coalesce(ri.id, ii.id) is not null;   -- 아직 아무것도 안 고른 빈 구성요소는 건너뜀

raise notice 'PART B 이관 완료.';
end
$migrate$;


-- ============================================================================
-- PART C — 검증
--
--   SQL 에디터는 여러 쿼리를 한 번에 실행하면 **마지막 쿼리 결과만** 화면에 보여준다.
--   그래서 제일 중요한 "이관이 잘 됐나?" 확인표(C-3)를 **일부러 맨 뒤에** 뒀다 —
--   파일 전체를 붙여넣고 실행하면 그 표가 화면에 나온다.
--
--   C-1 / C-2는 "그래서 뭘 정리해야 하나"를 보는 목록이다. 나중에 궁금할 때
--   그 쿼리만 마우스로 드래그해서 선택한 뒤 Run 하면 그 결과만 따로 볼 수 있다.
-- ============================================================================

-- C-1. 단가가 비어 있는 품목 목록 — 앱에서 채워 넣어야 할 것들
select name as 품목, category as 분류
from items
where kind = 'purchased' and purchase_amount = 0
order by name;

-- C-2. 이름이 겹치거나 비슷해 중복일 가능성이 있는 품목 (스펙 §10-2 "목록 폭발" 확인용)
--
--   (a) 레시피와 이름이 같은 구매 품목:
--       예를 들어 "묵은반죽"이라는 레시피가 있는데 다른 레시피의 재료 행에도 "묵은반죽"이라고
--       적혀 있으면, made 품목(레시피)과 purchased 품목(자동 생성) 두 개가 같은 이름으로 생긴다.
--       이관은 일부러 **레시피끼리 자동 연결하지 않는다** — 스펙 §3.3에서 하위 배합 중첩을
--       기본에서 뺐기 때문이다. 둘 중 하나로 정리하면 된다:
--         · purchased 쪽에 직접 단가를 넣고 그대로 쓴다 (권장 — 스펙 §3.3의 의도)
--         · purchased 쪽을 지우고 배합 라인을 made 품목으로 옮겨 자동 계산시킨다
--   (b) 한쪽 이름이 다른 쪽에 통째로 들어가 있는 구매 품목 쌍 ("버터" / "무염버터" 등)
select '레시피와 같은 이름' as 유형, p.name as 이름1, m.name as 이름2
from items p
join items m
  on m.owner_id = p.owner_id
 and m.kind = 'made'
 and normalize_for_match(m.name) = normalize_for_match(p.name)
where p.kind = 'purchased'
union all
select '비슷한 이름', a.name, b.name
from items a
join items b
  on a.owner_id = b.owner_id
 and a.kind = 'purchased' and b.kind = 'purchased'
 and a.id < b.id
 and normalize_for_match(a.name) <> normalize_for_match(b.name)
 and (normalize_for_match(a.name) like '%' || normalize_for_match(b.name) || '%'
   or normalize_for_match(b.name) like '%' || normalize_for_match(a.name) || '%')
order by 1, 2;

-- C-3. ★★ 이관 검증 — 파일 전체를 실행하면 이 표가 화면에 나온다.
--      "판정" 열이 전부 OK면 성공. 마지막 줄(새로 만들어진 재료)만 '참고'로 표시된다.
select
  항목, 이관전, 이관후,
  case
    when 이관전 < 0 then '참고'
    when 이관전 = 이관후 then 'OK'
    else '확인 필요'
  end as 판정
from (
  select 1 as 순서, '재료 (ingredients)' as 항목,
         (select count(*) from ingredients) as 이관전,
         (select count(*) from items where legacy_ingredient_id is not null) as 이관후
  union all
  select 2, '레시피 (recipes)',
         (select count(*) from recipes),
         (select count(*) from items where recipe_id is not null)
  union all
  select 3, '제품 (products)',
         (select count(*) from products),
         (select count(*) from items where legacy_product_id is not null)
  union all
  select 4, '조합 제품',
         (select count(*) from composite_products),
         (select count(*) from items where legacy_composite_id is not null)
  union all
  select 5, '배합 라인',
         (select coalesce(sum(jsonb_array_length(coalesce(flours,'[]'::jsonb))
                            + jsonb_array_length(coalesce(ingredients,'[]'::jsonb))), 0) from recipes),
         (select count(*) from bom_lines bl join items i on i.id = bl.parent_item_id where i.recipe_id is not null)
  union all
  -- 비교 대상이 아니라 참고용이다(이관 전에는 없던 것). 레시피에 이름만 있고 재료 연결이
  -- 없던 행들에서 새로 만들어진 품목 개수 = 앱에서 단가를 채워야 할 개수(C-1 목록의 길이).
  select 6, '새로 만들어진 재료 (단가 입력 필요)',
         -1,
         (select count(*) from items
           where legacy_ingredient_id is null and recipe_id is null
             and legacy_product_id is null and legacy_composite_id is null)
) t
order by 순서;


-- ============================================================================
-- PART D — 롤백 (문제가 있을 때만 실행)
--   새 테이블만 지운다. 기존 데이터는 애초에 건드리지 않았으므로 원래 상태로 완전히 복구된다.
-- ============================================================================
-- drop trigger if exists bom_lines_no_cycle on bom_lines;
-- drop function if exists check_bom_cycle();
-- drop table if exists item_price_history;
-- drop table if exists bom_lines;
-- drop table if exists items;
-- drop function if exists normalize_for_match(text);
