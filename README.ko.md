# herdr-pane-resurrect

[English](README.md) | **한국어**

[herdr](https://herdr.dev) 의 페인에서 돌던 프로그램을 다시 띄워주는 플러그인.
tmux 의 [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) 가 하는 일과 같다.

## 왜 필요한가

herdr 은 이미 세션을 복원한다 — 레이아웃, 페인별 디렉터리, 그리고
`[session] resume_agents_on_restore` 로 에이전트 대화까지. 복원하지 않는 것은 그 페인 **안에서 돌던**
프로그램이고, 페인은 빈 셸로 돌아온다.

| 재시작 후 | |
|---|---|
| 레이아웃: 분할·비율·탭·이름·포커스 | herdr 이 복원 |
| 페인별 디렉터리 | herdr 이 복원 |
| 에이전트 대화 | herdr 이 복원 |
| **페인에서 돌던 명령** | **유실 — 이 플러그인** |
| 스크롤백 | 유실 |

tmux-resurrect 중 herdr 에 없는 절반만 맡는다. herdr 이 이미 잘하는 것은 건드리지 않는다.

## 동작

- **save** 는 각 페인에서 돌고 있는 명령을 기록한다. 프로세스 그룹의 **리더**를 잡으므로, 파이프라인은
  조각이 아니라 실제로 입력한 한 줄로 기록된다. 다음은 일부러 뺀다.
  - 프롬프트만 떠 있는 페인 — 되살릴 게 없다.
  - 에이전트 페인 — herdr 이 직접 resume 하므로 되살리면 같은 에이전트가 두 개 뜬다.
  - **페인 안에서 띄운 대화형 셸**(`nix-shell`, `sudo -i`, 중첩 `bash`) — 이것도 결국 프롬프트이고, 그 셸을
    만든 환경은 argv 에 남지 않는다. 실행할 것을 받은 셸(`bash -c …`, `bash ./deploy.sh`)은 실제 명령이라 남긴다.
  - **인자가 `$XDG_RUNTIME_DIR`·`$TMPDIR` 안을 가리키는 명령** — 재시작하면 비워지는 곳이다. `nix-shell` 이
    남기는 모양이 정확히 이것이다. `bash --rcfile $TMPDIR/nix-shell-…/rc` 로 exec 하는데, bash 는 rcfile 이
    없어도 실패하지 않고 떠돌이 대화형 셸을 연다.

  `@resurrect-processes` 처럼 목록을 미리 적어둘 필요는 없다. 저장 시점에 실제로 돌던 것을 그대로 적는다.
- **restore** 는 기록을 원래 자리의 페인에 되돌린다. 프롬프트만 떠 있는 페인에만 쓰고, 같은 명령이 이미
  돌고 있으면 건너뛴다. 그래서 두 번 실행해도 두 번 뜨지 않는다. 읽어 온 기록에 위 save 규칙을 한 번 더
  적용하므로, 이전 버전이 저장한 스냅샷이라도 지금 버전이 기록하지 않을 것은 되살리지 않는다.
- `herdr pane run` 의 성공은 명령이 **입력됐다**는 뜻일 뿐이다. 그래서 restore 는 잠시 뒤 각 페인을 다시
  보고 실제로 돌고 있는 것만 셈한다. 곧바로 실패한 명령(스크립트가 사라진 경우 등)은 복원이 아니라
  *exited right away* 로 보고한다.
- 기록의 키는 **워크스페이스 id + 탭 번호 + 그 탭 안에서의 페인 위치**다. 워크스페이스 id 와 탭 번호는
  재시작을 넘어 유지되지만(herdr 이 `session.json` 에 저장한다) 페인 id 는 새로 매겨진다. 탭 **이름**만으로
  짝지어도 안 된다 — 이름을 안 붙인 탭의 label 은 그냥 탭 번호라, 세션 안의 이름 없는 탭이 전부 똑같아 보인다.
- 복원된 페인이 명령을 시작했던 디렉터리에 있지 않으면 앞에 `cd` 를 붙여 원래 자리에서 실행한다.
- 작은 데몬(`bin/autosave`)이 스냅샷을 최신으로 유지한다. 종료 시점에 저장하는 설계가 자연스러워 보이지만
  성립하지 않는다 — 그래픽 세션 로그아웃은 프로세스 트리를 통째로 종료시켜서, 훅이 돌 수 있는 순간이 남지
  않는다. 주기 저장이면 최악의 경우가 "마지막 틱 이후에 시작한 명령" 으로 한정된다. `flock` 으로 하나만
  돌고, `[[startup]]` 훅과 액션 양쪽에서 띄우며, herdr 서버가 멈추면 같이 종료한다.
- **데몬은 스냅샷을 절대 비우지 않는다.** 비우는 건 직접 실행한 save 뿐이다. 그러지 않으면 종료 순간이
  이길 수 없는 경쟁이 된다 — 페인의 프로세스와 데몬이 같이 죽는데, 그 사이에 틱이 걸리면 빈 세션을 보고
  정작 살아남아야 할 스냅샷을 덮어쓴다.
- **서버가 새로 뜨면, 스냅샷을 쓰기 전까지 데몬은 아무것도 저장하지 않는다.** 막 뜬 서버는 스냅샷이
  고치려는 바로 그 세션이다 — herdr 이 레이아웃만 빈 셸로 되돌려 놓았으니, 첫 틱이 그걸 찍으면 복원을
  기다리던 명령을 덮어쓴다. 실제로 그랬다: 컴포지터 크래시 뒤, restore 를 누르기도 전에 `ssh` 세 개의
  스냅샷이 떠돌이 `bash` 한 줄로 바뀌었다. 이제 `[[startup]]` 훅이 스냅샷을 보호 상태로 두고, **restore**
  를 실행하거나 **save 를 직접** 누르면(= "그건 복원하지 않겠다") 풀린다.

## 요구 사항

- herdr ≥ 0.9.0 (Linux / macOS)
- herdr 서버의 `PATH` 에 `bash`, `jq`, `flock`(util-linux)

## 설치

```sh
herdr plugin install unstable-code/herdr-pane-resurrect
```

개발용으로는 로컬 클론을 `link` 한다 — 작업트리를 그대로 쓰므로 `git pull` 이 곧 업데이트다.

```sh
git clone https://github.com/unstable-code/herdr-pane-resurrect.git
herdr plugin link ./herdr-pane-resurrect
```

그다음 `~/.config/herdr/config.toml` 에 액션 두 개를 건다. `prefix+ctrl+s` / `prefix+ctrl+r` 은
tmux-resurrect 와 같은 자리이고, herdr 기본값에서도 비어 있다.

```toml
[[keys.command]]
key = "prefix+ctrl+s"
type = "plugin_action"
command = "unstable-code.herdr-pane-resurrect.save"
description = "save pane commands"

[[keys.command]]
key = "prefix+ctrl+r"
type = "plugin_action"
command = "unstable-code.herdr-pane-resurrect.restore"
description = "restore pane commands"
```

적용은 `herdr server reload-config`(또는 설정해 둔 reload 키).

액션은 결과 요약을 herdr 알림으로 띄우고, 페인별 상세는 `herdr plugin log` 에 남는다.

## 설정

선택 사항이며, 이 플러그인의 설정 디렉터리
(`herdr plugin config-dir unstable-code.herdr-pane-resurrect`) 안 `config.toml` 에 둔다.

```toml
autosave = true   # 백그라운드 저장 데몬 사용
interval = 60     # 자동 저장 주기(초)
notify   = true   # 액션이 끝나면 알림 표시
exclude  = ""     # 저장하지 않을 명령 이름, 공백 구분: "cargo make"
verify_delay = 1.5  # restore 가 각 명령이 아직 돌고 있는지 확인하기 전 기다리는 시간(초)
```

`exclude` 는 실행 파일의 basename 과 맞춘다. 프롬프트만 떠 있는 페인은 애초에 빠지므로, 이건 "되살아나면
곤란한 것" 을 위한 것이다 — 오래 걸리고 비싼 작업이나, 시작할 때 뭔가 물어보는 명령 같은 것.

## 검증

격리된 herdr 0.9.0 서버에서 워크스페이스 셋으로 확인했다 — `alpha`(이름 붙인 탭에 페인 둘), 그리고 탭에
이름을 안 붙여 **둘 다 label 이 `1`** 인 `beta` 와 `gamma`.

| 경우 | 결과 |
|---|---|
| `sleep 500`, `bash -c 'sleep 400 \| cat'`, `/tmp` 의 `sleep 300` | 각 프로세스 그룹 리더의 argv 그대로 저장. 파이프라인은 입력한 한 줄로 기록 |
| 서버를 멈췄다 다시 띄운 뒤(모든 페인 유휴) | 셋 다 그대로 복원, `/tmp` 짜리는 `/tmp` 에서 |
| label 이 둘 다 `1` 인 탭이 서로 다른 워크스페이스에 | 각자 자기 워크스페이스로 복원 |
| restore 두 번째 실행 | `already running 3` — 중복 실행 없음 |
| 저장된 워크스페이스를 닫고 restore | 건너뜀으로 보고, 다른 곳에 실행하지 않음 |
| `bin/autosave --spawn` 을 동시에 5번 | 데몬은 정확히 하나 |
| 페인에서 명령이 끝남 | 한 주기 안에 스냅샷 갱신 |
| 서버 종료 | 데몬이 스스로 종료하고 pid 파일 정리 |
| 서버를 페인째 강제 종료 후 재기동 (플러그인 link, `[[startup]]` 훅 동작) | 스냅샷이 보호 상태가 됨. 페인에서 새 명령이 돌아도 세 틱 동안 그대로 |
| 보호 중 restore | 보호 해제, 다음 틱부터 자동 저장 재개 |
| 보호 중 save 직접 실행 | 보호 해제 |
| 페인에서 실제 `nix-shell -p hello` (리더 `bash --rcfile $TMPDIR/nix-shell-…/rc`) | 저장 안 함. 옆 페인의 `bash -c 'sleep 600 \| cat'` 은 그대로 저장 |
| 그 nix-shell 기록을 담은 이전 버전 스냅샷 | *not replayable* 로 건너뜀, 페인에 입력하지 않음 |
| 스냅샷의 `bash /nonexistent/deploy.sh` | 입력 후 즉시 실패, *exited right away* 로 보고 — `restored 1, skipped 1, failed 1` |

## 한계

- 되살리는 건 *프로그램*이지 *상태*가 아니다. `nvim file` 은 파일을 다시 열 뿐 저장 안 한 버퍼를
  되돌리지 않고, 빌드는 처음부터 다시 돈다. 스크롤백도 복원되지 않는다.
- 마지막 자동 저장 이후에 시작한 명령은 스냅샷에 없다. 그게 중요한 순간을 위해 `save` 액션이 있다.
- 셸 안에서 다시 띄운 셸에 입력한 명령은 그 안쪽 셸의 명령으로 기록된다 — 실제로 돌던 것이 그것이므로.
- 에이전트 페인은 기록하지 않는다. 그쪽은 herdr 자체의 에이전트 resume 이 담당한다.

## License

[MIT](LICENSE)
