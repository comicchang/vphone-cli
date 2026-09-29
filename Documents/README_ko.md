<div align="right"><a href="../README.md">English</a> · <a href="README_zh.md">中文</a> · <a href="README_ja.md">日本語</a> · <strong>한국어</strong></div>

# vphone-cli

Apple Silicon Mac에서 가상 iPhone을 실행합니다.

![macOS에서 실행 중인 가상 iPhone](demo.jpeg)

vphone-cli는 Apple의 Virtualization.framework와 PCC 연구용 가상 머신으로 iOS를 실행하며, 보안 연구, 리버스 엔지니어링, 디버깅에 적합합니다.

- **그래픽 창**: Mac에서 가상 iPhone의 화면을 조작하고, 앱과 파일을 탐색하며, 스크린샷을 찍고 화면을 녹화합니다.
- **커스텀 펌웨어(Custom Firmware)**: 시스템에 패치가 미리 적용되어 있어 패키지 환경을 설치할 수 있습니다.
- **백업과 복제**: 가상 머신을 내보내고, 가져오고, 복제할 수 있습니다.
- **자동화 API**: 선택적으로 사용할 수 있는 로컬 HTTP 및 WebSocket 인터페이스입니다.
- **추가 의존성 없음**: 실행에 Xcode, Python, Homebrew가 필요하지 않습니다.

