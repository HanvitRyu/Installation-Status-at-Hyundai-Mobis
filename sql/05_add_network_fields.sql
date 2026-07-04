-- ============================================================
-- 증분 스크립트: 이미 01_schema.sql + 02_seed_placeholder.sql 을
-- 실행한 프로젝트에 "모뎀(C 품목) 대수별 네트워크 정보" 기능을 추가한다.
-- (01_schema.sql 은 이 내용을 이미 포함하도록 갱신해두었으니,
--  앞으로 새로 시작하는 프로젝트는 01_schema.sql만 실행하면 되고
--  이 파일은 필요 없다.)
--
-- Supabase SQL Editor 에서 이 파일 전체를 한 번만 실행하세요.
-- ============================================================

create table installation_units (
  id           bigint generated always as identity primary key,
  site_id      bigint references sites(id) not null,
  product      text not null check (product = 'C'),
  unit_no      integer not null,
  ip           text,
  gateway      text,
  subnet_mask  text,
  host_ip      text,
  unique (site_id, product, unit_no)
);

alter table installation_units enable row level security;
create policy "inst_units_read_all" on installation_units for select using (true);

create or replace function save_installation_units(
  p_token text, p_site_id bigint, p_product text, p_units jsonb
) returns void language plpgsql security definer as $$
begin
  if not can_edit_site(p_token, p_site_id) then
    raise exception '이 사업장을 수정할 권한이 없습니다';
  end if;
  if p_product <> 'C' then
    raise exception '네트워크 정보는 모뎀(C) 품목에만 입력할 수 있습니다';
  end if;

  delete from installation_units where site_id = p_site_id and product = p_product;

  insert into installation_units (site_id, product, unit_no, ip, gateway, subnet_mask, host_ip)
  select
    p_site_id, p_product,
    (u->>'unit_no')::int,
    u->>'ip', u->>'gateway', u->>'subnet_mask', u->>'host_ip'
  from jsonb_array_elements(p_units) as u;
end; $$;
