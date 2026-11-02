# 토큰 소속 맵 변경 차단 (BE #58)

기존 토큰의 `map_id`는 생성 후 변경할 수 없다. 플레이어와 마스터 모두 같은 룸의
다른 맵 또는 다른 룸의 맵으로 변경하면 SQLSTATE `23514`를 반환한다. 기존 맵 값을
유지하는 UPDATE, 위치 변경, 생성과 재할당은 기존 RLS에 따라 허용한다.

## 로컬 검증

로컬 Supabase에 마이그레이션을 적용한 뒤 BE 디렉터리에서 실행한다.

```sh
npx supabase test db --local
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
    'supabase/tests/room_token_map_boundary.test.ts'
], env=env).returncode)
PY
```

통합 테스트는 양쪽 룸에서 맵 열람·토큰 이동 권한을 가진 플레이어의 실제 Data API
요청을 검증한다. 대상 룸에만 속한 별도 구성원으로 이미지 메타데이터와 실제 파일
다운로드가 변경 시도 전후 모두 거부되는지 확인한다. 원래 룸 플레이어의 다운로드는
실제 바이트를 비교하며, 테스트 계정·룸·자산·파일은 종료 시 정리한다.

2026-11-02 로컬 검증 결과:

- 수정 전 플레이어의 룸 간 맵 변경과 대상 룸 구성원의 메타데이터·원본 다운로드를 재현했다.
- 수정 전 SQL 회귀 테스트 5개와 API 회귀 테스트가 실패하고, 수정 후 통과했다.
- 전체 DB 테스트 25개 파일·726개 검사와 API 통합 테스트가 통과했다.
- 로컬 security advisor에서 warn 이상 문제가 없었다.
