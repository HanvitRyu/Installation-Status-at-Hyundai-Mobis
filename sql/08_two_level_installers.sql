-- ============================================================
-- 2단계 구조로 전환:
--   담당업체(총괄, contractors 테이블) 2곳 — 링고벨/씨스콜CNS
--     └ 설치업체(installers 테이블, 신규) 6곳 — A~F 성격의 실제 시공 업체
--
-- - 사업장(sites)은 이제 "설치업체" 하나에 배정된다 (installer_id).
--   담당업체(총괄)는 그 설치업체가 어느 그룹 소속인지로 자동 결정된다.
-- - 마스터: 전체 조회/수정 + 사업장별 설치업체 배정(변경).
-- - 담당업체(총괄) 토큰: 자기 소속 설치업체들이 담당한 사업장을 전부 조회 "및 수정"
--   가능 (설치업체 배정 변경은 불가 — 그건 마스터만).
-- - 설치업체 토큰: 자기가 배정받은 사업장만 조회/수정 가능.
--
-- 주의: sites.contractor_id(그룹 직접 참조) 컬럼은 없애고 installer_id로 대체합니다.
-- 기존에 07번 스크립트로 배정해둔 값이 있었다면(그룹 단위 배정) 그대로 옮길 수 없어
-- 전부 "미배정" 상태로 초기화됩니다. 마스터가 사업장별로 설치업체(A~F)를 다시
-- 지정해줘야 합니다.
--
-- Supabase SQL Editor 에서 이 파일 전체를 한 번만 실행하세요.
-- ============================================================

-- ------------------------------------------------------------
-- 1) 설치업체 테이블
-- ------------------------------------------------------------
create table installers (
  id            bigint generated always as identity primary key,
  name          text not null,
  group_id      bigint references contractors(id) not null,
  access_token  text unique not null default gen_random_uuid()::text,
  created_at    timestamptz default now()
);

alter table installers enable row level security;
-- 정책 없음 → anon 직접 접근 전면 차단 (RPC로만 접근)

-- 설치업체 placeholder 6곳 생성 (링고벨/씨스콜CNS 각 3곳). 실제 업체명 받으면 UPDATE로 교체.
insert into installers (name, group_id)
values
  ('설치업체1', (select id from contractors where name = '링고벨')),
  ('설치업체2', (select id from contractors where name = '링고벨')),
  ('설치업체3', (select id from contractors where name = '링고벨')),
  ('설치업체4', (select id from contractors where name = '씨스콜CNS')),
  ('설치업체5', (select id from contractors where name = '씨스콜CNS')),
  ('설치업체6', (select id from contractors where name = '씨스콜CNS'));

-- ------------------------------------------------------------
-- 2) sites: contractor_id(그룹 직접 참조) → installer_id 로 교체
-- ------------------------------------------------------------
alter table sites add column installer_id bigint references installers(id);
alter table sites drop column contractor_id;

-- ------------------------------------------------------------
-- 3) 권한/조회 함수 전체 교체
-- ------------------------------------------------------------

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
    );
$$;

create or replace function who_is(p_token text)
returns text language sql stable as $$
  select coalesce(
    (select name from installers where access_token = p_token),
    (select name || '(총괄)' from contractors where access_token = p_token),
    (select '[관리자] ' || name from app_admins where access_token = p_token)
  );
$$;

-- 토큰으로 "나는 누구인가" 판별: 마스터 / 담당업체(총괄) / 설치업체 중 하나.
-- access_token 자체는 절대 반환하지 않는다.
-- (반환 컬럼 구성이 바뀌어서 CREATE OR REPLACE가 안 되므로 먼저 DROP)
drop function if exists identify(text);
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

-- 설치업체 목록 (마스터: 전체, 담당업체 토큰: 자기 소속만, 설치업체 토큰: 자기 자신만)
drop function if exists list_contractors(text);
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

create or replace function get_sites(p_token text)
returns setof sites
language sql stable security definer as $$
  select s.* from sites s
  left join installers i on i.id = s.installer_id
  where
    exists (select 1 from app_admins where access_token = p_token)
    or i.access_token = p_token
    or i.group_id = (select id from contractors where access_token = p_token);
$$;

create or replace function get_installations(p_token text)
returns setof installations
language sql stable security definer as $$
  select ins.* from installations ins
  join sites s on s.id = ins.site_id
  left join installers i on i.id = s.installer_id
  where
    exists (select 1 from app_admins where access_token = p_token)
    or i.access_token = p_token
    or i.group_id = (select id from contractors where access_token = p_token);
$$;

create or replace function get_installation_units(p_token text)
returns setof installation_units
language sql stable security definer as $$
  select u.* from installation_units u
  join sites s on s.id = u.site_id
  left join installers i on i.id = s.installer_id
  where
    exists (select 1 from app_admins where access_token = p_token)
    or i.access_token = p_token
    or i.group_id = (select id from contractors where access_token = p_token);
$$;

-- 설치업체 배정/변경 (마스터 전용)
drop function if exists assign_contractor(text, bigint, bigint);
create or replace function assign_installer(p_token text, p_site_id bigint, p_installer_id bigint)
returns void language plpgsql security definer as $$
begin
  if not exists (select 1 from app_admins where access_token = p_token) then
    raise exception '설치업체 배정은 마스터만 변경할 수 있습니다';
  end if;
  update sites set
    installer_id = p_installer_id,
    updated_by = who_is(p_token),
    updated_at = now()
  where id = p_site_id;
end; $$;

-- 4) 발급된 설치업체 토큰 확인 (이 값으로 설치업체별 링크를 만든다)
select i.id, i.name, g.name as group_name, i.access_token
from installers i join contractors g on g.id = i.group_id
order by i.id;

-- 참고: 담당업체(총괄, 링고벨/씨스콜CNS) 토큰은 이미 07번 스크립트 실행 결과에서 확인한
-- contractors.access_token 그대로 씁니다 (이 스크립트에서는 바뀌지 않음).
