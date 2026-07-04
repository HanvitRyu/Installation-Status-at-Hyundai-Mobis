-- ============================================================
-- "☆현대모비스 전사 비상벨 설치현황 및 설치 계획.xlsx" 의 J열 기준으로
-- 59개 사업장을 담당업체(총괄) 단위로 배정한다.
--   J열에 '링고벨'이 적혀있으면 링고벨 담당, 빈칸이면 씨스콜CNS 담당.
--   (링고벨 28개소 / 씨스콜CNS 31개소)
--
-- 주의: 아직 "설치업체"(A~F, 실무 6곳) 단위의 세부 배정표는 없으므로,
-- 일단 각 담당업체 소속의 대표 placeholder 설치업체 1곳에 전부 몰아서
-- 배정해둔다 (링고벨 소속은 '설치업체1', 씨스콜CNS 소속은 '설치업체4').
-- 나중에 6개 설치업체별 세부 배정표를 받으면, 마스터 화면에서 사업장별로
-- '설치업체' 드롭다운만 바꿔주면 된다 (이 SQL을 다시 실행할 필요 없음).
--
-- Supabase SQL Editor 에서 이 파일 전체를 한 번만 실행하세요.
-- ============================================================

update sites set installer_id = (select id from installers where name = '설치업체1')
where id in (2,3,4,5,6,11,12,13,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,49,54,55,56,59);

update sites set installer_id = (select id from installers where name = '설치업체4')
where id in (1,7,8,9,10,14,15,16,17,18,19,20,21,22,38,39,40,41,42,43,44,45,46,47,48,50,51,52,53,57,58);

-- 확인용
select s.id, s.name, i.name as installer_name, g.name as group_name
from sites s
left join installers i on i.id = s.installer_id
left join contractors g on g.id = i.group_id
order by s.id;
