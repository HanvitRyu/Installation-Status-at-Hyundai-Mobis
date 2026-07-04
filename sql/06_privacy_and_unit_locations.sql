-- ============================================================
-- 증분 스크립트: 아래 2가지를 반영한다.
--
-- 1) 리피터(B)·모뎀(C) 품목의 "설치위치"를 품목당 1칸이 아니라
--    실제수량만큼 반복 입력하도록 변경 (기존 installations.location 폐기,
--    installation_units 테이블을 B/C 공용으로 확장해서 위치도 여기 저장).
--
-- 2) 조회(SELECT) 권한을 "전체 공개"에서 "토큰 기반"으로 전환.
--    - 토큰이 없거나 잘못되면 사업장이 하나도 안 보임.
--    - 업체 토큰은 자기 담당 사업장만 보임 (다른 업체 현황 조회 불가).
--    - 마스터 토큰은 전체 조회.
--    지금까지는 sites/installations/installation_units 에 "누구나 조회 가능"
--    정책이 걸려 있어서, anon key만 있으면 앱을 거치지 않고도 전체 데이터를
--    직접 조회할 수 있는 상태였다. 이 정책들을 지우고, 대신 토큰을 검증하는
--    RPC 함수(get_sites/get_installations/get_installation_units)로만 조회하게 한다.
--
-- Supabase SQL Editor 에서 이 파일 전체를 한 번만 실행하세요.
-- (01_schema.sql 은 새 프로젝트를 위해 이 내용을 이미 포함하도록 갱신해뒀습니다.)
-- ============================================================

-- ------------------------------------------------------------
-- 1) installation_units: B/C 공용으로 확장 + location 컬럼 추가
-- ------------------------------------------------------------
alter table installation_units add column location text;
alter table installation_units drop constraint installation_units_product_check;
alter table installation_units add constraint installation_units_product_check check (product in ('B','C'));

-- installations.location 은 이제 사용하지 않음 (품목당 1칸 → 수량별 여러 칸으로 대체됨)
alter table installations drop column location;

-- ------------------------------------------------------------
-- 2) 조회 정책을 토큰 기반으로 전환
-- ------------------------------------------------------------
drop policy if exists "sites_read_all" on sites;
drop policy if exists "inst_read_all" on installations;
drop policy if exists "inst_units_read_all" on installation_units;
-- 정책을 하나도 남기지 않음 → anon 직접 SELECT 전면 차단.
-- 이제부터는 아래 RPC 함수를 통해서만 조회 가능.

create or replace function get_sites(p_token text)
returns setof sites
language sql stable security definer as $$
  select s.* from sites s
  where
    exists (select 1 from app_admins where access_token = p_token)
    or exists (
      select 1 from contractors c
      where c.access_token = p_token and c.id = s.contractor_id
    );
$$;

create or replace function get_installations(p_token text)
returns setof installations
language sql stable security definer as $$
  select i.* from installations i
  join sites s on s.id = i.site_id
  where
    exists (select 1 from app_admins where access_token = p_token)
    or exists (
      select 1 from contractors c
      where c.access_token = p_token and c.id = s.contractor_id
    );
$$;

create or replace function get_installation_units(p_token text)
returns setof installation_units
language sql stable security definer as $$
  select u.* from installation_units u
  join sites s on s.id = u.site_id
  where
    exists (select 1 from app_admins where access_token = p_token)
    or exists (
      select 1 from contractors c
      where c.access_token = p_token and c.id = s.contractor_id
    );
$$;

-- list_contractors 도 토큰 기반으로 변경: 마스터는 전체, 업체는 자기 자신만.
drop function if exists list_contractors();
create or replace function list_contractors(p_token text)
returns table(id bigint, name text)
language sql stable security definer as $$
  select c.id, c.name from contractors c
  where
    exists (select 1 from app_admins where access_token = p_token)
    or c.access_token = p_token;
$$;

-- ------------------------------------------------------------
-- 3) save_installation: p_location 파라미터 제거 (더 이상 installations에 위치 저장 안 함)
-- ------------------------------------------------------------
drop function if exists save_installation(text, bigint, text, integer, text);
create or replace function save_installation(
  p_token text, p_site_id bigint, p_product text, p_actual_qty integer
) returns void language plpgsql security definer as $$
begin
  if not can_edit_site(p_token, p_site_id) then
    raise exception '이 사업장을 수정할 권한이 없습니다';
  end if;
  update installations set actual_qty = p_actual_qty
  where site_id = p_site_id and product = p_product;
end; $$;

-- ------------------------------------------------------------
-- 4) save_installation_units: B/C 공용 + location 포함해서 저장
-- ------------------------------------------------------------
create or replace function save_installation_units(
  p_token text, p_site_id bigint, p_product text, p_units jsonb
) returns void language plpgsql security definer as $$
begin
  if not can_edit_site(p_token, p_site_id) then
    raise exception '이 사업장을 수정할 권한이 없습니다';
  end if;
  if p_product not in ('B','C') then
    raise exception '수량별 상세 정보는 리피터(B)·모뎀(C) 품목에만 입력할 수 있습니다';
  end if;

  delete from installation_units where site_id = p_site_id and product = p_product;

  insert into installation_units (site_id, product, unit_no, location, ip, gateway, subnet_mask, host_ip)
  select
    p_site_id, p_product,
    (u->>'unit_no')::int,
    u->>'location', u->>'ip', u->>'gateway', u->>'subnet_mask', u->>'host_ip'
  from jsonb_array_elements(p_units) as u;
end; $$;
