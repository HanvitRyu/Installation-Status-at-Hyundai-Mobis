-- ============================================================
-- "담당업체(총괄)는 정해졌지만 설치업체(A~F)는 아직 미정"인 상태를 표현하기 위해
-- sites 에 group_id 를 별도로 둔다 (installer_id 와 독립적).
--
-- - installer_id 가 있으면: 그 설치업체가 소속된 담당업체가 실제 담당업체.
-- - installer_id 가 없으면: sites.group_id 가 (있다면) 잠정 담당업체.
-- - 설치업체를 배정하면 group_id 는 그 설치업체의 소속으로 자동 동기화된다.
-- - 담당업체를 바꾸면, 이미 배정된 설치업체가 다른 소속이었을 경우 설치업체
--   배정은 자동으로 해제된다 (담당업체 불일치 방지).
--
-- Supabase SQL Editor 에서 이 파일 전체를 한 번만 실행하세요.
-- ============================================================

alter table sites add column group_id bigint references contractors(id);

-- ------------------------------------------------------------
-- 권한/조회 함수: site.group_id 도 함께 고려하도록 갱신
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
    )
    or exists (
      select 1 from sites s
      join contractors g on g.id = s.group_id
      where s.id = p_site_id and g.access_token = p_token
    );
$$;

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

-- 설치업체 배정: 배정 시 group_id 를 그 설치업체 소속으로 자동 동기화.
-- 설치업체를 미배정(null)으로 되돌릴 땐 group_id 는 그대로 둔다 (담당업체 정보 보존).
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

-- ------------------------------------------------------------
-- 데이터 반영: "☆현대모비스 전사 비상벨 설치현황 및 설치 계획.xlsx" J열 기준
-- (링고벨 28개소 / 씨스콜CNS 31개소) — 설치업체(installer_id)는 그대로 미배정 유지.
-- ------------------------------------------------------------

update sites set group_id = (select id from contractors where name = '링고벨')
where id in (2,3,4,5,6,11,12,13,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,49,54,55,56,59);

update sites set group_id = (select id from contractors where name = '씨스콜CNS')
where id in (1,7,8,9,10,14,15,16,17,18,19,20,21,22,38,39,40,41,42,43,44,45,46,47,48,50,51,52,53,57,58);

-- 확인용 (installer_name 은 전부 비어있고 group_name 만 채워져 있어야 정상)
select s.id, s.name, i.name as installer_name, g.name as group_name
from sites s
left join installers i on i.id = s.installer_id
left join contractors g on g.id = s.group_id
order by s.id;
