# AI_CODE_MAP.md

> **[AI 에이전트 주의사항]**
>
> 이 파일은 ClipOCR-Pro 프로젝트의 구조, 공개 대상, 보안 주의사항, 핵심 로직을 빠르게 파악하기 위한 코드 지도이다.
>
> 실제 최종 기준은 소스 코드이며, 코드를 수정하기 전에는 반드시 `myAGENT.md`와 이 파일을 먼저 확인한다.
>
> 잦은 문서 변경을 줄이기 위해 정확한 라인 번호 대신 파일명, 함수명, 전역 변수명, 검색 키워드 중심으로 기록한다.

---

## 1. 프로젝트 개요

| 항목 | 내용 |
| --- | --- |
| 프로젝트명 | ClipOCR-Pro |
| 목적 | Windows 화면 영역 캡처, 플로팅 참고 이미지, 주석 표시, 선택 텍스트 번역, 이미지 번역 업무 자동화 |
| 주요 사용자 | 재무, 회계, 정산, 영업관리 등 백오피스 실무자 |
| 사용 언어 | AutoHotkey v2 |
| 실행 진입점 | `src/ClipOCR-Pro.ahk` |
| 핵심 라이브러리 | `src/Gdip_All.ahk` |
| 설정 저장 위치 | `HKCU\Software\ScreenClipTool` |
| 공개 배포 방식 | 소스는 GitHub 저장소, 실행 파일과 ZIP은 GitHub Releases 권장 |

---

## 2. 폴더 분류

| Path | 분류 | GitHub 업로드 기준 | 설명 |
| --- | --- | --- | --- |
| `src/` | 소스 코드 | 포함 | AutoHotkey v2 메인 스크립트와 GDI+ 라이브러리 |
| `assets/` | 공개 자산 | 포함 | README 이미지, 앱 아이콘, 보조 이미지 |
| `release/` | 릴리즈 산출물 | 저장소 제외 | 기존 exe/zip 보관 위치, GitHub Releases 업로드 후보 |
| `tools/` | 작업용 도구 | 저장소 제외 | GIF 제작/분석 스크립트와 작업 산출물, 일부 절대 경로 포함 |
| `.vscode/` | 개인 편집기 설정 | 저장소 제외 | 개인 로컬 설정 |
| 루트 문서 | 문서/정책 | 포함 | README, LICENSE, `myAGENT.md`, `AI_CODE_MAP.md`, `.gitignore` |

---

## 3. GitHub 공개 기준

### 공개 저장소 포함 권장

```text
.gitignore
AI_CODE_MAP.md
LICENSE
README.md
README.ko.md
myAGENT.md
src/ClipOCR-Pro.ahk
src/Gdip_All.ahk
assets/ClipOCR-Pro.ico
assets/demo.gif
assets/manual.png
assets/github_icon.png
```

| Path | 역할 | 공개 메모 |
| --- | --- | --- |
| `src/ClipOCR-Pro.ahk` | 메인 AutoHotkey v2 소스 | 주석은 영어, 변수/함수명은 기존 영어 식별자 유지 |
| `src/Gdip_All.ahk` | GDI+ 래퍼 라이브러리 | 외부 의존성으로 원본 보존 우선, 임의 번역/리팩토링 금지 |
| `assets/ClipOCR-Pro.ico` | 앱 아이콘 | 16/24/32/48/64/128/256 멀티사이즈 ICO, Ahk2Exe 실행 파일 아이콘으로 포함 |
| `assets/demo.gif` | README 데모 이미지 | 공개 전 대표 프레임에 민감정보가 없는지 확인 |
| `assets/manual.png` | README 매뉴얼 인포그래픽 | 주요 기능과 단축키를 한 장으로 요약 |
| `assets/github_icon.png` | About 화면 GitHub 아이콘 | 런타임 다운로드 대신 번들 자산으로 로드(`PrepareBundledGithubIcon`), 컴파일 시 `FileInstall`로 임베드 |

### 저장소 제외 권장

| Path | 제외 사유 | 처리 기준 |
| --- | --- | --- |
| `release/ClipOCR-Pro.exe` | 컴파일 산출물 | 저장소 대신 GitHub Releases 권장 |
| `release/ClipOCR-Pro.zip` | 배포 압축 산출물 | 저장소 대신 GitHub Releases 권장 |
| `dist/`, `build/`, `out/` | 빌드 산출물 | `.gitignore`로 제외 |
| `.vscode/` | 개인 편집기 설정 | 공개 저장소 추적 제외 |
| `tools/` | GIF 제작/분석 작업 파일 | 사용자 프로필 절대 경로가 포함되어 공개 제외 |

