# 음악 검증 테스트 데이터

외부 녹음물을 사용하지 않고 생성한 작은 오디오 파일이다.

- `silence.mp3`: MPEG-1 Layer III 128kbps/44.1kHz 프레임 10개. 각 417바이트
  프레임의 헤더는 `FF FB 90 64`, 나머지는 0이다. 디코딩 길이 261ms.
- `silence-opus.ogg`: 단일 채널 48kHz OpusHead(pre-skip 0), 빈 OpusTags, 무음
  패킷 `F8 FF FE`를 각각 OGG 페이지로 구성했다. 마지막 페이지의 granule은
  960이며 EOS를 설정했다. 각 페이지에는 OGG CRC를 기록했다. 디코딩 길이 20ms.
- `tone-vorbis.ogg`: `@audio/encode-ogg@1.3.0`으로 생성한 100ms 440Hz 톤이다.
  입력은 `sin(2π × 440 × i / 44100) × 0.1`인 Float32Array 4410개, 단일 채널,
  44.1kHz, quality 3이다. 인코더의 encode 결과와 flush 결과를 이어 붙였다.
  인코더는 테스트 데이터 생성에만 사용하며 런타임 의존성이 아니다.

BE 루트에서 검증:

```sh
deno test --allow-env --allow-read=supabase/functions/upload-music/testdata --no-lock --node-modules-dir=auto supabase/functions/upload-music/
```
