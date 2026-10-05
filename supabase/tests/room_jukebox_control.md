# 룸 주크박스 제어 계약 (BE #46)

`public.room_jukebox_states`는 룸당 최대 한 행을 저장한다. 첫 `play` 또는 `stop`
호출이 행을 생성하며, 이후 정지·음악 제거·음악 삭제는 행을 유지하는 UPDATE다.
룸 자체를 삭제하면 FK cascade로 행도 삭제된다.

## 상태 조회

활성 룸 구성원만 아래 필드를 조회한다. 플레이어와 관전자도 읽을 수 있지만,
클라이언트의 INSERT·UPDATE·DELETE 권한은 마스터에게도 없다.

| 필드 | 의미 |
| --- | --- |
| `room_id` | 룸 FK·PK |
| `music_asset_id` | 현재 음악 FK. 공용 정지·음악 제거·삭제 시 NULL |
| `status` | `playing`·`paused`·`stopped` |
| `position_ms` | `state_changed_at` 시점의 기준 재생 위치, 음이 아닌 정수 밀리초 |
| `state_changed_at` | 서버 기준 상태 변경 시각 (`timestamptz`) |
| `loop_enabled` | 한 곡 반복 여부 |

아직 상태 행이 없으면 FE는 음악 없는 `stopped` 상태로 표시한다.

## 마스터 제어 RPC

`control_room_jukebox(target_room_id, action, target_music_asset_id = NULL,
target_position_ms = NULL, target_loop_enabled = NULL)`은 변경 후 상태 행을 반환한다.
로그인한 활성 마스터만 호출할 수 있다. 인자 이름은 FE에서 Supabase RPC 요청의
JSON 키로 사용한다. 상태 변경 시각을 클라이언트에서 전달하는 인자는 없다.

| `action` | 인자·동작 |
| --- | --- |
| `play` | 본인 소유 `target_music_asset_id` 필수. 해당 음악을 선택하고 `playing`으로 전환. 위치는 생략 시 0, 반복은 생략 시 false |
| `pause` | `playing`에서 서버 경과 시간을 기준 위치에 더한 뒤 `paused`로 전환. 이미 `paused`면 기존 상태 반환 |
| `resume` | `paused`의 기준 위치를 유지하며 `playing`으로 전환. 이미 `playing`이면 기존 상태 반환 |
| `stop` | 음악 참조·위치·반복을 NULL·0·false로 초기화하고 `stopped`로 전환. 음악 제거도 이 동작 사용 |
| `seek` | `target_position_ms` 필수. 선택된 음악의 위치만 변경하며 `playing` 또는 `paused` 유지 |
| `set_loop` | `target_loop_enabled` 필수. 선택된 음악의 반복을 변경하며 재생 상태 유지 |

`pause`·`resume`·`seek`·`set_loop`는 선택된 음악이 있어야 한다. 역할이 마스터로
변경된 사용자는 다른 마스터가 선택해 둔 음악을 제어할 수 있지만, 새로 선택할
음악은 호출자 본인 소유여야 한다. 없는 음악 또는 삭제 진행 중인 음악은 선택할
수 없다. 음수 위치·알 수 없는 동작·동작에 사용되지 않는 인자는 거부한다.

권한 오류는 `42501`, 잘못된 인자·상태는 `22023`, 삭제 진행 중인 음악은 `23514`다.

## 재생 위치와 Realtime

`playing`일 때 현재 타임라인 위치는 `position_ms`에 서버 변경 시각 이후의 경과
밀리초를 더한 값이다. `paused`일 때는 `position_ms`를 그대로 사용한다. 서버는
브라우저마다 확인할 실제 재생 시간을 알 수 없으므로 DB 메타데이터의 재생 시간으로
위치를 제한하거나 나머지 연산을 하지 않는다. FE는 파일 로드 후 브라우저가 확인한
재생 시간으로 반복 위치를 계산하고, 반복하지 않을 때 파일 끝을 처리한다.

`pause`와 재생 중 `set_loop`는 경과 시간을 기준 위치에 합산하고 서버 시각을
갱신한다. 일시 정지 중 위치 변경·반복 설정·재개는 정지 시간만큼 위치를 더하지
않는다. 반복된 `pause`·`resume`은 시각도 변경하지 않는다.

테이블은 `supabase_realtime` publication에 등록된다. FE는 `room_id` 필터로
INSERT·UPDATE를 구독하고, 입장·재연결 시 상태를 다시 조회한다. 기존 SELECT RLS로
수신 대상이 활성 구성원으로 제한된다. 음악 삭제 알림은 DELETE 대신 참조를 비운
UPDATE를 사용한다. 서버 시각·실제 길이를 사용한 FE 동기화는 FE #53에서 구현한다.
[Supabase Postgres Changes 문서](https://supabase.com/docs/guides/realtime/postgres-changes)를 따른다.

## 삭제·동시 실행

제어 RPC는 룸 행으로 같은 룸의 동시 명령·첫 행 생성을 직렬화하고, 호출자의 활성
마스터 구성원 행을 잠가 제어 중 역할·퇴장 변경과 조정한다. 음악이 필요한 명령은
음악 행의 `FOR KEY SHARE` 잠금을 먼저 획득한 뒤 주크박스 행을 잠근다. 삭제 준비는
음악 행을 먼저 `FOR UPDATE`로 잠그므로 같은 잠금 순서를 따른다.

재생 제어가 먼저 완료되면 삭제 준비가 참조를 비우고 정지한다. 삭제 준비가 먼저
완료되면 후속 재생 제어가 삭제 진행 중인 음악을 거부한다. 명시적 삭제 준비와 FK
SET NULL 모두 트리거로 위치·반복·서버 변경 시각을 정리한다. signed URL 발급은
기존 [음악 파일 접근 계약](../functions/music-signed-url/README.md)을 재사용한다.

## 로컬 검증

```sh
npx supabase migration up --local
npx supabase test db --local
npx supabase db lint --local --schema public,private --fail-on error
npx supabase db advisors --local --type security --level warn
```

2026-10-05에 로컬 Supabase CLI 2.118.0으로 검증했다.

- `room_jukebox_control.sql`: 상태 전이·시간 계산·잘못된 인자·역할별 접근·직접 쓰기 차단·삭제 정리 82개 통과.
- 전체 SQL 테스트: 21개 파일, 560개 통과.
- DB lint와 security advisors: 발견된 문제 없음.
- 별도 로컬 DB 세션에서 재생 제어 먼저/삭제 준비 먼저의 두 동시 실행 순서를 확인했다. 교착 없이 삭제 후 정지 또는 재선택 거부를 확인하고 임시 데이터를 정리했다.

역할별 실제 Realtime 수신과 signed URL 발급·만료 통합 검증은 두 번째 TODO에서
수행한다. 현재 검증은 DB 권한·publication 설정·SQL 동작 범위다.
