-- 계약이 성사되지 않아 설치업체 '벨샵'(씨스콜CNS 소속)을 삭제한다.
-- 사전 확인: 벨샵에 배정된 사업장 없음 (installer_id로 참조하는 sites 행 없음).
-- 혹시라도 배정된 사업장이 남아있으면 sites.installer_id -> installers FK 제약 때문에
-- 아래 delete가 그냥 에러로 막힌다 (다른 데이터를 건드리지 않고 안전하게 실패).

delete from installers where name = '벨샵';

-- 삭제 확인용 (읽기 전용) — 결과가 0행이면 정상 삭제된 것
select id, name from installers where name = '벨샵';
