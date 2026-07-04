-- ============================================================
-- 초기 시드 데이터 (placeholder)
-- 실제 59개 사업장 목록(CSV)을 받기 전까지 임시로 사용.
-- 01_schema.sql 실행 후 이 파일을 실행하세요.
-- ============================================================

-- 59개 사업장 생성
insert into sites (name)
select n || '번 사업장' from generate_series(1,59) as n;

-- 각 사업장에 A/B/C 품목 행 생성 (예정수량 0으로 초기화)
insert into installations (site_id, product, planned_qty)
select s.id, p.product, 0
from sites s
cross join (values ('A'),('B'),('C')) as p(product);

-- 마스터 관리자 1명 생성 (토큰 자동 발급)
insert into app_admins (name) values ('마스터');

-- 담당업체(총괄) 2곳
insert into contractors (name) values ('링고벨'), ('씨스콜CNS');

-- 설치업체 placeholder 6곳 (담당업체 소속). 실제 업체명 받으면 UPDATE로 교체.
insert into installers (name, group_id)
values
  ('설치업체1', (select id from contractors where name = '링고벨')),
  ('설치업체2', (select id from contractors where name = '링고벨')),
  ('설치업체3', (select id from contractors where name = '링고벨')),
  ('설치업체4', (select id from contractors where name = '씨스콜CNS')),
  ('설치업체5', (select id from contractors where name = '씨스콜CNS')),
  ('설치업체6', (select id from contractors where name = '씨스콜CNS'));

-- 사업장은 처음엔 전부 미배정 상태로 둔다 (installer_id null).
-- 마스터가 화면(?token=마스터토큰)에서 사업장별로 설치업체를 지정하면 된다.

-- 발급된 토큰 확인 (이 값으로 링크를 만든다)
select name, access_token from app_admins;
select name, access_token from contractors;
select i.id, i.name, g.name as group_name, i.access_token
from installers i join contractors g on g.id = i.group_id
order by i.id;
