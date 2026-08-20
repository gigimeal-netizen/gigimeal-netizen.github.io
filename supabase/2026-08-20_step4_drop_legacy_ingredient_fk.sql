-- BOM 4단계 (2026-08-20) — 재료의 출처를 ingredients → items 로 옮긴 뒤 필요한 한 줄.
--
-- 왜 필요한가:
--   composite_product_components.ingredient_id 가 구 ingredients(id) 를 참조하는
--   외래 키를 갖고 있다. 이제 앱은 items 를 재료 목록으로 쓰므로, 마이그레이션 이후
--   새로 만든 품목(구 ingredients 에 대응 행이 없다)을 조합 제품의 구성요소로 고르면
--   외래 키 위반으로 저장이 실패한다.
--
--   조합 제품 자체가 6단계에서 items/bom_lines 로 흡수되어 사라질 예정이라, 여기서는
--   제약만 떼어내고 컬럼은 그대로 둔다(기존 3건의 데이터는 손대지 않는다).
--
-- 실행 방법: Supabase 대시보드 → SQL Editor 에 붙여넣고 Run.
--            여러 번 실행해도 안전하다(이미 없으면 그냥 넘어간다).

alter table composite_product_components
  drop constraint if exists composite_product_components_ingredient_id_fkey;

-- 확인 — 아래가 0 이면 정상적으로 제거된 것이다.
select count(*) as remaining_fk
from pg_constraint
where conrelid = 'composite_product_components'::regclass
  and conname = 'composite_product_components_ingredient_id_fkey';
