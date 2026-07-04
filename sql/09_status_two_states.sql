-- ============================================================
-- 진행여부를 미착수/진행중/완료 3단계에서 미착수/완료 2단계로 축소.
-- 기존에 '진행중'으로 저장된 행이 있으면 '미착수'로 되돌린다.
--
-- Supabase SQL Editor 에서 이 파일 전체를 한 번만 실행하세요.
-- ============================================================

update sites set status = '미착수' where status = '진행중';

alter table sites drop constraint sites_status_check;
alter table sites add constraint sites_status_check check (status in ('미착수','완료'));
