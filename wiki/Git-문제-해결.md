[[Home]] · [[작업 순서]]

Git을 사용하다 자주 만나는 문제와 해결 방법을 정리합니다.

명령을 실행하기 전에는 현재 브랜치와 변경된 파일을 먼저 확인합니다.

```bash
git status
```

## 다른 컴퓨터에서 작업 브랜치를 이어받으려면?

먼저 기존 컴퓨터에서 작업 내용을 Commit하고 Push합니다.

```bash
git add .
git commit -m "작업 중간 저장 #12"
git push -u origin f/12
```

다른 컴퓨터에 아직 로컬 저장소가 없다면 원격 저장소를 먼저 Clone하고 저장소 폴더로 이동합니다. `OWNER`와 `REPOSITORY`는 실제 GitHub 사용자명과 저장소명으로 바꿉니다.

```bash
git clone https://github.com/OWNER/REPOSITORY.git
cd REPOSITORY
```

Clone을 마쳤거나 이미 로컬 저장소가 있다면 원격 저장소의 최신 브랜치 정보를 가져온 뒤 작업 브랜치로 전환합니다.

```bash
git fetch origin
git switch -c f/12 --track origin/f/12
```

그 컴퓨터에 `f/12` 브랜치가 이미 있다면 다음과 같이 최신 내용을 받습니다.

```bash
git switch f/12
git pull origin f/12
```

## 수정한 파일을 main을 Pull한 시점으로 되돌리려면?

먼저 되돌릴 내용을 확인합니다.

```bash
git diff -- src/server/UserHandler.java
```

문제가 없다면 해당 파일을 로컬 `main` 브랜치에 저장된 상태로 되돌립니다.

```bash
git restore --source=main -- src/server/UserHandler.java
```

> 이 명령을 실행하면 아직 Commit하지 않은 수정 내용이 사라집니다. 필요한 내용이 없는지 반드시 먼저 확인합니다.

만약 파일 충돌로 인해 복구가 안된다면 다음과 같이 강제로 되돌리는 방법이 있습니다.

```bash
git fetch origin
git reset --hard origin/main
```

## 로컬 저장소에서 파일 충돌이 일어났다면?

먼저 충돌한 파일을 확인합니다.

```bash
git status
```

충돌한 파일에는 다음과 같은 표시가 생깁니다.

```text
<<<<<<< HEAD
내 브랜치의 내용
=======
가져온 브랜치의 내용
>>>>>>> main
```

두 내용을 비교하여 최종적으로 사용할 코드만 남기고, `<<<<<<<`, `=======`, `>>>>>>>` 표시는 모두 삭제합니다.

수정한 프로그램을 테스트한 뒤 충돌 해결 내용을 Commit하고 Push합니다.

```bash
git add src/server/UserHandler.java
git commit -m "충돌 해결 #12"
git push
```

어느 코드를 남겨야 할지 모르겠다면 임의로 삭제하지 말고 해당 코드를 작성한 조원과 먼저 확인합니다.

## 잘못된 파일을 Commit해서 저장소에서 삭제하려면?

파일을 저장소와 내 컴퓨터에서 모두 삭제하려면 다음 명령을 사용합니다.

```bash
git rm config.properties
git commit -m "잘못 추가한 파일 삭제 #12"
git push
```

파일은 내 컴퓨터에 남겨 두고 저장소에서만 삭제하려면 먼저 해당 파일을 `.gitignore`에 추가한 뒤 다음 명령을 사용합니다.

```bash
git rm --cached config.properties
git add .gitignore
git commit -m "설정 파일 추적 제외 #12"
git push
```

> 저장소에서 파일을 삭제해도 과거 Commit 기록에는 남아 있습니다. 파일에 개인정보가 담기지 않도록 주의하고, 만약 비밀번호나 API Key를 올렸다면 파일 삭제만으로 끝내지 말고 해당 비밀번호나 Key도 즉시 변경합니다.

## 비밀번호나 API Key를 Commit하고 Push했다면?

아래 순서대로 처리합니다.

### 팀원 전원

1. 즉시 모든 팀원에게 알립니다.
2. 모든 Commit, Push, Pull Request와 Merge를 중단합니다.
3. 노출된 비밀번호, API Key와 Token을 모두 폐기하거나 변경합니다.
4. 같은 값을 다른 곳에서도 사용했다면 그 값도 모두 변경합니다.
5. 새 값을 환경변수에 다시 설정합니다.
6. 실제 비밀번호나 Key를 Issue, 채팅 또는 문서에 적지 않습니다.
7. 아직 Push하지 않은 작업이 있다면 삭제하지 말고 저장소 관리자에게 알립니다.

### 저장소 관리자

1. 팀원에게 작업 중단 여부를 확인합니다.
2. 열린 Pull Request를 모두 닫거나 먼저 정리합니다.
3. `git-filter-repo` 2.47 이상을 설치합니다.
4. 기존 작업 폴더가 아닌 새 폴더에 저장소를 Clone합니다.

