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
| 에이전트 대화 | herdr 이 복원 — 에이전트가 세션 id 를 보고한 경우에만. Claude 페인은 그 보고 없이도 이 플러그인이 복원(아래 참조) |
| **페인에서 돌던 명령** | **유실 — 이 플러그인** |
| 스크롤백 | 유실 |

tmux-resurrect 중 herdr 에 없는 절반만 맡는다. herdr 이 이미 잘하는 것은 건드리지 않는다.

## 동작

- **save** 는 각 페인에서 돌고 있는 명령을 기록한다. 프로세스 그룹의 **리더**를 잡으므로, 파이프라인은
  조각이 아니라 실제로 입력한 한 줄로 기록된다. nix 래퍼를 거쳐 실행된 명령도 입력한 모양으로
  기록한다. 래퍼는 자기 플래그를 붙여 같은 프로세스에서 진짜 프로그램으로 exec 하므로, argv 에 아무도 치지
  않은 플래그(`mpv --script=…/mpris.so …`)나 래핑 전 프로그램의 store 경로가 남는다. 그대로 되살리면 래퍼를
  다시 거쳐 복원할 때마다 한 벌씩 늘었다. 래퍼의 플래그와 정확히 같은 부분만 떼고 입력한 이름을 되돌리며,
  restore 도 떠 있는 명령을 같은 방식으로 비교하므로 "이미 실행 중" 판정은 그대로 맞는다. 모양이 다른
  래퍼나 셸 확장이 든 플래그면 argv 를 그대로 둔다. 업데이트 전 래퍼가 붙인 플래그(옛 store 경로)도 지금
  래퍼와 같지 않으므로 그대로 남는다. 다음은 일부러 뺀다.
  - 프롬프트만 떠 있는 페인 — 되살릴 게 없다.
  - Claude 를 뺀 에이전트 페인 — herdr 이 직접 resume 하므로 되살리면 같은 에이전트가 두 개 뜬다.
  - **페인 안에서 띄운 대화형 셸**(`nix-shell`, `sudo -i`, 중첩 `bash`) — 이것도 결국 프롬프트이고, 그 셸을
    만든 환경은 argv 에 남지 않는다. 실행할 것을 받은 셸(`bash -c …`, `bash ./deploy.sh`)은 실제 명령이라 남긴다.
  - **인자가 `$XDG_RUNTIME_DIR`·`$TMPDIR` 안을 가리키는 명령** — 재시작하면 비워지는 곳이다. `nix-shell` 이
    남기는 모양이 정확히 이것이다. `bash --rcfile $TMPDIR/nix-shell-…/rc` 로 exec 하는데, bash 는 rcfile 이
    없어도 실패하지 않고 떠돌이 대화형 셸을 연다.

  `@resurrect-processes` 처럼 목록을 미리 적어둘 필요는 없다. 저장 시점에 실제로 돌던 것을 그대로 적는다.
- **restore** 는 기록을 원래 자리의 페인에 되돌린다. 프롬프트만 떠 있는 페인에만 쓰고, 같은 명령이 이미
  돌고 있으면 건너뛴다. 그래서 두 번 실행해도 두 번 뜨지 않는다. 읽어 온 기록에 위 save 규칙을 한 번 더
  적용하므로, 이전 버전이 저장한 스냅샷이라도 지금 버전이 기록하지 않을 것은 되살리지 않는다.
- **되살린 명령은 셸 히스토리에 남기지 않는다.** restore 는 명령을 타이핑해서 되살리므로, 그대로 두면 복원한
  세션의 히스토리가 내가 친 적 없는 줄로 채워진다. 그중 최악은 `claude --resume <uuid>` 다 — 그 id 는 누구도
  검색할 일 없는 잡음이다. 그래서 명령 앞에 공백 한 칸을 붙여 입력하고, zsh(`HIST_IGNORE_SPACE`)와
  bash(`HISTCONTROL=ignorespace`)가 그 줄을 히스토리에서 뺀다. 그 옵션이 없는 셸에서는 예전처럼 기록될
  뿐이라, 효과가 없는 곳에서 손해도 없다.
- `herdr pane run` 의 성공은 명령이 **입력됐다**는 뜻일 뿐이다. 그래서 restore 는 잠시 뒤 각 페인을 다시
  보고 실제로 돌고 있는 것만 셈한다. 곧바로 실패한 명령(스크립트가 사라진 경우 등)은 복원이 아니라
  *exited right away* 로 보고한다.
