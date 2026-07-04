-- ============================================================
-- 설치업체를 "링고벨", "씨스콜CNS" 단 2곳으로 확정하고,
-- 마스터가 웹 화면에서 사업장별로 설치업체를 직접 선택/변경할 수 있게 한다.
--
-- 주의: 기존에 임시로 만들어둔 업체(업체1~4 등)와 그 사업장 배정은 전부 지워집니다.
-- 실행 후 59개 사업장은 전부 "미배정" 상태가 되고, 마스터 화면에서 사업장을
-- 하나씩 열어 설치업체를 선택해서 저장하면 됩니다.
--
-- Supabase SQL Editor 에서 이 파일 전체를 한 번만 실행하세요.
-- ============================================================

-- 1) 기존 배정 초기화 후 업체 교체
update sites set contractor_id = null;
delete from contractors;
insert into contractors (name) values ('링고벨'), ('씨스콜CNS');

-- 2) 설치업체 배정/변경은 마스터만 가능 (RPC)
create or replace function assign_contractor(p_token text, p_site_id bigint, p_contractor_id bigint)
returns void language plpgsql security definer as $$
begin
  if not exists (select 1 from app_admins where access_token = p_token) then
    raise exception '설치업체 배정은 마스터만 변경할 수 있습니다';
  end if;
  update sites set
    contractor_id = p_contractor_id,
    updated_by = who_is(p_token),
    updated_at = now()
  where id = p_site_id;
end; $$;

-- 3) 발급된 업체 토큰 확인 (이 값으로 업체별 링크를 만든다)
select id, name, access_token from contractors order by id;