주의:

* `.gitignore`는 Git 클라이언트 사용 시 추적 제외에 도움을 주지만, GitHub 웹 직접 업로드에서는 자동 필터처럼 동작하지 않을 수 있다.
* 회사 PC 보안 규정 때문에 웹 업로드를 직접 수행할 경우, 포함/제외 목록을 수동으로 대조한다.

---

## 4. 실행 구조

```mermaid
graph TD
    User([사용자]) --> Main[src/ClipOCR-Pro.ahk]
    Main --> Gdip[src/Gdip_All.ahk]
    Main --> Assets[assets/ClipOCR-Pro.ico]
    Main --> Registry[HKCU Registry]
    Main --> Clipboard[Windows Clipboard]
    Main --> HTTP[Google Translate HTTP API]
    Main --> GitHubAPI[GitHub Releases API]
    Main --> Browser[Google Translate Web / Browser RPA]
    Main --> Floating[Floating Capture Windows]
    Floating --> Annotation[Annotation / Undo]
    Floating --> Menu[Context Menu]
```

기본 흐름:

1. 사용자가 단축키 또는 메뉴로 캡처, 번역, 정렬, 저장 작업을 실행한다.
2. `src/ClipOCR-Pro.ahk`가 화면 좌표, 클립보드, Registry, GUI 상태를 관리한다.
3. 화면 캡처와 이미지 처리는 `src/Gdip_All.ahk`의 GDI+ helper를 사용한다.
4. 소스 실행 시 아이콘은 `assets/ClipOCR-Pro.ico`를 참조한다.
5. 컴파일 실행 시 트레이 아이콘은 exe 내장 아이콘을 우선 사용한다.
6. 텍스트 번역은 Google Translate HTTP endpoint를 호출한다.
7. 이미지 번역은 브라우저를 열고 클립보드 이미지를 붙여넣는 RPA 방식으로 처리한다.

---

## 5. 핵심 파일과 기능 위치

