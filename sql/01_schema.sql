-- ============================================================
-- 현대모비스 설치현황 관리 페이지 — 스키마 (테이블 / RLS / RPC)
-- Supabase SQL Editor 에 이 파일 전체를 그대로 붙여넣고 실행하세요.
-- (새 프로젝트용 최종본입니다. 이미 이전 버전을 실행해둔 프로젝트는
--  sql/08_two_level_installers.sql 같은 증분 스크립트를 대신 사용하세요.)
--
-- 권한 구조는 2단계입니다.
--   담당업체(총괄, contractors 테이블) — 링고벨/씨스콜CNS 같은 총괄 2곳
--     └ 설치업체(installers 테이블) — 실제 시공하는 6곳, 총괄업체 소속
--   사업장(sites)은 설치업체 하나에 배정되고, 담당업체(총괄)는 그 설치업체의
--   소속 그룹으로 자동 결정됩니다.
-- ============================================================

-- ------------------------------------------------------------
-- 1. 테이블
-- ------------------------------------------------------------

-- 담당업체(총괄)
create table contractors (
  id            bigint generated always as identity primary key,
  name          text not null,
  access_token  text unique not null default gen_random_uuid()::text,
  created_at    timestamptz default now()
);

-- 설치업체 (담당업체 소속, 실제 시공)
create table installers (
  id            bigint generated always as identity primary key,
  name          text not null,
  group_id      bigint references contractors(id) not null,
  access_token  text unique not null default gen_random_uuid()::text,
  created_at    timestamptz default now()
);

create table app_admins (
  id            bigint generated always as identity primary key,
  name          text not null,
  access_token  text unique not null default gen_random_uuid()::text,
  created_at    timestamptz default now()
);

create table sites (
  id             bigint generated always as identity primary key,
  name           text not null,
  installer_id   bigint references installers(id),
  -- 담당업체(총괄)만 정해지고 설치업체는 아직 미정인 상태를 표현하기 위한 컬럼.
  -- installer_id 가 있으면 그 설치업체의 소속이 실제 담당업체이고, 없으면 이 값이 잠정 담당업체.
  group_id       bigint references contractors(id),

  status         text default '미착수'
                   check (status in ('미착수','완료')),
  install_date   date,
  manager_name   text,
  note           text,

  -- 참고용 표시 정보 (화면에서 직접 수정하지 않음, SQL로만 갱신)
  address              text,  -- 사업장 주소
  site_contact_name    text,  -- 현장 담당자명
  site_contact_phone   text,  -- 현장 담당자 전화번호
  site_contact_email   text,  -- 현장 담당자 이메일
  monitor_location     text,  -- 모니터링 프로그램 설치 장소
  monitor_pc_ip        text,  -- 모니터링 프로그램 설치 PC IP

  updated_by     text,
  updated_at     timestamptz default now(),
  created_at     timestamptz default now()
);

create table installations (
  id           bigint generated always as identity primary key,
  site_id      bigint references sites(id) not null,
  product      text not null check (product in ('A','B','C')),
  planned_qty  integer not null default 0,
  actual_qty   integer,
  unique (site_id, product)
);

-- 품목 B(리피터, GX-8200)·C(모뎀, GX-8200 TCP/IP) 전용:
-- 설치 대수(실제수량)만큼 반복되는 상세 정보. B는 location만 쓰고,
-- C는 location + ip/mac_address/gateway/subnet_mask/host_ip 를 모두 쓴다.
-- (A=비상벨/GST-502 는 이 테이블을 쓰지 않음 — 위치가 고정이라 입력란 자체가 없음)
create table installation_units (
  id           bigint generated always as identity primary key,
  site_id      bigint references sites(id) not null,
  product      text not null check (product in ('B','C')),
  unit_no      integer not null,
  location     text,
  ip           text,
  mac_address  text,
  gateway      text,
  subnet_mask  text,
  host_ip      text,
  unique (site_id, product, unit_no)
);

