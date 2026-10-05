# 음악 삭제

`POST /functions/v1/delete-music`

로그인 사용자의 JWT와 `{ "musicAssetId": "<uuid>" }`를 받는다. 삭제를 완료하면
`{ "deleted": true }`, 이미 없으면 `{ "deleted": false }`를 HTTP 200으로
반환한다. 클라이언트가 전달한 소유자 ID나 Storage 경로는 사용하지 않는다.

```ts
const { data, error } = await supabase.functions.invoke("delete-music", {
  body: { musicAssetId },
});
```

- `401`: 로그인 토큰이 없거나 유효하지 않음.
- `400`: JSON 또는 음악 ID 형식 오류.
- `403`: 음악 소유자가 아님.
- `500 / deletion_prepare_failed`: DB 삭제 준비 실패.
- `502 / storage_delete_failed`: Storage 파일 삭제 실패. 같은 ID로 재시도한다.
- `500 / metadata_delete_failed`: 파일 삭제 후 메타데이터 정리 실패. 같은 ID로
  재시도한다.
- `500 / music_delete_failed`: 예상하지 못한 실패. 같은 ID로 재시도한다.

## 삭제 순서와 재시도

1. 요청자의 JWT로 `prepare_music_asset_deletion`을 호출한다. DB가
   로그인·소유권을 확인하고 음악 행을 잠근다. `deletion_pending = true`로
   표시하고 이 음악을 참조하는 모든 룸을 `music_asset_id = NULL`,
   `status = stopped`로 바꾼다. 메타데이터와 파일 경로는 보존한다. 이 단계는 한
   DB 트랜잭션이다.
2. 서버 전용 클라이언트로 준비 단계에서 얻은 파일 경로를 Storage API `remove`로
   삭제한다. Storage 테이블을 직접 삭제하지 않는다.
3. 서버 전용 `finish_music_asset_deletion`으로 메타데이터를 삭제한다. 준비
   상태와 요청에서 확인한 소유자 ID를 다시 검사한다. 클라이언트에는 실행 권한이
   없다.

Storage와 DB를 묶는 외부 트랜잭션은 없으므로 삭제 준비 상태를 보존한다. Storage
실패 시 파일과 메타데이터가 남고, 메타데이터 정리 실패 시 파일 경로를 담은
메타데이터가 남는다. 두 경우 모두 주크박스는 정지하며 같은 ID로 요청하면 정리를
이어간다. 이미 제거된 파일/메타데이터에 대한 재시도는 성공하는 no-op이다.

삭제 준비를 취소하거나 음악을 자동 복구하는 API는 제공하지 않는다. 실패한 음악은
개인 목록에 남아 소유자가 삭제를 재시도할 수 있다. 삭제 중인 음악에는 소유자도
새 signed URL을 발급받지 못한다. 기존 URL의 서명 만료 시점은 그대로지만 실제
파일이 삭제되면 다운로드할 수 없다.

## 주크박스 계약

BE #45가 `room_jukebox_states.status`에 `playing`·`paused`·`stopped` 값을
제공한다. 기본값은 `stopped`이며, 빈 음악 참조는 트리거가 항상 `stopped`로
맞춘다. 삭제/사용자 계정 삭제로 FK 참조가 비워지는 경우도 상태 행을 보존하며
정지한다. 삭제 중인 음악의 선택은 트리거가 거부하고, 선택과 삭제 시작은 음악 행
잠금으로 조정한다. 클라이언트의 상태 테이블 직접 변경 권한은 계속 차단한다.

BE #46은 기존 `room_id`, `music_asset_id`, `status`를 사용해 기준 위치·서버
시각· 반복 필드와 마스터 전용 상태 변경 함수 및 Realtime을 구현한다. 이번
작업에는 주크박스 재생·동기화 구현을 포함하지 않는다.

BE #46의 상태 변경 함수는 선택할 음악 행의 `FOR KEY SHARE` 잠금을 먼저 얻은 뒤
주크박스 행을 변경해야 한다. 삭제 준비도 음악 행을 먼저 잠그므로 같은 순서를
지켜 교착을 방지한다. 트리거는 추가 검증이며, 이미 주크박스 행을 잠근 뒤
호출되는 트리거만으로 잠금 순서를 보장할 수는 없다.

## 로컬 검증

로컬 Supabase와 `npx supabase functions serve`가 실행된 상태에서 검증한다. 키는
로컬 CLI 상태에서 얻어 프로세스 환경으로만 전달한다. 통합 테스트는
`SUPABASE_URL=http://127.0.0.1:54321`, `SUPABASE_ANON_KEY`,
`SUPABASE_SERVICE_ROLE_KEY`를 요구하고 원격 URL을 거부한다.

```sh
npx supabase test db supabase/tests/music_assets.sql \
  supabase/tests/music_playback_access.sql supabase/tests/music_asset_deletion.sql

deno test --allow-env --node-modules-dir=auto \
  --lock=supabase/functions/delete-music/deno.lock \
  supabase/functions/delete-music/index.test.ts

deno test --allow-env --allow-net=127.0.0.1:54321 \
  --allow-read=supabase/functions/upload-music/testdata --node-modules-dir=auto \
  --lock=supabase/functions/delete-music/deno.lock \
  supabase/functions/delete-music/integration.test.ts
```

단위 테스트는 Storage/DB 실패 응답을 주입해 호출 순서와 재시도를 검증한다. 통합
테스트는 실제 파일 삭제, 재생/일시정지 룸 참조 정리, 비소유자 거부, 중복· 동시
요청과 정리 중단 전후 상태에서의 재시도를 검증하고 임시 데이터를 제거한다.