| 기능 | 파일 | 주요 함수 / 검색 키워드 | 주의사항 |
| --- | --- | --- | --- |
| 화면 영역 캡처 | `src/ClipOCR-Pro.ahk` | `ScreenClip2Win`, `SelectArea` | DPI와 멀티 모니터 좌표계 유지 |
| 플로팅 캡처 창 | `src/ClipOCR-Pro.ahk` | `CreateClipWin`, `ClipWins` | 창 상태는 `HWND` 기반 `Map`에 저장 |
| 클립보드 이미지 출력 | `src/ClipOCR-Pro.ahk` | `CopyBitmapToClipboard`, `CreateOutputBitmap`, `GetEstimatedJpegSize` | 선택한 고정 가로폭으로 확대/축소, 선택적 아웃라인, CF_DIB 호환성 유지 |
| JPG 파일 저장 | `src/ClipOCR-Pro.ahk` | `SaveBitmapToDesktop`, `SaveJpegBitmapToFile`, `GetUniqueFilePath`, `GetSaveFolder`, `SetSaveFolder` | 가로폭/아웃라인 적용, 품질 85, 저장 위치는 `SaveFolder` 설정(미설정 시 Desktop), 같은 초 파일명 충돌 시 `_2`,`_3` 접미사로 덮어쓰기 방지 |
| 번역 개인정보 동의 | `src/ClipOCR-Pro.ahk` | `EnsureTranslationConsent`, `TranslateConsent` | 텍스트/이미지 번역 최초 실행 전 1회 경고, 동의는 Registry에 저장 |
| UI 문자열 다국어화 | `src/ClipOCR-Pro.ahk` | `UIText`, `BuildUIStringTable`, `GetUILang`, `GetDefaultUILang` | 핵심 툴팁만 `MANUAL_LANG` 기준 6개 언어 지원(점진 적용), 미번역 키는 영어 fallback, `{name}` 플레이스홀더 치환 |
| Outlook 웹메일 용량 추정 | `src/ClipOCR-Pro.ahk` | `EstimateOutlookWebMailSize`, `IsSupportedOutlookWebMailHost`, `CalculateOutlookWebMailBytes` | `Ctrl+Win+0`, 첨부 제외, 영어 툴팁, 보수적 MB 추정 |
| 주석 그리기 | `src/ClipOCR-Pro.ahk` | `SCW_ApplyAnnotation`, `WM_LBUTTONDOWN`, `DrawRectPreview`, `DrawVectorPreview` | 모드: Red/Yellow/Green(드래그), Text/Number(클릭), Arrow(드래그·방향), Mosaic(드래그·픽셀화). Number는 `ClipWins[hwnd].AnnotSeq` 증가, Arrow/Number/Mosaic는 우클릭 메뉴로만 시작. UndoStack과 GDI+ 포인터 해제 필요 |
| Undo | `src/ClipOCR-Pro.ahk` | `SCW_Undo` | 버려지는 비트맵 포인터 해제 필요 |
| 선택 텍스트 번역 | `src/ClipOCR-Pro.ahk` | `TranslateSelectedText`, `TranslateTextViaGoogle` | 외부 번역 서비스 전송 주의, 최초 실행 시 `EnsureTranslationConsent` 동의 게이트 |
| 번역 응답 파싱 | `src/ClipOCR-Pro.ahk` | `ParseGoogleTranslateResponse` | Google 응답 구조 변경 가능성 있음 |
| 번역 팝업 | `src/ClipOCR-Pro.ahk` | `ShowTextTranslationPopup`, `GetPopupPositionNearMouse` | AlwaysOnTop 및 화면 밖 표시 주의 |
| 이미지 번역 | `src/ClipOCR-Pro.ahk` | `GoogleImageTranslate`, `AutoPasteToGoogleTranslate` | 브라우저 포커스와 웹 UI 변경에 취약 |
| 설정창 | `src/ClipOCR-Pro.ahk` | `ShowDashboardDialog`, `SaveDashboardSettings`, `GetCenteredPositionOnMouseMonitor` | Registry 호환성 유지, 커서가 있는 모니터 작업 영역 중앙에 표시 |
| GitHub 업데이트 확인 | `src/ClipOCR-Pro.ahk` | `StartGithubUpdateCheck`, `PollGithubUpdateCheck`, `ParseGithubLatestRelease`, `CompareSemanticVersions` | About 탭에서 비동기 확인, 새 버전이 있을 때만 릴리즈 페이지 버튼 활성화 |
| 매뉴얼 창 | `src/ClipOCR-Pro.ahk` | `ShowManualDialog`, `GetManualText`, `GetCenteredPositionOnMouseMonitor` | 커서가 있는 모니터 작업 영역 중앙에 표시, 다국어 텍스트 문자열은 기능 문구이므로 주석 정책과 별개 |
| GDI+ helper | `src/Gdip_All.ahk` | `Gdip_Startup`, `Gdip_BitmapFromScreen`, `Gdip_DisposeImage` | 외부 라이브러리 원본성 유지 |

---

## 6. 전역 변수와 설정

