-- ============================================================
-- 설치업체를 6곳(placeholder) → 4곳(실제 업체명)으로 정리한다.
--   링고벨 소속: 링고벨, 벨플러스
--   씨스콜CNS 소속: 씨스콜CNS, 벨샵
-- 남는 설치업체3 / 설치업체6 은 삭제한다 (현재 배정된 사업장이 없어야 안전하게 삭제됨).
--
-- Supabase SQL Editor 에서 이 파일 전체를 한 번만 실행하세요.
-- ============================================================

update installers set name = '링고벨' where name = '설치업체1';
update installers set name = '벨플러스' where name = '설치업체2';
update installers set name = '씨스콜CNS' where name = '설치업체4';
update installers set name = '벨샵' where name = '설치업체5';

delete from installers where name = '설치업체3';
delete from installers where name = '설치업체6';

-- 확인용
select i.id, i.name, g.name as group_name
from installers i join contractors g on g.id = i.group_id
order by g.name, i.name;