-- ------------------------------------------------------------
-- 2. RLS (Row Level Security)
-- ------------------------------------------------------------
-- 전부 anon 에게 직접 SELECT/UPDATE 권한을 주지 않는다 (정책을 만들지 않음
-- = 전체 차단). 대신 아래 RPC 함수(SECURITY DEFINER)를 통해서만 접근한다.
--
-- ※ 명세서 4장 원안은 sites/installations 를 "조회는 전체 공개"로 뒀지만,
--   그러면 앱을 거치지 않고 anon key로 직접 REST 호출해서 다른 업체의
--   현황까지 다 볼 수 있게 된다. "업체끼리 서로의 현황을 모르게 해달라"는
--   요청에 따라, 조회도 토큰을 검증하는 get_sites()/get_installations()/
--   get_installation_units() RPC를 통해서만 가능하도록 바꿨다.
--   (토큰이 없거나 잘못되면 아무 사업장도 보이지 않는다.)

alter table sites enable row level security;
alter table installations enable row level security;
alter table installation_units enable row level security;
alter table contractors enable row level security;
alter table installers enable row level security;
alter table app_admins enable row level security;
-- 여섯 테이블 모두 정책 없음 → anon 직접 접근 전면 차단 (RPC로만 접근)

-- ------------------------------------------------------------
-- 3. RPC 함수
-- ------------------------------------------------------------

-- 토큰이 해당 사업장을 수정할 권한이 있는지 판정.
-- 마스터 / 그 사업장을 배정받은 설치업체 / 그 설치업체가 소속된 담당업체(총괄) 모두 가능.
create or replace function can_edit_site(p_token text, p_site_id bigint)
returns boolean language sql stable as $$
  select
    exists (select 1 from app_admins where access_token = p_token)
    or exists (
      select 1 from sites s
      join installers i on i.id = s.installer_id
      where s.id = p_site_id and i.access_token = p_token
    )
    or exists (
      select 1 from sites s
      join installers i on i.id = s.installer_id
      join contractors g on g.id = i.group_id
      where s.id = p_site_id and g.access_token = p_token
    )
    or exists (
      select 1 from sites s
      join contractors g on g.id = s.group_id
      where s.id = p_site_id and g.access_token = p_token
    );
$$;

-- 수정자 이름 조회
create or replace function who_is(p_token text)
returns text language sql stable as $$
  select coalesce(
    (select name from installers where access_token = p_token),
    (select name || '(총괄)' from contractors where access_token = p_token),
    (select '[관리자] ' || name from app_admins where access_token = p_token)
  );
$$;

-- 토큰으로 "나는 누구인가"를 판별: 마스터 / 담당업체(총괄) / 설치업체 중 하나.
-- access_token 자체는 절대 반환하지 않는다.
create or replace function identify(p_token text)
returns table(
  is_admin boolean,
  installer_id bigint, installer_name text,
  group_id bigint, group_name text
)
language sql stable security definer as $$
  select
    exists(select 1 from app_admins where access_token = p_token) as is_admin,
    (select i.id from installers i where i.access_token = p_token) as installer_id,
    (select i.name from installers i where i.access_token = p_token) as installer_name,
    coalesce(
      (select i.group_id from installers i where i.access_token = p_token),
      (select g.id from contractors g where g.access_token = p_token)
    ) as group_id,
    coalesce(
      (select g.name from installers i join contractors g on g.id = i.group_id where i.access_token = p_token),
      (select g.name from contractors g where g.access_token = p_token)
    ) as group_name;
$$;

-- 설치업체 목록. 마스터: 전체, 담당업체(총괄) 토큰: 자기 소속만, 설치업체 토큰: 자기 자신만.
create or replace function list_installers(p_token text)
returns table(id bigint, name text, group_id bigint, group_name text)
language sql stable security definer as $$
  select i.id, i.name, i.group_id, g.name as group_name
  from installers i
  join contractors g on g.id = i.group_id
  where
    exists (select 1 from app_admins where access_token = p_token)
    or i.access_token = p_token
    or g.access_token = p_token
  order by i.id;
$$;

-- 토큰이 볼 수 있는 사업장만 반환 (마스터: 전체, 담당업체: 소속 설치업체 몫 전부,
-- 설치업체: 자기 담당만, 그 외: 없음)
create or replace function get_sites(p_token text)
returns setof sites
language sql stable security definer as $$
  select s.* from sites s
  left join installers i on i.id = s.installer_id
  where
    exists (select 1 from app_admins where access_token = p_token)
    or i.access_token = p_token
    or i.group_id = (select id from contractors where access_token = p_token)
    or s.group_id = (select id from contractors where access_token = p_token);
$$;