| 이름 | 용도 | 주의사항 |
| --- | --- | --- |
| `APP_NAME`, `APP_VERSION` | 앱 표시명과 버전 | 현재 `1.3.0`; EXE 파일 버전은 `1.3.0.0`, README/릴리즈 표기와 맞춰 관리 |
| `APP_ICON_PATH` | 실행 중 사용할 아이콘 경로 | 컴파일 실행 시 `A_ScriptFullPath`, 소스 실행 시 `src/../assets/ClipOCR-Pro.ico` |
| `APP_SOURCE_ICON_PATH` | 소스 실행 fallback 아이콘 경로 | `assets/ClipOCR-Pro.ico` 이동 시 함께 수정 필요 |
| `REG_PATH` | 사용자 설정 Registry 경로 | 기존 사용자 설정 호환성을 위해 변경 금지 |
| `CLIP_WIDTH` | 클립보드 복사/JPG 저장 목표 가로폭 | `0`은 Original Size, 나머지 400~1600px는 원본 크기와 관계없이 선택 폭으로 확대/축소 |
| `COPY_OUTLINE_ENABLED` | 복사/JPG 저장 이미지의 1px 검정 아웃라인 여부 | 설정창의 체크박스와 연동 |
| `WINDOW_BORDER_WIDTH` | 플로팅 캡처 창 외곽선 굵기 | 1px 검정, 출력 이미지 아웃라인과 별개 |
| `ANNOTATION_BORDER_WIDTH` | 빨간 주석 박스 굵기 | 3px 유지, 창 외곽선 변경의 영향을 받지 않음 |
| `JPG_QUALITY` | JPG 저장과 예상 용량 계산 품질 | 85 고정 |
| `MAIL_COPY_TIMEOUT_SECONDS` | Outlook 본문 복사 대기 시간 | 3초 |
| `MAIL_SUBJECT_ALLOWANCE_BYTES` | 제목 추정 여유분 | 8KB |
| `MAIL_HEADER_ALLOWANCE_BYTES` | Outlook/MIME 헤더 추정 여유분 | 64KB |
| `MAIL_ENCODING_FACTOR` | 전송 인코딩 보수 계수 | 1.37 |
| `TEXT_TRANSLATE_LANG` | 선택 텍스트 번역 기본 언어 | `TranslateLang` Registry value 사용 |
| `TEXT_TRANSLATE_HOTKEY` | 선택 텍스트 번역 단축키 | `Win+CapsLock`은 정적 기본 단축키로 유지 |
| `TEXT_TRANSLATE_FONT_SIZE` | 번역 팝업 글자 크기 | 실사용 범위로 정규화 |
| `IMAGE_TRANSLATE_LANGS` | 이미지 번역 메뉴 언어 목록 | 콤마 구분 문자열로 저장 |
| `MANUAL_LANG` | 매뉴얼 다이얼로그 및 핵심 툴팁 UI 언어 | `ManualLang` Registry value 사용, 미설정 시 `GetDefaultUILang()`로 시스템 로캘 기반 기본값 |
| `TRANSLATE_CONSENT` | 외부 번역 서비스 전송 최초 동의 여부 | `TranslateConsent` Registry value(`1`) 사용, 미동의 시 번역 진입점에서 취소 |
| `ClipWins` | 플로팅 캡처 창 상태 저장 | Key는 `HWND`, Value는 상태 object |
| `RightClickedHwnd` | 우클릭 메뉴 대상 창 | 메뉴 핸들러에서 대상 확인 |
| `TextTranslatePopupHwnd` | 현재 번역 팝업 HWND | 새 팝업 표시 전 기존 팝업 정리 |
| `DashboardHwnd`, `ManualHwnd` | 설정창/매뉴얼 창 중복 방지 | 창 종료 시 0으로 복구 |
| `TEMP_FILES` | 앱이 생성한 임시 파일 목록 | 종료 시 앱 소유 파일만 삭제 |
| `MAIL_SIZE_CHECK_RUNNING` | 메일 용량 추정 중복 실행 방지 | 모든 성공/실패 경로에서 `false`로 복구 |
| `GITHUB_RELEASES_URL`, `GITHUB_LATEST_RELEASE_API` | 업데이트 페이지와 최신 릴리즈 API 주소 | 공식 저장소 `KwangBeomPark/ClipOCR-Pro`만 사용 |
| `UPDATE_CHECK_STATE` | 비동기 GitHub 확인 요청과 About UI 상태 | 요청 객체, 타임아웃, 최신 버전, 버튼 컨트롤을 보관하고 설정창 종료 시 분리 |
| `ENABLE_BMC_AUTO_DOWNLOAD` | 후원 버튼 이미지 자동 다운로드 제어 | 현재 `false`(기본 OFF); About 화면 BMC 이미지 로드도 이 플래그로 게이트하여 기본 구성에서 외부 다운로드/임시 이미지 로드 없음 |
| `APP_TEMP_DIR` | 앱 전용 임시 폴더 경로 | `A_Temp\ClipOCR-Pro`; 다운로드/추출 자산과 용량 추정 임시 파일 보관 |
| `SAVE_FOLDER` | Ctrl+S JPG 저장 위치 | `SaveFolder` Registry value 사용, 빈 값이면 Desktop(하위호환), 설정창 General 탭 Browse로 변경 |

출력 관련 Registry value:

| Value name | 의미 | 기본값 / 호환성 |
| --- | --- | --- |
| `ClipboardWidth` | 클립보드/JPG 출력 목표 가로폭 | `1000`; 허용값 `0`(Original Size), 400, 600, 800, 1000, 1200, 1400, 1600 |
| `CopyOutline` | 출력 이미지 1px 검정 아웃라인 | `1`; `0`은 비활성 |
| `Scale` | 과거 퍼센트 스케일 설정 | 삭제하지 않지만 신규 출력 로직에서는 사용하지 않음 |
| `ManualLang` | 매뉴얼 다이얼로그 언어 | `en`; 허용값: `ko`, `en`, `pl`, `de`, `fr`, `es` |
| `TranslateConsent` | 외부 번역 전송 최초 동의 플래그 | 미설정이 기본(미동의); `1`이면 동의 완료로 경고 생략 |
| `SaveFolder` | Ctrl+S JPG 저장 폴더 | 빈 값이 기본(Desktop); 존재하지 않는 경로는 로드 시 무시하고 Desktop으로 대체 |

Windows 시작 실행은 설정 저장 시 사용자 Startup 폴더의 `ClipOCR-Pro.lnk` 바로가기로 관리한다. 기존 버전의 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\ScreenClipTool` 값은 legacy 상태로 인식하되, 새 설정을 저장할 때 제거한다.

플로팅 창 전용 출력 단축키 `Ctrl+0`은 Original Size를 선택하고 현재 이미지를 즉시 복사한다. `Ctrl+1`~`Ctrl+7`은 각각 400~1600px를 선택해 같은 방식으로 복사한다. 이 단축키들은 플로팅 캡처 창이 활성화된 경우에만 동작한다. `Ctrl+C`는 현재 설정으로 복사하고, `Ctrl+S`는 같은 설정으로 JPG를 저장한다. 별도의 전역 `Ctrl+Win+0`은 Outlook 작성 본문을 복사해 첨부 제외 보수적 용량을 영어 툴팁으로 표시한다.

`ClipWins[hwnd]` 주요 상태 key:

| Key | 의미 |
| --- | --- |
| `pBitmap` | 캡처 이미지 GDI+ 비트맵 포인터 |
| `w`, `h` | 원본 이미지 크기 |
| `gui`, `picCtrl` | AHK GUI와 이미지 컨트롤 |
| `IsMinimized`, `id`, `NumText`, `NumBg` | 미니 모드 표시 상태 |
| `UndoStack` | 주석 Undo용 비트맵 포인터 스택 |
| `AnnotSeq` | 번호 핀(Number) 다음 표시 숫자(1부터 증가, Undo 시 감소하지 않음) |
| `orgX`, `orgY` | 최소화 전 위치 |

---

## 7. 빌드 / 릴리즈 기준

개발 실행:

```powershell
& "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" .\src\ClipOCR-Pro.ahk
```

컴파일 예시:

```powershell
& "C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe" /in .\src\ClipOCR-Pro.ahk /out .\release\ClipOCR-Pro.exe /icon .\assets\ClipOCR-Pro.ico /base "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
```

릴리즈 기준:

* `release/`는 로컬 산출물 보관 위치이며 저장소 업로드 대상이 아니다.
* GitHub Releases에 업로드할 exe/zip은 빌드 후 해시와 아이콘, 실행 여부를 별도로 확인한다.
* 기존 `release/ClipOCR-Pro.exe`와 `release/ClipOCR-Pro.zip`은 루트에서 이동한 기존 산출물이며, 새 아이콘 반영 여부는 재컴파일 전까지 보장하지 않는다.

---

## 8. 외부 링크와 네트워크 동작

| 위치 | URL / 동작 | 공개/보안 메모 |
| --- | --- | --- |
| README | GitHub Releases 링크 | 공개 저장소 주소로 유지 |
| README | Buy Me a Coffee 링크 | 사용자가 공개 유지 선택 |
| About 화면 | GitHub profile 링크 | 사용자가 공개 유지 선택 |
| About 화면 | Buy Me a Coffee 링크 | 사용자가 공개 유지 선택 |
| About 화면 | `api.github.com/repos/KwangBeomPark/ClipOCR-Pro/releases/latest` | 탭 최초 진입 또는 `Check Again` 시 최신 공개 릴리즈 메타데이터만 조회 |
| About 화면 | `github.com/KwangBeomPark/ClipOCR-Pro/releases/...` | 원격 버전이 더 높을 때만 `View Update` 버튼을 활성화하며 브라우저로 페이지를 열고 다운로드/설치는 하지 않음 |
| (제거됨) | ~~Google favicon 다운로드~~ | 런타임 외부 다운로드를 제거하고 번들 `assets/github_icon.png`를 로드하도록 변경 |
| 앱 실행 중 | BMC 버튼 다운로드 | 기본 OFF(`ENABLE_BMC_AUTO_DOWNLOAD := false`); 활성화 시에만 다운로드하며 미활성 시 텍스트 링크 표시 |
| 텍스트 번역 | `translate.googleapis.com` | 선택 텍스트가 외부 서비스로 전송될 수 있음 |
| 이미지 번역 | `translate.google.com` | 캡처 이미지가 외부 서비스로 전송될 수 있음 |

민감한 회사 문서, 개인정보, 비밀번호, API key, 계좌/카드 정보, 내부 시스템 화면은 번역 기능 사용 전에 사용자가 직접 확인해야 한다.

---

## 9. 보안 점검 결과와 공개 전 체크리스트

현재 점검 기준:

* 텍스트 파일 대상: `.ahk`, `.md`, `.py`, `.html`, `.txt`, `.json`, `.gitignore`
* 검색 패턴: 사용자 프로필 절대 경로, 로컬 file URL, 네트워크 공유 경로, `password`, `token`, `secret`, `api_key`, `authorization`, `bearer`, private key, 개인정보 키워드
* 이미지 대상: `assets/demo.gif`, `assets/manual.png`, `assets/github_icon.png`, `tools/Manual1.png`, `tools/*.gif` 대표 프레임과 메타데이터

확인된 사항:

* `tools/` 하위 Python 작업 파일에는 사용자 프로필 절대 경로가 하드코딩되어 있으므로 공개 저장소에서 제외한다.
* `release/` 하위 exe/zip은 컴파일/배포 산출물이므로 저장소가 아니라 GitHub Releases 업로드 대상으로 분리한다.
* README와 About 화면의 GitHub/후원 링크, `LICENSE` 저작권 표기는 사용자가 공개 유지하기로 결정했다.
* `README.md`와 `README.ko.md`는 현재 `assets/demo.gif`와 `assets/manual.png`를 참조한다.
* `assets/ClipOCR-Pro.ico`는 멀티사이즈 ICO로 관리한다.

---

## 10. 변경 시 주의사항

* `REG_PATH`와 Registry value name은 기존 사용자 설정 호환성 때문에 변경하지 않는다.
* AutoHotkey v2 문법만 사용하고 v1 문법을 섞지 않는다.
* `src/Gdip_All.ahk`는 외부 라이브러리로 보고 원본성, 라이선스, 호환성을 우선한다.
* `pBitmap`, `pGraphics`, `pPen`, `pBrush`, `hBitmap` 등 GDI+ 리소스는 생성 후 해제 경로를 확인한다.
* 클립보드 전달 형식은 PNG/JPG 파일이 아니라 Windows `CF_DIB` 비트맵이다. JPG 품질 85는 Desktop 저장과 툴팁 용량 추정에만 적용한다.
* 예상 용량 계산용 임시 JPG는 `%TEMP%\ClipOCR-Pro\jpeg_estimate_*.jpg`에 생성되며 함수 종료 전에 삭제되어야 한다.
* Outlook 용량 추정은 Edge/Chrome의 Outlook 제목 창, `olk.exe`/`OUTLOOK.EXE`, 또는 Outlook 제목을 가진 `msedgewebview2.exe` 포커스 조합만 허용한다. 다른 WebView2 호스트는 거부한다.
* 메일 용량 값은 `ClipboardAll.Size`에 제목 8KB, 헤더 64KB, 인코딩 계수 1.37을 적용한 추정치이며 첨부파일과 실제 서버 저장 크기를 포함하지 않는다.
* GitHub 업데이트 확인은 15초 타임아웃의 비동기 WinHTTP 요청으로 수행한다. 태그가 버전 형식이 아니면 릴리즈명과 자산명에서 semantic version을 보수적으로 찾고, 신뢰된 공식 릴리즈 URL만 열어야 한다.
* 업데이트 확인 실패는 앱 시작과 설정 저장을 막지 않으며, 자동 다운로드·자동 설치·실행 파일 교체는 수행하지 않는다.
* 클립보드 백업/복구 실패는 사용자 데이터 손상으로 이어질 수 있으므로 안전 fallback을 유지한다.
* AlwaysOnTop 캡처 창은 InputBox, MsgBox, 브라우저 RPA, 설정창과 Z-order 충돌이 날 수 있다.
* Google Translate API와 Web UI는 외부 서비스라 응답 구조, 타이틀, 붙여넣기 동작이 바뀔 수 있다.
* 주석은 영어로 작성하되, 사용자에게 보여주는 UI 문구와 매뉴얼 본문은 다국어 문자열을 유지할 수 있다.

---

## 11. 멀티모니터 / DPI 수동 테스트 체크리스트

좌표·창 위치·캡처 로직은 자동 테스트로 회귀를 잡기 어렵다. 캡처, 정렬, 다이얼로그 위치 관련 코드를 수정한 뒤에는 아래 항목을 수동으로 점검한다.

전제:

* 앱은 `SetThreadDpiAwarenessContext(-4)`(Per-Monitor DPI Aware V2)로 물리 픽셀 좌표를 사용한다.
* 가능하면 배율이 서로 다른 2대 이상 모니터, 세로 모니터, 보조 모니터가 주 모니터 왼쪽/위(음수 좌표)에 있는 배치를 포함한다.

| # | 환경 | 확인 항목 | 기대 결과 |
| --- | --- | --- | --- |
| T1 | 100% + 150% 혼합 DPI 2모니터 | 각 모니터에서 `Win+드래그` 캡처 | 선택한 영역과 실제 캡처 이미지의 범위·비율이 일치 |
| T2 | 보조 모니터가 주 모니터 왼쪽/위(음수 좌표) | 보조 모니터에서 캡처 및 플로팅 창 생성 | 창이 지정 좌표에 정확히 뜨고 잘리지 않음 |
| T3 | 2모니터 이상 | `Ctrl+←` 전체 정렬 반복 | 정렬 대상 모니터를 순환하며 각 모니터 작업영역 기준으로 계단식 배치 |
| T4 | 커서를 각 모니터에 둔 상태 | 설정창·매뉴얼·번역 팝업 열기 | 커서가 있는 모니터 작업영역 중앙에 표시, 화면 밖으로 넘치지 않음 |
| T5 | 200% 배율 / 세로 모니터 | 플로팅 창 더블클릭 미니모드, 숫자/배경 표시 | 미니 크기·숫자 위치·투명도가 정상, 복원 시 원위치 |
| T6 | 작업표시줄이 있는 모니터 | 저장/복사 툴팁, 시작 안내 툴팁 | 툴팁이 화면 안에서 정상 표시 |

회귀가 확인되면 관련 함수(`SelectArea`, `CreateClipWin`, `SCW_SortCascade`, `GetCenteredPositionOnMouseMonitor`, `GetPopupPositionNearMouse`)의 좌표 계산과 DPI 컨텍스트를 우선 검토한다.

---

## 12. 변경 이력

| Date | Change | Updated By |
| --- | --- | --- |
| 2026-06-14 | 루트 파일을 `src/`, `assets/`, `release/`로 분류하고 경로/문서 갱신 | AI Agent |
| 2026-06-14 | `ClipOCR-Pro.ico` 멀티사이즈 재생성, 컴파일된 exe 내장 아이콘 우선 사용 로직 반영 | AI Agent |
| 2026-06-14 | `manual.png` 공개용 매뉴얼 인포그래픽 생성 및 README 참조 반영 | AI Agent |
| 2026-06-14 | GitHub 소스 중심 공개 기준, 제외 파일, 보안 점검 결과, 영어 주석/식별자 원칙 반영 | AI Agent |
| 2026-06-22 | 플로팅 창 1px 검정 외곽선, 400~1600px 출력 단축키, 선택적 아웃라인, JPG 품질 85 저장과 용량 툴팁 반영 | AI Agent |
| 2026-06-22 | 앱 표시 버전을 1.2.1, 컴파일 EXE 파일 버전을 1.2.1.0으로 갱신 | AI Agent |
| 2026-06-22 | Ctrl+Win+0 Outlook 웹메일 용량 추정, WebView2 감지, 영어 툴팁, 선택 가로폭 강제 확대/축소 반영 | AI Agent |
| 2026-06-22 | 앱 버전 1.2.2, Original Size와 플로팅 전용 Ctrl+0, About 탭 GitHub 최신 릴리즈 확인 및 웹페이지 열기 반영 | AI Agent |
| 2026-06-22 | 설정창과 매뉴얼 창을 커서가 있는 모니터 중앙에 배치하고 열린 매뉴얼 재호출 시 현재 모니터로 이동하도록 수정 | AI Agent |
| 2026-06-30 | 번역 팝업창 및 매뉴얼 다이얼로그의 마지막 선택 언어 저장 및 유지 기능 추가 | AI Agent |
| 2026-06-30 | 앱 버전 1.2.3, Windows 시작 실행을 Startup 폴더 바로가기 방식으로 변경하고 legacy Run Registry 값을 정리하도록 수정 | AI Agent |
| 2026-07-08 | 텍스트/이미지 번역 최초 실행 전 개인정보 동의 게이트(`EnsureTranslationConsent`, `TranslateConsent`) 추가, Desktop JPG 저장 파일명 충돌 시 `_2`,`_3` 접미사로 덮어쓰기 방지(`GetUniqueFilePath`) | AI Agent |
| 2026-07-08 | 코드 품질 개선: `ScreenClip2Win` 캡처 실패 시 null 비트맵 가드 추가, 마우스 메시지 핸들러(`OnMessage`)를 창 생성마다 재등록하던 것을 시작 시 1회 등록으로 이동, 미사용 `temp_clip.png` 정리 코드 및 `.gitignore` 항목 제거, 텍스트 번역 WinHTTP 타임아웃을 프록시/저속망 대응으로 상향(5s/5s/5s/15s) | AI Agent |
| 2026-07-08 | 핵심 런타임 툴팁(시작 안내, 캡처 실패, 클립보드 복사, Desktop 저장, 번역 진행/실패)을 `UIText`/`BuildUIStringTable` 기반 6개 언어로 다국어화(점진 1차), `MANUAL_LANG`을 UI 언어로 겸용하고 미설정 시 시스템 로캘 기반 기본값 적용 | AI Agent |
| 2026-07-08 | 보안/회사망 개선: GitHub 아이콘을 런타임 favicon 다운로드에서 번들 자산 로드(`PrepareBundledGithubIcon`, 컴파일 시 `FileInstall` 임베드)로 전환, BMC 자동 다운로드 기본 OFF 및 About 이미지 로드도 플래그로 게이트, 앱 임시 파일을 전용 폴더(`APP_TEMP_DIR`)로 통일 → 기본 구성에서 외부 이미지 다운로드/임시 이미지 로드 제거 | AI Agent |
| 2026-07-08 | C1 저장 위치 선택 기능: `SaveFolder` 설정과 `GetSaveFolder`/`SetSaveFolder` 추가, 설정창 General 탭에 "Save to File" 폴더 선택(Browse) UI 추가, `SaveBitmapToDesktop`이 설정 폴더에 저장(미설정 시 Desktop), 저장 실패 툴팁 문구를 파일 저장 일반 표현으로 변경 | AI Agent |
| 2026-07-08 | C7 멀티모니터/DPI 수동 테스트 체크리스트 섹션 추가(문서 전용), 기존 변경 이력 섹션 번호 12로 조정 | AI Agent |
| 2026-07-08 | C5 주석 도구 확장: 화살표(방향 있는 드래그+화살촉), 번호 핀(클릭, `AnnotSeq` 자동 증가), 모자이크(드래그 영역 픽셀화로 민감정보 가리기) 추가. `DrawVectorPreview` 헬퍼, 우클릭 메뉴 항목/번호 재정렬(2~18), `MenuHandler`·`StartAnnotationMode`·`SCW_ApplyAnnotation` 확장. 매뉴얼 본문 다국어 반영은 후속(B1) 예정 | AI Agent |
| 2026-07-10 | 앱 버전 1.3.0(EXE 1.3.0.0)으로 상향. 우클릭 메뉴 11번 라벨을 "Save to Desktop"에서 "Save to File"로 변경(`MenuHandler` 매칭 문자열 포함). README(en/ko)에 신규 주석 도구 3종, Ctrl+S 저장 폴더, 설정 저장 항목, 보안 개선(번역 동의·외부 다운로드 제거·모자이크) 반영. 앱 내 매뉴얼(`GetManualText`)은 ko/en만 갱신(주석 도구, 저장 폴더, 번역 동의) — pl/de/fr/es 본문 갱신은 사용자 결정으로 보류 | AI Agent |
