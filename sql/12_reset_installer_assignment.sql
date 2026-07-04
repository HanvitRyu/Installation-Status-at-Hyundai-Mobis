-- ============================================================
-- 설치업체 선정이 아직 진행 중이라, 11번 스크립트로 임시 배정했던 내용을
-- 되돌리고 59개 사업장을 전부 미배정 상태로 되돌린다.
--
-- Supabase SQL Editor 에서 이 파일 전체를 한 번만 실행하세요.
-- ============================================================

update sites set installer_id = null;

-- 확인용 (전부 installer_name/group_name 이 비어있어야 정상)
select s.id, s.name, i.name as installer_name, g.name as group_name
from sites s
left join installers i on i.id = s.installer_id
left join contractors g on g.id = i.group_id
order by s.id;
