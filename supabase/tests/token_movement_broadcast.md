# 서버 검증 토큰 이동 송신 (BE #60 / FE #97)

## FE 송신 계약

인증된 클라이언트는 다음 RPC를 호출한다. 클라이언트의 anon key와 사용자 세션을
사용하며, service role key는 필요하지 않다.

```ts
const { error } = await supabase.rpc("broadcast_token_movement", {
  target_room_id: roomId,
  target_token_id: tokenId,
  position_x: x,
  position_y: y,
});
```

성공 시 반환값은 `void`다. 서버가 토큰의 실제 룸, 활성 멤버 여부, 역할,
`token_move`, 할당 소유권을 매 호출마다 검증한다. 마스터는 해당 룸의 모든 토큰,
플레이어는 본인 할당 토큰만 송신할 수 있다. 관전자는 개인 권한이 있어도 송신할
수 없다. 다른 룸·없는 토큰도 같은 권한 오류를 반환한다.

| SQLSTATE | 의미 |
|---|---|
| `42501` | 인증·역할·멤버 상태·이동 권한·토큰 룸/할당 조건 불충족 |
| `22023` | 좌표가 null, NaN, 양/음의 Infinity |

UUID·숫자 형식 자체가 잘못된 요청은 PostgreSQL/PostgREST의 입력 오류를 반환한다.
네트워크 오류와 위 오류를 포함해 FE는 `error`를 처리해야 한다.

수신 채널은 **`room:<roomId>:token-movements`**, `private: true`, 이벤트는
`token-move`다. payload는 다음 형태다. `sender_id`는 서버가 `auth.uid()`로 채운다.

```ts
{ token_id: string, x: number, y: number, sender_id: string }
```

서버 송신은 발신 클라이언트의 채널 `broadcast.self: false`와 무관하게 발신자에게도
도착한다. FE는 서버 echo를 로컬 드래그의 최신 위치에 덮어쓰지 않도록 처리한다.
RPC는 임시 좌표를 방송할 뿐 `room_tokens.x/y`를 저장하지 않는다. 확정 저장은
기존 RLS로 보호된 UPDATE를 사용한다. RPC 성공은 연결된 모든 화면에 전달됐다는
보장이 아니며, 취소·저장 실패·권한 상실 시 DB 확정 좌표로 복구해야 한다.
호출 간 순서나 최종 UPDATE와의 수신 순서는 이 API가 보장하지 않는다. FE #97에서
대기 요청과 늦은 메시지의 처리를 구현하고 통합 검증한다.

## 직접 송신과 적용 순서

기존 `room:<roomId>:tokens` 채널의 송신 정책을 제거하고, 수신 정책도 새 채널로
전환한다. 기존 접속에 남은 송신 권한이 새 FE 수신자에게 도달하지 않도록 채널을
분리했다. 새 채널은 클라이언트의 직접 WebSocket/REST 송신을 허용하지 않는다.
배치 REST API는 전달되지 않는 메시지에도 HTTP 202를 반환할 수 있으므로, 차단은
응답 상태와 별도로 수신 여부를 검사한다.

BE만 적용하면 기존 FE의 임시 이동 공유가 중단된다. FE #97과 함께 준비하고 로컬
또는 원격 테스트(`ellimium-test`)에서 화면 통합 검증 후 적용한다. 프로덕션 작업은
별도 사용자 요청이 필요하다. 수신 권한의 접속 후 즉시 철회는 이번 송신 검증의
범위에 포함하지 않으며, 기존 Realtime 구독 권한 캐시 동작을 따른다.

## 로컬 검증

마이그레이션 적용 후 BE 디렉터리에서 실행한다. 통합 테스트는 로컬만 허용하며,
service role key는 fixture 생성·정리에만 사용한다. 실제 검증 요청은 사용자 세션과
anon key로 보낸다.

```sh
npx supabase test db --local supabase/tests/token_movement_broadcast.sql supabase/tests/room_tokens.sql supabase/tests/room_feature_permissions.sql
python3 - <<'PY'
import json, os, subprocess
status = json.loads(subprocess.check_output(
    ['npx', 'supabase', 'status', '-o', 'json'],
    text=True, stderr=subprocess.DEVNULL))
env = os.environ.copy()
for target, source in [('SUPABASE_URL', 'API_URL'),
                       ('SUPABASE_ANON_KEY', 'ANON_KEY'),
                       ('SUPABASE_SERVICE_ROLE_KEY', 'SERVICE_ROLE_KEY')]:
    env[target] = status[source]
raise SystemExit(subprocess.run([
    'deno', 'test', '--allow-env', '--allow-net=127.0.0.1:54321',
    'supabase/tests/room_tokens_realtime.test.ts'
], env=env).returncode)
PY
```

수정 전 로컬 private WebSocket에서 P1이 P2 소유 토큰의 표시 좌표를 `(999,999)`로
위조해 다른 참가자에게 전달할 수 있었고, DB 좌표는 `(1,2)`로 유지됨을 재현했다.

## 검증 결과 (2026-11-03)

- 로컬에 최종 마이그레이션 파일을 적용하고 적용 이력을 확인했다.
- 실제 private WebSocket 통합 테스트 1개와 전체 SQL 테스트 26개 파일·761개 검사를 통과했다.
- 정상 송신, 타인·미할당·다른 룸·없는 토큰, 외부인·비활성·관전자·익명·미인증 사용자,
  잘못된 좌표, 접속 후 권한·역할·할당 변경과 강제 퇴장, 직접 WebSocket/REST 우회를 확인했다.
- local security advisor는 warn 이상 문제가 없었고, public/private DB lint·Deno 타입 검사·lint를 통과했다.
- FE 화면 연동 검증과 원격 테스트·프로덕션 적용은 수행하지 않았다.