-- 토큰이 볼 수 있는 사업장의 installations 행만 반환
create or replace function get_installations(p_token text)
returns setof installations
language sql stable security definer as $$
  select ins.* from installations ins
  join sites s on s.id = ins.site_id
  left join installers i on i.id = s.installer_id
  where
    exists (select 1 from app_admins where access_token = p_token)
    or i.access_token = p_token
    or i.group_id = (select id from contractors where access_token = p_token)
    or s.group_id = (select id from contractors where access_token = p_token);
$$;

-- 토큰이 볼 수 있는 사업장의 installation_units 행만 반환
create or replace function get_installation_units(p_token text)
returns setof installation_units
language sql stable security definer as $$
  select u.* from installation_units u
  join sites s on s.id = u.site_id
  left join installers i on i.id = s.installer_id
  where
    exists (select 1 from app_admins where access_token = p_token)
    or i.access_token = p_token
    or i.group_id = (select id from contractors where access_token = p_token)
    or s.group_id = (select id from contractors where access_token = p_token);
$$;

-- 설치업체 배정/변경 (마스터 전용). 배정 시 group_id 를 그 설치업체 소속으로 자동 동기화하고,
-- 미배정(null)으로 되돌릴 땐 group_id 는 그대로 둔다 (담당업체 정보 보존).
create or replace function assign_installer(p_token text, p_site_id bigint, p_installer_id bigint)
returns void language plpgsql security definer as $$
begin
  if not exists (select 1 from app_admins where access_token = p_token) then
    raise exception '설치업체 배정은 마스터만 변경할 수 있습니다';
  end if;
  update sites set
    installer_id = p_installer_id,
    group_id = case
      when p_installer_id is not null then (select group_id from installers where id = p_installer_id)
      else group_id
    end,
    updated_by = who_is(p_token),
    updated_at = now()
  where id = p_site_id;
end; $$;

-- 담당업체(총괄)만 배정 (설치업체 미정 상태에서 사용). 마스터 전용.
-- 이미 배정된 설치업체가 다른 담당업체 소속이면 설치업체 배정은 자동 해제된다.
create or replace function assign_group(p_token text, p_site_id bigint, p_group_id bigint)
returns void language plpgsql security definer as $$
begin
  if not exists (select 1 from app_admins where access_token = p_token) then
    raise exception '담당업체 배정은 마스터만 변경할 수 있습니다';
  end if;
  update sites set
    group_id = p_group_id,
    installer_id = case
      when p_group_id is null then null
      when installer_id is not null
        and (select group_id from installers where id = sites.installer_id) is distinct from p_group_id
      then null
      else installer_id
    end,
    updated_by = who_is(p_token),
    updated_at = now()
  where id = p_site_id;
end; $$;

-- 사업장 단위 항목 저장
create or replace function save_site(
  p_token text, p_site_id bigint,
  p_status text, p_install_date date, p_manager_name text, p_note text
) returns void language plpgsql security definer as $$
begin
  if not can_edit_site(p_token, p_site_id) then
    raise exception '이 사업장을 수정할 권한이 없습니다';
  end if;
  update sites set
    status = p_status, install_date = p_install_date,
    manager_name = p_manager_name, note = p_note,
    updated_by = who_is(p_token), updated_at = now()
  where id = p_site_id;
end; $$;

-- 품목별 실제수량 저장 (설치위치/네트워크 정보는 save_installation_units 로 별도 저장)
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

-- 품목 B(리피터)·C(모뎀) 전용: 대수별 설치위치(+ C는 네트워크 정보) 저장.
-- p_units 예: '[{"unit_no":1,"location":"...","ip":"...","mac_address":"...","gateway":"...","subnet_mask":"...","host_ip":"..."}, ...]'
-- (B는 location만 채우고 나머지는 null로 보내면 됨)
-- 매번 해당 사업장·품목의 기존 행을 지우고 통째로 다시 넣는다 (실제수량이 줄어도 정합성 유지).
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

  insert into installation_units (site_id, product, unit_no, location, ip, mac_address, gateway, subnet_mask, host_ip)
  select
    p_site_id, p_product,
    (u->>'unit_no')::int,
    u->>'location', u->>'ip', u->>'mac_address', u->>'gateway', u->>'subnet_mask', u->>'host_ip'
  from jsonb_array_elements(p_units) as u;
end; $$;
