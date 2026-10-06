# 자산 폴더 로컬 검증 (BE #2)

`Ellimium-BE`에서 로컬 Supabase 실행과 마이그레이션 적용을 확인한 뒤 실행한다.

```sh
npx supabase test db --local supabase/tests/asset_folders.sql
sh supabase/tests/asset_folders_upgrade.sh
```

- `asset_folders.sql`: 생성·이름 변경의 저장값, 빈 폴더 삭제, 내용이 있는 폴더 삭제 거부와 데이터 보존, 폴더 간·미분류 양방향 이동, 깊이 위반, 타인·미인증 사용자의 변경 거부를 검증한다. 룸 참가로 읽을 수 있는 타인 자산도 이동할 수 없어야 한다.
- `asset_folders_upgrade.sh`: 실제 마이그레이션 파일을 임시 pgTAP 테스트에 포함해 기존 자산의 모든 메타데이터 보존과 기존·새 업로드의 미분류 기본 상태를 검증한다. 서비스 역할의 메타데이터 INSERT를 사용하며 Edge Function이나 실제 파일 업로드를 호출하지 않는다.
- 두 검증 모두 트랜잭션을 롤백한다. 업그레이드 검증 중 스키마를 임시로 변경하므로 다른 개발 작업과 동시에 실행하지 않는다. 실행 후 임시 파일을 제거한다.
- 전체 DB 회귀 검증은 `npx supabase test db --local`로 실행한다. 업그레이드 검증 스크립트는 위 명령으로 별도 실행한다.

합격 기준은 각 실행의 `Result: PASS`다. 모든 명령은 로컬 환경에만 적용하며 원격 데이터와 비밀 키를 사용하지 않는다.
