-- 사진 업로드 기능 2종:
--   1) 유닛(GX-8200/GX-8200 TCP/IP)별 설치사진 1장
--   2) 사업장 단위 "GST-502 등 기타 사진" 최대 5장
-- 전부 스키마 변경(새 컬럼/새 테이블/새 함수/새 버킷/새 정책)만 포함하며, 기존 사업장
-- 데이터 값은 전혀 수정하지 않는다.

-- ============================================================
-- 1) 유닛별 설치사진 1장
-- ============================================================

-- installation_units에 사진 경로 컬럼 추가 (기존 행은 전부 NULL로 시작, 값 변경 없음)
alter table installation_units add column if not exists photo_path text;

-- save_installation_units는 저장할 때마다 해당 사업장·품목의 기존 행을 전부 지우고
-- 폼에 있는 값으로 다시 넣는 방식이라, 그대로 두면 위치/네트워크 정보를 저장할 때마다
-- 이미 올려둔 사진 링크가 함께 삭제돼버린다. unit_no 기준으로 기존 photo_path를 백업했다가
-- 재삽입 후 복원하도록 수정한다. (동작 자체는 동일, 사진 유실만 방지)
create or replace function save_installation_units(
  p_token text, p_site_id bigint, p_product text, p_units jsonb
) returns void language plpgsql security definer as $$
declare
  v_photos jsonb;
begin
  if not can_edit_site(p_token, p_site_id) then
    raise exception '이 사업장을 수정할 권한이 없습니다';
  end if;
  if p_product not in ('B','C') then
    raise exception '수량별 상세 정보는 리피터(B)·모뎀(C) 품목에만 입력할 수 있습니다';
  end if;

  select jsonb_object_agg(unit_no, photo_path) into v_photos
  from installation_units
  where site_id = p_site_id and product = p_product and photo_path is not null;

  delete from installation_units where site_id = p_site_id and product = p_product;

  insert into installation_units (site_id, product, unit_no, location, ip, mac_address, gateway, subnet_mask, host_ip)
  select
    p_site_id, p_product,
    (u->>'unit_no')::int,
    u->>'location', u->>'ip', u->>'mac_address', u->>'gateway', u->>'subnet_mask', u->>'host_ip'
  from jsonb_array_elements(p_units) as u;

  if v_photos is not null then
    update installation_units
    set photo_path = v_photos ->> unit_no::text
    where site_id = p_site_id and product = p_product
      and v_photos ? unit_no::text;
  end if;
end; $$;

-- 유닛 사진 경로만 저장하는 전용 RPC (기존 can_edit_site로 권한 체크, 다른 필드는 안 건드림)
create or replace function save_unit_photo(
  p_token text, p_site_id bigint, p_product text, p_unit_no integer, p_photo_path text
) returns void language plpgsql security definer as $$
begin
  if not can_edit_site(p_token, p_site_id) then
    raise exception '이 사업장을 수정할 권한이 없습니다';
  end if;
  update installation_units
  set photo_path = p_photo_path
  where site_id = p_site_id and product = p_product and unit_no = p_unit_no;
end; $$;

-- ============================================================
-- 2) 사업장 단위 "GST-502 등 기타 사진" (최대 5장)
-- ============================================================

create table if not exists site_photos (
  id           bigint generated always as identity primary key,
  site_id      bigint references sites(id) not null,
  photo_path   text not null,
  created_at   timestamptz default now()
);
alter table site_photos enable row level security;
-- 정책 없음 → anon 직접 접근 전면 차단, RPC로만 접근 (기존 테이블들과 동일한 방식)

create or replace function get_site_photos(p_token text)
returns setof site_photos
language sql stable security definer as $$
  select sp.* from site_photos sp
  join sites s on s.id = sp.site_id
  left join installers i on i.id = s.installer_id
  where
    exists (select 1 from app_admins where access_token = p_token)
    or i.access_token = p_token
    or i.group_id = (select id from contractors where access_token = p_token)
    or s.group_id = (select id from contractors where access_token = p_token);
