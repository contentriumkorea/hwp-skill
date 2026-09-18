# 화면을 열지 않는 근사 미리보기

HWPX의 문단·표·이미지·용지 정보를 확인하거나 디자인을 검토할 때 사용한다.

```powershell
& "<스킬 경로>/scripts/Invoke-HwpSkill.ps1" preview `
  -LiteralPath "문서.hwpx" -OutputDirectory "새 미리보기 폴더"
```

미리보기는 Windows/macOS/Linux에서 로컬 HTML로 만든다. 현재 PDF 경로는 Windows의
지원하는 Edge/Chrome/Chromium을 이용한 headless 인쇄다. 다른 OS에서는 HTML만 제공한다.
브라우저 창과 결과 파일을 자동으로 표시하지 않는다.
필요하면 설치된 브라우저 실행 파일을 `-BrowserPath`로 지정한다. 브라우저가 없을 때는
HTML과 제한 경고를 반환한다. 이 기능을 위해 한컴이나 Word를 실행하지 않는다.

결과의 `Fidelity`는 `approximate`, `NativeLayoutVerified`는 `false`다. HTML/PDF를
만들었다는 사실만으로 한컴의 실제 줄바꿈·자동 쪽 번호·표 분할·인쇄 결과가 검증되었다고
보고하지 않는다. 미지원 개체와 서식 경고를 확인하고, 픽셀 수준 동일성이 필요하면
별도 한컴 호환 렌더러의 결과가 필요하다고 설명한다.

포함 이미지는 로컬 파일의 바이트로만 표시한다. 문서에 든 스크립트나 외부 URL은
실행하거나 불러오지 않는다. 원본 SHA-256을 보존하며 기존 미리보기 파일을 덮어쓰지 않는다.
