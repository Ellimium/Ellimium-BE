# 음악 signed URL

`POST /functions/v1/music-signed-url`

로그인 사용자의 JWT와 `{ "musicAssetId": "<uuid>" }`를 받는다. 성공하면
`{ "signedUrl": "<url>", "expiresIn": 300 }`를 반환한다. `expiresIn` 입력은
사용하지 않으며, 이 엔드포인트는 항상 5분 동안 유효한 URL을 발급한다.

```ts
const { data, error } = await supabase.functions.invoke("music-signed-url", {
  body: { musicAssetId },
});
```

- `401`: 로그인하지 않았거나 유효하지 않은 토큰.
- `400`: JSON 또는 음악 ID 형식이 잘못됨.
- `403`: 접근 권한이 없거나 음악/파일이 없음. 존재 여부를 구분해 노출하지
  않는다.
- `500`: 설정 또는 음악 경로 조회 실패.
- `502`: Storage 서비스의 URL 발급 실패.

응답에는 `Cache-Control: no-store`를 적용한다. 소유자는 개인 음악을 발급받고,
다른 사용자는 음악을 현재 참조하는 룸 중 하나의 활성 구성원일 때만 발급받는다.
플레이어와 관전자 모두 이 규칙을 따른다. `left`·`removed` 상태나 음악 참조
교체·제거는 다음 발급부터 반영된다. 이미 발급된 URL은 만료 시점까지 유효하다.

경로 조회에만 서버 전용 클라이언트를 사용한다. 실제 서명에는 요청자의 JWT를
전달한 클라이언트를 사용하므로 Storage RLS가 현재 권한을 재확인한다. 직접
Storage API를 호출해도 같은 RLS를 적용한다. Storage API의 자체 `expiresIn`
인자는 이 엔드포인트와 별개이며, 5분은 애플리케이션 발급 계약이다.

`music_assets`의 개인 목록 RLS는 소유자 조회만 유지한다. 룸 구성원에게 다른
사용자의 음악 목록이나 메타데이터 조회 권한을 추가하지 않는다.

로컬 Edge Runtime의 내부 `kong` 주소는 클라이언트용 기본 주소
`http://127.0.0.1:54321`로 바꾼다. 호스팅 환경에서는 `SUPABASE_URL`을 사용한다.
다른 로컬 포트나 별도 공개 도메인은 서버 환경 변수 `MUSIC_PUBLIC_API_URL`로
지정한다. 요청 헤더로 응답 URL의 도메인을 결정하지 않는다.

## BE #46과의 계약

BE #45가 `public.room_jukebox_states`에 아래 최소 필드와 조회 RLS를 제공한다.

| 필드             | 의미                                                |
| ---------------- | --------------------------------------------------- |
| `room_id`        | 룸 FK이자 PK. 룸당 최대 한 행, 룸 삭제 시 함께 제거 |
| `music_asset_id` | 현재 음악 FK. 음악 없음은 NULL, 음악 삭제 시 NULL   |

활성 룸 구성원만 상태 행을 조회한다. 클라이언트의 INSERT·UPDATE·DELETE 권한은
부여하지 않는다. 이 단계에서 음악 선택 기능은 아직 제공하지 않는다.

BE #46은 이 테이블을 확장해 재생 상태·기준 위치·서버 변경 시각·반복 여부와
Realtime을 구현한다. 로그인한 활성 마스터만 자신의 음악을 선택하는 PostgreSQL
함수를 제공하고, 첫 상태 설정 시 행을 생성하며 이후 제거·정지는 행 삭제 대신
참조를 비우는 UPDATE로 처리한다. 음악 삭제 시 `stopped` 갱신도 재생 상태 필드가
추가된 뒤 이 테이블과 연결한다.

## 로컬 검증

Supabase CLI 2.118.0과 Docker로 로컬 서비스를 실행하고 함수를 serve한 상태에서
아래 명령을 사용한다. 원격 환경에서는 실행하지 않는다.

```sh
npx supabase test db supabase/tests/music_assets.sql supabase/tests/music_playback_access.sql

deno test --allow-env --allow-net=127.0.0.1:54321 --allow-run=docker \
  --allow-read=supabase/functions/upload-music/testdata \
  --node-modules-dir=auto --lock=supabase/functions/music-signed-url/deno.lock \
  supabase/functions/music-signed-url/integration.test.ts
```

통합 테스트의 `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`는
로컬 CLI 상태에서 얻어 프로세스 환경으로만 전달한다. 키를 파일이나 로그에
기록하지 않는다. 테스트는 임시 사용자·룸·업로드 파일을 만들고 종료 시 제거한다.
자진 퇴장 RPC가 아직 없으므로 `left` 상태는 Docker 내 로컬 postgres로 구성하고,
강제 퇴장은 기존 마스터 RPC로 실행한다. 두 경우 모두 퇴장 전 JWT를 다시 사용해
새 발급 거부를 검증한다. 5분은 실제 서명 토큰의 만료 값으로 확인하고, 실제 만료
후 다운로드 거부는 같은 Storage 발급기에 2초 TTL을 지정해 확인한다.