```bash
git clone https://github.com/OWNER/REPOSITORY.git repository-clean
cd repository-clean
```

5. 다음 두 방법 중 하나만 실행합니다.

파일 전체를 모든 Commit에서 삭제하려면 다음 명령을 실행합니다.

```bash
git filter-repo --sensitive-data-removal --invert-paths --path 비밀값이_들어간_파일경로
```

파일은 남기고 비밀번호 문자열만 제거하려면 저장소 밖에 `passwords.txt`를 만들고, 노출된 값을 한 줄에 하나씩 적은 뒤 다음 명령을 실행합니다.

```bash
git filter-repo --sensitive-data-removal --replace-text ../passwords.txt
```

6. `passwords.txt`를 사용했다면 즉시 삭제합니다.
7. 정리한 저장소에서 비밀값을 제거하고 환경변수를 사용하도록 소스를 수정합니다.
8. 비밀값이 들어가는 로컬 설정 파일을 `.gitignore`에 추가합니다.
9. 수정 내용을 Commit합니다.

```bash
git add 수정한_파일 .gitignore
git commit -m "민감정보 제거"
```

10. `git remote -v`를 실행합니다. `origin`이 나오지 않으면 다시 등록합니다.

```bash
git remote add origin https://github.com/OWNER/REPOSITORY.git
```

11. Ruleset 또는 브랜치 보호가 Push를 막으면 잠시 해제합니다.
12. 정리된 이력을 원격 저장소에 반영합니다.

```bash
git push --force --mirror origin
```

13. 잠시 해제했던 Ruleset 또는 브랜치 보호를 다시 켭니다.
14. Fork가 있다면 Fork 소유자에게 삭제 또는 이력 정리를 요청합니다.
15. 실제 민감정보가 Pull Request나 캐시에 남아 있다면 [GitHub Support](https://support.github.com/)에 삭제를 요청합니다.
16. 작업이 끝났다고 모든 팀원에게 알립니다.

### 저장소 정리 완료 후 팀원 전원

1. 기존 로컬 저장소에서는 더 이상 Pull하거나 Push하지 않습니다.
2. Push하지 않은 작업이 없다면 기존 로컬 저장소 폴더를 삭제합니다.
3. 저장소를 다시 Clone합니다.

```bash
git clone https://github.com/OWNER/REPOSITORY.git
```

4. 새 환경변수를 설정합니다.
5. 프로그램 실행과 데이터베이스 연결을 확인합니다.
6. 저장소 관리자의 허락을 받은 뒤 작업을 다시 시작합니다.

[GitHub 공식 민감정보 삭제 절차](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository)

## main 브랜치에서 작업해버린 것을 뒤늦게 알아차렸다면?

### case: 아직 Commit 전

수정한 파일을 그대로 둔 상태에서 작업 브랜치를 생성합니다. `git add`를 실행한 뒤라도 방법은 같습니다.

```bash
git switch -c f/12
```

수정 내용과 Add 상태는 새 브랜치로 그대로 따라갑니다. 이후 작업을 계속하면 됩니다.

### case: Commit 후, Push 전

잘못 만든 Commit을 작업 브랜치에 보존합니다.

```bash
git switch -c f/12
```

그다음 `main`을 원격 저장소와 같은 상태로 되돌립니다.

```bash
git switch main
git fetch origin
git reset --hard origin/main
```

`reset --hard`를 실행하면 Commit하지 않은 수정 내용은 사라집니다. 실행 전에 `git status`로 남은 작업이 없는지 확인합니다.

### case: Push 후

이미 원격 `main`에 공유된 Commit이므로 팀원에게 먼저 알립니다. 강제 Push로 기록을 지우지 않고, 되돌리는 Commit을 추가합니다.

```bash
git switch main
git pull origin main
git revert 잘못된_커밋_ID
git push origin main
```

이제 되돌린 `main`에서 작업 브랜치를 만들고, 기존 Commit의 작업 내용을 다시 적용합니다.

```bash
git switch -c f/12
git cherry-pick 잘못된_커밋_ID
git push -u origin f/12
```

이후 작업 브랜치에서 테스트하고 Pull Request를 작성합니다.


## 현재 작업 중이던 브랜치에 main의 수정 내용을 병합하는 절차
가능한 한 충돌 위험이 없다고 판단될 경우에만 행하도록 합니다.
```bash
# 1. 현재 변경 상태 확인
git status --short

# 2. 현재 작업이 남아 있다면 먼저 커밋
git add <파일명>
git commit -m "작업 내용"

# 3. main 최신 정보 가져오기
git fetch origin

# 4. 원격 main을 현재 브랜치에 병합
git merge origin/main

# (충돌발생시!) 만약 충돌이 발생했다면 파일 수정 후 커밋
git add <충돌을 해결한 파일>
git commit
```
