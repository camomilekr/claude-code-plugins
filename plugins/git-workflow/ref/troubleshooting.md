# 참조 — 증상과 원인

명령이 실패했거나 증상의 원인을 모를 때 읽는다. 테스트 쪽은 `ref/testing-traps.md`.

## git · 워크트리

| 증상 | 원인 |
|---|---|
| `fatal: '<브랜치>' is already checked out` | 다른 워크트리가 그 브랜치를 쓰고 있다. `git worktree list`로 찾는다 |
| `fatal: cannot lock ref 'refs/heads/feature/x/y'` | 트랙 브랜치에 슬래시를 썼다. 하이픈으로 잇는다(아래) |
| `git branch -d`가 거부 | 워크트리가 아직 그 브랜치를 붙잡고 있거나, 정말 병합되지 않았다 |
| 워크트리에서 테스트가 모듈을 못 찾음 | 그 워크트리에 `node_modules`(의존성)가 없다. 워크트리마다 설치가 필요하다 |
| 워크트리 디렉터리를 손으로 지웠다 | `git worktree prune`으로 남은 등록 정보를 정리한다 |
| `git worktree remove`가 느리거나 거부한다 | `node_modules`를 먼저 지우지 않았다 |
| 커밋 하나에 여러 관심사가 들어갔다 | `git add -A`를 썼다. 경로를 지정해 의미 단위로 나눈다 |
| `git stash -k -u`가 `Entry '...' not uptodate. Cannot merge.` | 지문용 `git add -N` 표식이 있는 파일을 그 뒤에 편집했다. `git reset`으로 인덱스를 비운 뒤 다시 스테이징한다 |
| 푸시·브랜치 삭제에 `Repository rule violations` 경고가 뜨는데 결과는 성공 | ruleset의 `bypass_actors`에 admin이 있으면 위반을 보고하고 허용한다. **실패와 구분하는 기준은 `[deleted]`·`[new branch]` 줄이 있는지다** |

### 트랙 브랜치에 슬래시를 쓸 수 없다

`feature/foo`가 있는데 `feature/foo/bar`를 만들 수 없다. **git ref는 파일시스템 기반이라 같은 이름이 파일이면서 디렉터리일 수 없다.** 반대 순서도 막힌다. 그래서 트랙 브랜치는 **하이픈으로 잇는다**: `feature/{KEY}-{트랙}`.

### `node_modules`의 `rm -rf`는 거의 항상 한 번 실패한다 (macOS)

```
rm: .../node_modules: Directory not empty
```

**정상이고, 내용은 이미 다 지워졌다.** macOS가 `rm`이 도는 동안 그 디렉터리에 `.DS_Store`를 다시 쓰고, `rm`은 내용을 비운 뒤 마지막에 `rmdir`을 시도하므로 그 틈에 생긴 파일 하나 때문에 `ENOTEMPTY`로 끝난다. 한 번 더 부르면 성공한다. **`git worktree remove --force`로 넘어가지 마라** — 추적되지 않는 진짜 작업물(계획서, 개발 루프 기록)까지 함께 버린다.

## git은 워크트리를 자동으로 무시하지 않는다

워크트리가 저장소 안 경로(`.worktrees/` 등)에 있으면 부모 저장소의 `git status`에 미추적으로 올라온다. 여기서 `git add -A`를 쓰면 워크트리가 **embedded git repository로 커밋된다** — 경고는 나오지만 막아 주지는 않고, 들어가는 것은 gitlink 하나라 diff에 내용이 보이지 않아 **눈치채기 어렵다.**

- **`.gitignore`에 워크트리 경로(`/.worktrees/` 등)를 넣어 1차 방어선을 둔다.** 규약이 `git add -A`를 금지하는 것만으로는 실수 한 번을 막지 못한다
- 점(`.`)으로 시작하는 디렉터리에 워크트리를 두면 lint·타입 검사 도구들이 기본 탐색에서 건너뛰어 부모 프로젝트의 verify와 충돌하지 않는다. **대가는 IDE 지원이다** — 워크트리를 편집할 때는 별도 창으로 열어야 한다. 루트 tsconfig에 워크트리를 포함시키는 우회는 쓰지 마라(같은 클래스가 두 번 선언된 것으로 보인다)
- **`docs/`를 `.gitignore`에 넣지 마라.** 추적해야 하는 문서가 같은 폴더에 있을 수 있다. 계획서와 개발 루프 기록은 "무시되는" 것이 아니라 **커밋하지 않기로 한 것뿐**이고, `git add -A`를 쓰면 그대로 들어간다. **커밋할 파일을 경로로 지정해라**

## 훅(pre-commit)은 강제 수단이 아니라 편의 장치다

- 훅이 없는 곳이 있다 — 클론 직후 의존성 설치 전, 훅이 세워지지 않은 워크트리, `HUSKY=0` 같은 우회 환경변수가 설정된 셸. 전부 **경고 없이** 훅을 건너뛴다. 워크트리를 만들면 훅 설치 절차를 함께 돌려라
- `--no-verify`·환경변수·`core.hooksPath` 변경으로 우회된다. **실제 강제는 CI의 몫이다**
- 규칙을 끄거나 낮출 때는 반드시 이유를 주석으로 남기고, 전체를 끄기보다 파일 단위로 좁혀서 끈다
