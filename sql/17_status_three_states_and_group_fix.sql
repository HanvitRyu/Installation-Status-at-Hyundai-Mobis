-- ============================================================
-- 기존 사업장 데이터는 전혀 건드리지 않는다 (컬럼/제약조건/함수만 변경).
--
-- 1) 버그 수정: 설치업체를 "미배정"으로 되돌려 저장해도 이전 설치업체가
--    그대로 남아있던 문제. assign_group()은 "설치업체가 아직 정해지지 않은
--    상태"에서만 호출되므로, 호출되면 installer_id를 항상 null로 확실히
--    비워야 하는데, 이전 로직은 "새 담당업체가 기존 설치업체와 같은 그룹이면
--    설치업체를 그대로 둔다"는 조건이 있어서 이 경우에 설치업체가 안 지워졌다.
--
-- 2) 진행여부를 미착수/완료 2단계에서 미착수/설치예정/완료 3단계로 확장.
--    기존에 저장된 '미착수', '완료' 값은 그대로 유효하므로 데이터 영향 없음.
--
-- Supabase SQL Editor 에서 이 파일 전체를 한 번만 실행하세요.
-- ============================================================

create or replace function assign_group(p_token text, p_site_id bigint, p_group_id bigint)
returns void language plpgsql security definer as $$
begin
  if not exists (select 1 from app_admins where access_token = p_token) then
    raise exception '담당업체 배정은 마스터만 변경할 수 있습니다';
  end if;
  update sites set
    group_id = p_group_id,
    installer_id = null,
    updated_by = who_is(p_token),
    updated_at = now()
  where id = p_site_id;
end; $$;

alter table sites drop constraint sites_status_check;
alter table sites add constraint sites_status_check check (status in ('미착수','설치예정','완료'));
