-- 링고벨 담당업체 밑에 설치업체 1곳을 추가로 만들어둔다 (상호명 미정, 임시로 '응준씨업체').
-- 기존 행은 전혀 건드리지 않는 순수 INSERT. 새로 생기는 이 설치업체는 어느 사업장에도
-- 자동 배정되지 않으며, 나중에 화면에서 직접 사업장에 배정하면 된다.
insert into installers (name, group_id)
values ('응준씨업체', (select id from contractors where name = '링고벨'));

-- 생성 확인 + 발급된 access_token 확인용 (읽기 전용)
select id, name, group_id, access_token
from installers
where name = '응준씨업체';
