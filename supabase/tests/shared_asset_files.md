# 공유 자산 파일 접근 (BE #3)

룸 라이브러리 공유는 `assets` 버킷의 원본·썸네일에 인증 다운로드 권한만
추가한다. 다음 Storage 경로에 현재 사용자 JWT를 보내면 요청마다 공유 관계와
활성 멤버십을 RLS로 검사한다.

```text
GET /storage/v1/object/authenticated/assets/{storage_path}
Authorization: Bearer {current_user_access_token}
apikey: {anon_key}
```

FE는 위 경로를 `fetch(..., { cache: "no-store" })`로 요청하고 반환된 Blob을
이미지로 표시한다. 룸 전환·다시 조회 시 기존 Blob URL을 해제하고 다시 요청한다.
`supabase.storage.from("assets").download(path)`도 동일한 인증 경로를 사용하지만,
브라우저 캐시를 확실히 피하려면 위 fetch 방식을 사용한다.

공유만으로는 `createSignedUrl`·`createSignedUrls`가 허용되지 않는다. signed URL은
만료 전 권한 회수가 불가능하므로 공유 라이브러리 이미지에는 사용하지 않는다.
정책은 `storage.allow_only_operation('object.get_authenticated')`로 다운로드와
URL 발급을 구분한다. 직접 파일 목록 조회·이미지 변환 등 다른 작업에는 공유
권한을 추가하지 않는다. 파일 쓰기·삭제 정책도 추가하지 않는다.

공유 해제·탈퇴·강제 제외 후 같은 인증 URL과 JWT로 다시 요청해도 접근이
거부된다. 여러 룸 중 하나만 공유 해제하면 다른 공유 룸의 권한은 유지된다.
이미 다운로드된 파일 자체는 회수할 수 없다.

자산 소유자와 기존 맵·토큰 사용 권한은 별도 접근 근거로 유지한다. 이 권한으로
발급한 signed URL은 기존처럼 만료까지 유효하다. 라이브러리 공유 해제는 이러한
별도 권한을 제거하지 않으며, 공유 권한만 가진 구성원에게는 signed URL이
발급되지 않으므로 공유 해제 후 사용할 signed URL도 남지 않는다.

## 로컬 검증

로컬 Supabase를 실행한 뒤 BE 디렉터리에서 실행한다. 키는 상태 출력에서 읽어
테스트 프로세스 환경에만 전달하고 출력하거나 파일에 저장하지 않는다.

```sh
python3 - <<'PY'
import json, os, subprocess
status = json.loads(subprocess.check_output(
    ['npx', 'supabase', 'status', '-o', 'json'], text=True))
env = os.environ.copy()
for key, source in [('SUPABASE_URL', 'API_URL'),
                    ('SUPABASE_ANON_KEY', 'ANON_KEY'),
                    ('SUPABASE_SERVICE_ROLE_KEY', 'SERVICE_ROLE_KEY')]:
    env[key] = status[source]
raise SystemExit(subprocess.run([
    'deno', 'test', '--allow-env', '--allow-net=127.0.0.1:54321',
    '--allow-run=docker', 'supabase/tests/shared_asset_files.test.ts'
], env=env).returncode)
PY
```

테스트는 원본·썸네일 실제 바이트, 공유 전후·해제 후 접근, 비구성원·비인증 접근,
단건·일괄 signed URL 발급 거부, 파일 변경·삭제 거부, 멤버십 변경 시 같은 JWT의
접근 차단, 다른 공유 룸 및 기존 맵·토큰 권한을 검증한다. 테스트에서 만든 룸·파일·
사용자는 마지막에 삭제한다. 탈퇴 API가 없으므로 해당 상태 준비만 로컬 DB에서
직접 실행한다.