> 1.x 버전은 [1.0.14 릴리스](https://github.com/Lakr233/vphone-cli/releases/tag/1.0.14)를 참고하세요. 2.x는 1.x에서 만든 가상 머신을 시작할 수 없으므로 다시 만들어야 합니다.

## 준비 사항

- macOS 15 이상을 실행하는 물리 Apple Silicon Mac. macOS 가상 머신에서는 사용할 수 없습니다.
- 충분한 디스크 공간. 가상 머신마다 기본적으로 64 GB 가상 디스크를 사용하며, 펌웨어와 임시 파일이 별도로 공간을 차지합니다.
- 네트워크 연결. 시스템을 복원할 때 서명 티켓을 온라인으로 받아야 합니다.
- 보안 설정 변경. macOS 복구 모드로 진입하여 터미널에서 다음 명령을 실행한 뒤 재시동합니다.

  ```sh
  csrutil enable --without debug
  csrutil allow-research-guests enable
  ```

  SIP는 켜진 상태로 유지되며 디버깅 제한만 완화됩니다. 이유와 다른 설정 방법은 [호스트 설정](Guides/host-setup.md)을 참고하세요.

## 빠른 시작

1. 최신 [vphone-launchpad](https://github.com/Lakr233/vphone-cli/releases/latest)(`vphone-launchpad-<버전>.zip`)를 내려받아 압축을 풀고 엽니다.
2. **Host Setup**에서 개발자 도구 권한을 부여하고 도우미 프로그램을 설치합니다.
3. **Core Bundle**에서 **Download and Install**을 클릭합니다. Launchpad가 `VPhone.bundle`을 내려받아 검증한 뒤, 그 안의 가상 머신 프로그램이 이 Mac에서 실행되도록 허용합니다.
4. **Machines**에서 **New Machine**을 클릭하고 펌웨어 조합을 선택한 뒤 **Create**를 클릭합니다.

Launchpad가 펌웨어를 내려받고, 패치를 적용하고, 시스템을 복원한 뒤 첫 부팅을 진행합니다. 완료되면 가상 머신은 계속 실행됩니다.

직접 준비한 iPhone 및 cloudOS IPSW를 사용할 수도 있습니다. 검증된 조합은 [호환성 안내](Guides/compatibility.md)를 참고하세요.

## 패키지 환경 설치

가상 머신에는 기본적으로 패키지 관리자가 없습니다. 설치 방법은 다음과 같습니다.

1. 메뉴 막대에서 **Apps > Install Bootstrap…**을 선택하고 레이아웃으로 **roothide**를 선택합니다(**rootless**는 더 이상 권장되지 않습니다). 가상 머신에 Irisin이 설치됩니다.
2. 처음 설치할 때는 Irisin에서 `apt`와 `bash`를 선택하고 설치 버튼을 길게 누른 뒤 **Bootstrap Install**을 선택합니다. `bash`와 `debianutils`는 서로 의존하므로 일반 설치로는 완료할 수 없습니다.
3. 이후에는 일반 설치를 사용하면 됩니다.

환경을 삭제하려면 **Apps > Uninstall Bootstrap…**을 선택합니다. 삭제 후 가상 머신이 재시동됩니다.

Option 키를 누른 채 **Apps** 메뉴를 열면 두 가지 항목이 더 있습니다.

- **Install Bootstrap from File…**: 로컬 Irisin `.deb`로 설치합니다.
- **Uninstall Bootstrap Without Restarting…**: 가상 머신을 재시동하지 않고 환경을 삭제합니다.

## 명령줄

Launchpad는 `VPhone.bundle` 안의 `vphone-cli`로 가상 머신을 관리하며, 터미널에서 직접 사용할 수도 있습니다.

| 작업 | 명령 |
| --- | --- |
| 가상 머신 목록 보기 | `vphone-cli vm list` |
| 가상 머신 정보 보기 | `vphone-cli vm info myphone` |
| 가상 머신 시작 | `vphone-cli vm launch myphone` |
| 가상 머신 중지 | `vphone-cli vm stop myphone` |
| 가상 머신 복제 | `vphone-cli vm clone myphone copy` |
| 가상 머신 내보내기 | `vphone-cli vm export myphone --out myphone.tzst` |
| 가상 머신 가져오기 | `vphone-cli vm import myphone.tzst --name restored` |

가상 머신은 기본적으로 `~/.vphone/`에 저장됩니다. 전체 명령은 `vphone-cli <group> --help`로 확인하세요. Launchpad 없이 가상 머신을 만드는 방법은 [생성 및 실행](Guides/create-and-run.md)을 참고하세요.

### 자동화 API

시작할 때 `--api-listen`을 추가하면 활성화됩니다.

```sh
vphone-cli vm launch myphone --api-listen 127.0.0.1:8765
# 출력에 [api] token: …이 표시됩니다
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8765/v1/health
```

시작할 때마다 새 token이 생성됩니다. 고정된 token을 사용하려면 환경 변수 `VPHONE_API_TOKEN`을 설정하세요. token이 없는 요청과 웹 페이지에서 온 요청은 모두 거부됩니다. 인터페이스 설명은 [API 문서](../Research/vphoned_http_api.md)를 참고하세요.

## 문제가 생기면

먼저 [문제 해결](Guides/troubleshooting.md)을 확인하세요. 시스템이 가상 머신 프로그램을 거부하는 경우, 복원 실패, “Press home to continue”에서 멈추는 경우 등을 다룹니다. 그래도 해결되지 않으면 [이슈를 등록](https://github.com/Lakr233/vphone-cli/issues)해 주세요.

## 문서

| 문서 | 내용 |
| --- | --- |
| [호스트 설정](Guides/host-setup.md) | SIP 및 AMFI 설정, 소스 빌드, 환경 점검 |
| [생성 및 실행](Guides/create-and-run.md) | 펌웨어 출처, 생성 절차, 저장과 백업 |
| [호환성 안내](Guides/compatibility.md) | 검증된 펌웨어 조합 |
| [문제 해결](Guides/troubleshooting.md) | 자주 발생하는 오류와 해결 방법 |
| [Launchpad 명령줄](Guides/launchpad-cli.md) | `vphone-launchpad-cli`로 로컬 빌드 설치 및 테스트 |
| [연구 기록](../Research/README.md) | 패치와 구현 세부 사항 |

## 프로젝트 구조

- `vphone-launchpad`: `VPhone.bundle`을 내려받아 설치하고 호스트를 설정하는 Mac 앱입니다. 별도로 배포됩니다.
- `vphone-cli`: 펌웨어 준비, 패치 적용, 시스템 복원, 가상 머신 관리를 담당합니다.
- `vphone-vm`: 가상 머신을 실행하고 가상 머신 창을 표시합니다.
- `vphoned`: 가상 머신 안의 제어 서비스로, 창의 기능과 API는 모두 이를 통해 동작합니다.

| 경로 | 내용 |
| --- | --- |
| [`VPhoneExecutable/`](../VPhoneExecutable/) | `vphone-cli`, `vphone-vm`, 펌웨어 패치와 복원 |
| [`VPhoneKit/`](../VPhoneKit/) | 호스트 공용 라이브러리와 API 클라이언트 |
| [`VPhoneDaemon/`](../VPhoneDaemon/) | `vphoned` |
| [`VPhoneGuestComponents/`](../VPhoneGuestComponents/) | 가상 머신 안의 hook과 도우미 프로그램 |
| [`VPhoneLaunchpad/`](../VPhoneLaunchpad/) | Launchpad 앱과 도우미 프로그램 |

소스에서 빌드하려면 `xcodebuild -workspace VPhone.xcworkspace -scheme VPhone build`를 실행합니다. 결과물은 `VPhone.bundle`입니다.

## 감사의 말

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
