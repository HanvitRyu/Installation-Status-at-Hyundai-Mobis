-- '응준씨업체'(임시 상호명으로 미리 만들어둔 설치업체)를 '예스아이엔티'로 정식 개명.
-- installers.name 컬럼 값만 바꾸며, id/access_token/group_id/배정된 사업장 등은 전혀 건드리지 않는다.
update installers
set name = '예스아이엔티'
where name = '응준씨업체';

-- 변경 확인용 (읽기 전용)
select id, name, group_id, access_token
from installers
where name = '예스아이엔티';
