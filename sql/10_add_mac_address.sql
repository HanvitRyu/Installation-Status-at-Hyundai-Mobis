-- ============================================================
-- 모뎀(C, GX-8200 TCP/IP) 대수별 정보에 MAC주소 칸 추가.
--
-- Supabase SQL Editor 에서 이 파일 전체를 한 번만 실행하세요.
-- ============================================================

alter table installation_units add column mac_address text;

create or replace function save_installation_units(
  p_token text, p_site_id bigint, p_product text, p_units jsonb
) returns void language plpgsql security definer as $$
begin
  if not can_edit_site(p_token, p_site_id) then
    raise exception '이 사업장을 수정할 권한이 없습니다';
  end if;
  if p_product not in ('B','C') then
    raise exception '수량별 상세 정보는 리피터(B)·모뎀(C) 품목에만 입력할 수 있습니다';
  end if;

  delete from installation_units where site_id = p_site_id and product = p_product;

  insert into installation_units (site_id, product, unit_no, location, ip, mac_address, gateway, subnet_mask, host_ip)
  select
    p_site_id, p_product,
    (u->>'unit_no')::int,
    u->>'location', u->>'ip', u->>'mac_address', u->>'gateway', u->>'subnet_mask', u->>'host_ip'
  from jsonb_array_elements(p_units) as u;
end; $$;