- **Claude 페인은 자기 대화로 돌아온다.** herdr 도 에이전트를 직접 resume 할 수 있지만, 에이전트가 세션 id 를
  보고한 뒤에만 가능하다. Claude 의 보고는 Claude Code 훅이 하는데 이 훅은 `python3` 가 필요하고, 없으면
  조용히 아무것도 하지 않는다. 그런 기기에서는 herdr 가 Claude 페인을 하나도 되살리지 못한다. 한편
  Claude Code 는 실행 중인 프로세스마다 `~/.claude/sessions/<pid>.json`(또는 `$CLAUDE_CONFIG_DIR` 아래)에
  세션 id 를 남긴다. save 가 이걸 읽어 그 페인을 `claude --resume <id>` 로 기록한다. 페인을 무엇으로
  시작했든 상관없다(목록에서 고르는 `claude -r` 은 argv 에 id 를 남기지 않는다).
  - `--continue` 가 아니라 `--resume <id>` 다. `--continue` 는 그 디렉터리의 가장 최근 대화를 열어서, 같은
    저장소의 Claude 페인 두 개가 같은 대화로 돌아온다.
  - 이 파일은 인터페이스가 아니라 Claude Code 내부 파일이다. 그래서 모든 단계가 안전한 쪽으로 실패한다. 파일이
    없거나, 형식이 다르거나, 같은 pid 를 쓰던 이전 프로세스가 남긴 파일이면(`procStart` 가 커널의 시작 시각과
    같아야 한다) 그 페인은 예전처럼 빠진다.
  - restore 는 이미 어디서든 열려 있는 대화를 건너뛴다. 손으로 다시 열었든, 목록에서 골랐든, herdr 자체
    resume 이 되는 기기에서 herdr 가 열었든 마찬가지다. 판정은 argv 가 아니라 세션 id 로 한다.
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
- **herdr 세션마다 상태를 따로 둔다.** herdr 는 플러그인 상태 디렉터리를 플러그인 id 하나로만 정해서, 기본
  세션과 모든 `herdr --session <이름>` 이 같은 디렉터리를 쓴다. 그래서 named session 이 뜨기만 해도 기본
  세션의 스냅샷이 보호 상태가 됐고, 자동 저장 데몬·스냅샷·에이전트 순서도 한 벌을 나눠 썼다. 세션은 명령이
  서버에 닿는 소켓으로 가른다 — named session 은 `<config>/sessions/<이름>/herdr.sock` 이고, 그 상태는
  플러그인 상태 디렉터리 아래 `sessions/<이름>/` 에 둔다. 기본 세션은 디렉터리를 그대로 써서 업데이트 전의
  스냅샷을 이어 받는다. `HERDR_SOCKET_PATH` 로 다른 곳에 둔 소켓은 기본 세션으로 친다.

### 에이전트 순서 (선택)

herdr 의 에이전트 사이드바 `priority` 정렬은 attention(blocked, done, working, idle) 순으로 세우고, 같은
등급 안에서는 가장 최근 상태 변경이 위로 온다. 이 두 번째 기준은 서버 메모리의 카운터라 저장되지 않는다.
그래서 재시작하면 에이전트가 다시 감지된 순서대로 줄을 선다. `agent_order = true` 로 켜면 순서를 지킨다.

- `pane.agent_status_changed` 가 올 때마다 그 시각을 페인 토큰 `$resurrect_order` 로 보고하고, 모든
  페인의 토큰을 명령 스냅샷과 같은 키로 저장한다.
- Agent view(`agent.view.set`)를 걸어 attention 다음에 그 토큰으로 정렬한다. `priority` 와 같은 규칙이고,
  동점 처리 기준만 재시작을 견디는 값으로 바꾼 것이다. 서버가 끝나면 herdr 가 view 와 토큰을 버리므로,
  `[[startup]]` 훅이 저장된 토큰을 다시 보고하고 view 를 다시 건다.
- **작업·blocked·턴 종료만 기록하고, idle 은 기록하지 않는다.** 재시작 직후에는 모든 에이전트가 herdr
  가 찾는 순서대로 다시 idle 로 감지되고, 저장된 자리가 없는 에이전트는 이번 세션에 새로 뜬 것과 구분할 수
  없다 — 그걸 기록하면 감지 순서로 되돌아간다. 자리가 없는 에이전트는 첫 프롬프트 전까지 같은 등급의 맨
  아래에 놓인다.

