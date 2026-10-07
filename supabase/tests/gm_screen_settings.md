# GM 화면 설정 (BE #21)

`public.gm_screen_settings`는 `(user_id, panel_id)`를 기본 키로 사용하는 사용자별
패널 설정이다. `collapsed`는 접힘 여부, `visible`은 표시 여부, `position`은
0 이상의 배치 순서다. 패널 ID는 앞뒤 공백 없는 1~64자 문자열이다.
저장하지 않은 패널은 FE 기본 배치를 사용한다. 동일한 순서는 `panel_id`로 정렬한다.

인증 사용자는 자신의 설정만 SELECT·INSERT·UPDATE·DELETE할 수 있다.
같은 룸의 GM·플레이어도 다른 사용자의 설정에 접근할 수 없다.
GM은 전역 사용자 역할이 아니라 룸별 역할이므로 저장은 사용자 소유권으로 제한하며,
FE #23에서 현재 룸의 GM 화면에만 설정을 적용한다. 플레이어 화면에는 적용하지 않는다.
계정 삭제 시 설정도 삭제된다.

FE는 `gm_screen_settings`에 `{ user_id, panel_id, collapsed, visible, position }`을
`upsert(..., { onConflict: "user_id,panel_id" })`하여 저장하고, 본인 행을
`position`, `panel_id` 순으로 조회한다. 여러 패널은 한 번의 배열 upsert로 저장한다.
본인 행을 DELETE하면 해당 패널을 기본 설정으로 복원할 수 있다.
RLS가 숨긴 다른 사용자의 UPDATE·DELETE는 오류 없이 0행을 반환하므로 반환 행을 확인한다.

## 로컬 검증

```sh
npx supabase test db --local supabase/tests/gm_screen_settings.sql
```

23개 pgTAP 검증은 저장·upsert·재조회, 사용자 및 같은 룸 플레이어의 접근 격리,
소유권 변경 거부, 입력 제약, 비인증 접근 거부, 계정 삭제 시 정리를 확인한다.
테스트 데이터는 트랜잭션 종료 시 롤백한다.