$$;

create or replace function add_site_photo(p_token text, p_site_id bigint, p_photo_path text)
returns bigint language plpgsql security definer as $$
declare
  v_id bigint;
begin
  if not can_edit_site(p_token, p_site_id) then
    raise exception '이 사업장을 수정할 권한이 없습니다';
  end if;
  if (select count(*) from site_photos where site_id = p_site_id) >= 5 then
    raise exception '사진은 최대 5장까지 업로드할 수 있습니다';
  end if;
  insert into site_photos (site_id, photo_path) values (p_site_id, p_photo_path) returning id into v_id;
  return v_id;
end; $$;

create or replace function delete_site_photo(p_token text, p_photo_id bigint)
returns void language plpgsql security definer as $$
declare
  v_site_id bigint;
begin
  select site_id into v_site_id from site_photos where id = p_photo_id;
  if v_site_id is null then
    return;
  end if;
  if not can_edit_site(p_token, v_site_id) then
    raise exception '이 사업장을 수정할 권한이 없습니다';
  end if;
  delete from site_photos where id = p_photo_id;
end; $$;

-- ============================================================
-- 3) Storage: 두 기능이 함께 쓰는 비공개 버킷 + 정책
-- ============================================================

-- 정책에서 can_edit_site를 직접 쓰면 익명 role의 RLS 차단에 걸려 항상 거부되므로,
-- 같은 판정 로직을 얇게 감싼 SECURITY DEFINER 함수를 별도로 둔다.
-- (기존 can_edit_site 함수 자체는 전혀 수정하지 않음 — 다른 모든 저장 로직이 그걸 그대로 씀)
create or replace function storage_can_access_unit(p_token text, p_site_id bigint)
returns boolean language sql stable security definer as $$
  select can_edit_site(p_token, p_site_id);
$$;

-- 비공개 Storage 버킷 생성. 이미지 파일만, 8MB 이하로 제한.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('installation-photos', 'installation-photos', false, 8388608, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

-- 업로드 경로 규칙: "{token}/{site_id}/파일명"
--   유닛 사진: {token}/{site_id}/C-1.jpg 형태
--   기타 사진: {token}/{site_id}/misc-<타임스탬프>.jpg 형태
-- 경로 첫 번째 폴더가 토큰, 두 번째 폴더가 사업장 id. 그 토큰이 그 사업장을 수정할
-- 권한이 있는지 storage_can_access_unit로 검증한다. (파일명 자체는 정책과 무관)
drop policy if exists "installation photos: insert by permitted token" on storage.objects;
create policy "installation photos: insert by permitted token"
on storage.objects for insert to anon
with check (
  bucket_id = 'installation-photos'
  and storage_can_access_unit((storage.foldername(name))[1], nullif((storage.foldername(name))[2], '')::bigint)
);

drop policy if exists "installation photos: update by permitted token" on storage.objects;
create policy "installation photos: update by permitted token"
on storage.objects for update to anon
using (
  bucket_id = 'installation-photos'
  and storage_can_access_unit((storage.foldername(name))[1], nullif((storage.foldername(name))[2], '')::bigint)
)
with check (
  bucket_id = 'installation-photos'
  and storage_can_access_unit((storage.foldername(name))[1], nullif((storage.foldername(name))[2], '')::bigint)
);

drop policy if exists "installation photos: select by permitted token" on storage.objects;
create policy "installation photos: select by permitted token"
on storage.objects for select to anon
using (
  bucket_id = 'installation-photos'
  and storage_can_access_unit((storage.foldername(name))[1], nullif((storage.foldername(name))[2], '')::bigint)
);

drop policy if exists "installation photos: delete by permitted token" on storage.objects;
create policy "installation photos: delete by permitted token"
on storage.objects for delete to anon
using (
  bucket_id = 'installation-photos'
  and storage_can_access_unit((storage.foldername(name))[1], nullif((storage.foldername(name))[2], '')::bigint)
);