view(라벨 `recently`)가 켜져 있는 동안에는 사이드바 자체 정렬(spaces/priority 전환 포함)이 가려진다.
`agent_order = false` 는 다음 서버 시작부터 적용된다 — 그때 herdr 가 view 를 스스로 버린다. 바로 끄려면
`herdr plugin disable`. herdr 가 동점 처리 기준을 직접 저장하게 되기 전까지의 우회책이다.

## 요구 사항

- herdr ≥ 0.9.0 (Linux / macOS)
- herdr 서버의 `PATH` 에 `bash`, `jq`, `flock`(util-linux)
- `agent_order` 를 쓸 때만: `socat`, 또는 `-U` 가 있는 `nc`(OpenBSD/LibreSSL netcat). Agent view 에는
  CLI 명령이 없어 소켓으로 직접 요청한다.

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
claude   = true   # Claude 페인을 대화 단위로 기록 (동작 절 참조)
agent_order = false  # 재시작해도 에이전트 사이드바 순서 유지 (에이전트 순서 절 참조)
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
| restore 두 번째 실행 | `command(s): 0 restored, 3 already running` — 중복 실행 없음 |
| 저장된 워크스페이스를 닫고 restore | 건너뜀으로 보고, 다른 곳에 실행하지 않음 |
| `bin/autosave --spawn` 을 동시에 5번 | 데몬은 정확히 하나 |
| 대기 중인 데몬을 죽이고 곧바로 `--spawn` (#2) | 락을 쥔 프로세스가 남지 않음(sleep 이 락을 물려받지 않음). 새 데몬이 바로 뜸 |
| 페인에서 명령이 끝남 | 한 주기 안에 스냅샷 갱신 |
| 서버 종료 | 데몬이 스스로 종료하고 pid 파일 정리 |
| 서버를 페인째 강제 종료 후 재기동 (플러그인 link, `[[startup]]` 훅 동작) | 스냅샷이 보호 상태가 됨. 페인에서 새 명령이 돌아도 세 틱 동안 그대로 |
| 보호 중 restore | 보호 해제, 다음 틱부터 자동 저장 재개 |
| 보호 중 save 직접 실행 | 보호 해제 |
| 기본 세션 옆에 named session 기동 (`herdr --session prtest server`, herdr 0.9.5) | `sessions/prtest/` 아래 자기 데몬·락·pid. 기본 세션 스냅샷은 그대로(md5 동일)이고 보호 상태도 생기지 않음. 그쪽에서 save 하면 `sessions/prtest/panes.json` 에 쓰고, restore 는 기본 스냅샷에서 아무것도 재생하지 않음 |
| 페인에서 실제 `nix-shell -p hello` (리더 `bash --rcfile $TMPDIR/nix-shell-…/rc`) | 저장 안 함. 옆 페인의 `bash -c 'sleep 600 \| cat'` 은 그대로 저장 |
| makeBinaryWrapper 래퍼로 띄운 mpv, 이전 복원으로 argv 에 래퍼의 `--script=…` 가 이미 두 벌 | `mpv --no-video --loop-file=inf <파일>` 로 저장. 옆의 ssh·Claude 기록은 그대로 |
| makeWrapper 셸 래퍼로 띄운 nvim (argv[0] 이 `neovim-unwrapped` store 경로, 이어서 `--cmd "lua …"`) | `nvim --headless +sleep 20` 으로 저장 |
| wrapProgram 형식 래퍼(`exec -a "$0" "…/.x-wrapped" --headless "$@"`)로 한 번, 그리고 플래그가 이미 반복된 채로 | 둘 다 래퍼 플래그 없이 저장 |
| 래퍼를 거치지 않은 명령(`sleep`·`ssh`) | argv 그대로 |
| 위 mpv 가 떠 있는 상태에서 restore | 입력한 모양으로 비교해 이미 실행 중으로 판정 |
| 그 nix-shell 기록을 담은 이전 버전 스냅샷 | *not replayable* 로 건너뜀, 페인에 입력하지 않음 |
| 스냅샷의 `bash /nonexistent/deploy.sh` | 입력 후 즉시 실패, *exited right away* 로 보고 — `command(s): 1 restored, 0 already running, 1 skipped, 1 failed` |
| 같은 디렉터리의 Claude 페인 둘 (Claude Code 처럼 `sessions/<pid>.json` 을 쓰는 대역) | `claude --resume aaaaaaaa-…`, `claude --resume bbbbbbbb-…` 로 저장 |
| 강제 재기동 후 restore | 각 페인이 자기 대화를 돌려받음(p1 → `aaaaaaaa-…`, p2 → `bbbbbbbb-…`). 죽은 프로세스의 세션 파일을 살아 있는 것으로 오판하지 않음 |
| restore 재실행 | `agent(s): 0 restored, 2 already running`, 세션 id 로 판정 |
| 실제 Claude Code 2.1.278 파일에 대고 | 열려 있던 대화 8개 모두 세션 id 로 풀림. 틀린 `procStart`·죽은 pid·잘못된 id 는 모두 거부 |
| `HIST_IGNORE_SPACE` 를 켠 zsh 페인에 `sleep 500` 복원 | 복원돼 돌고 있는데 히스토리 파일은 비어 있음. 직후 직접 입력한 `echo typed-by-hand` 는 그대로 기록 — 필터일 뿐 히스토리를 죽이지 않는다 |

에이전트 순서는 격리된 herdr 0.9.5 서버에서, 한 탭의 페인 셋을 `herdr pane report-agent` 로 에이전트로
만들어 확인했다.

| 경우 | 결과 |
|---|---|
| p3 → p1 → p2 순으로 작업 보고 | 토큰이 그 순서로 커지고 `w1/1/<위치>` 키로 저장. view 가 걸리고 소유자는 이 플러그인 |
| 서버 재시작 후 에이전트를 역순으로 다시 idle 감지 | 토큰과 저장 파일 모두 그대로 |
| 저장 파일을 치워 두고 재시작 | 토큰 없음 — herdr 는 토큰을 보관하지 않는다. 되살리는 건 startup 훅이다 |
| 재시작 후 p3 에서 작업 | p3 토큰이 올라가고 파일도 따라감 |
| 토큰이 빠진 페인(startup 훅보다 먼저 온 이벤트 상황)이 있는 채로 다른 페인 작업 | 그 페인의 저장된 자리는 파일에 유지, 작업한 페인 항목만 바뀜 |
| 작업한 페인 셋 + idle 만 있었던 페인 하나로 재시작, 넷을 역순으로 다시 idle 감지 | 셋은 저장된 순서 유지, idle 만 있던 페인은 토큰 없음, 저장 파일 그대로 (#3) |
| 그 세션에 새로 띄운 에이전트: idle 후 working | idle 동안 토큰 없음, 첫 `working` 에서 토큰이 생기고 위치 키로 저장 |
| `agent_order = false` 후 재시작 | view 해제(`active: false`), 훅은 다른 것을 읽기 전에 종료 |

## 한계

- 되살리는 건 *프로그램*이지 *상태*가 아니다. `nvim file` 은 파일을 다시 열 뿐 저장 안 한 버퍼를
  되돌리지 않고, 빌드는 처음부터 다시 돈다. 스크롤백도 복원되지 않는다.
- 마지막 자동 저장 이후에 시작한 명령은 스냅샷에 없다. 그게 중요한 순간을 위해 `save` 액션이 있다.
- 셸 안에서 다시 띄운 셸에 입력한 명령은 그 안쪽 셸의 명령으로 기록된다 — 실제로 돌던 것이 그것이므로.
- Claude 를 뺀 에이전트 페인은 기록하지 않는다. 그쪽은 herdr 자체의 에이전트 resume 이 담당한다.
- Claude 지원은 Claude Code 가 문서화하지 않은 파일을 읽는다. Claude Code 업데이트로 형식이 바뀌면 Claude
  페인은 다시 조용히 빠진다. 잘못 되살리는 일은 없지만, 되살리지도 못한다.

## 제3자 저작물

이 플러그인은 herdr 용이며 herdr 는 Apache-2.0 이다. herdr 의 코드나 바이너리를
재배포하지는 않는다. README 의 tmux-resurrect 언급은 기능 비교일 뿐 코드를 가져다 쓰지 않는다.

## License

[MIT](LICENSE)
