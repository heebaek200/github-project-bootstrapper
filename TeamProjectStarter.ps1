[CmdletBinding()]
param(
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# GitHub CLI는 JSON과 한글 텍스트를 UTF-8로 출력한다. 콘솔이 보이지 않는
# Windows PowerShell 5 프로세스는 기본 코드페이지로 이를 해석해 JSON을
# 손상시킬 수 있으므로 네이티브 명령 입출력을 명시적으로 UTF-8로 고정한다.
$script:Utf8Encoding = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = $script:Utf8Encoding
[Console]::OutputEncoding = $script:Utf8Encoding
$global:OutputEncoding = $script:Utf8Encoding

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$script:AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:WikiTemplatePath = Join-Path $script:AppRoot 'wiki'
$script:GitIgnorePath = Join-Path $script:AppRoot '.gitignore'
$script:LogsPath = Join-Path $script:AppRoot 'logs'
$script:StatePath = Join-Path $script:AppRoot 'state.json'
$script:ApiVersion = '2026-03-10'
$script:GitPath = $null
$script:GhPath = $null
$script:Owner = $null
$script:OwnerId = $null
$script:LogBox = $null
$script:StatusText = $null
$script:ProgressBar = $null
$script:SpringBootVersion = '4.1.1'
$script:JavaVersion = '21'
$script:DefaultGroupId = 'fullstack.teamproject'
# 다음 수업 진도에서 GUI와 생성 로직을 연결할 기능 자리다. 구현 전에는 화면에 노출하지 않는다.
$script:ProjectFeatures = [ordered]@{
    SpringBoot = [ordered]@{ Visible = $true; Implemented = $true }
    MySql = [ordered]@{ Visible = $false; Implemented = $false }
    Flutter = [ordered]@{ Visible = $false; Implemented = $false }
}

function Ensure-LocalFolders {
    if (-not (Test-Path -LiteralPath $script:LogsPath)) {
        New-Item -ItemType Directory -Path $script:LogsPath | Out-Null
    }
}

function Write-AppLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    Ensure-LocalFolders
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$stamp][$Level] $Message"
    $logFile = Join-Path $script:LogsPath ((Get-Date -Format 'yyyy-MM-dd') + '.log')
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8

    if ($null -ne $script:LogBox) {
        $script:LogBox.AppendText($line + [Environment]::NewLine)
        $script:LogBox.ScrollToEnd()
        $script:LogBox.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
    }
}

function Set-AppStatus {
    param([string]$Message, [int]$Percent = -1)

    if ($null -ne $script:StatusText) {
        $script:StatusText.Text = $Message
    }
    if (($null -ne $script:ProgressBar) -and ($Percent -ge 0)) {
        $script:ProgressBar.Value = $Percent
    }
    if ($null -ne $script:StatusText) {
        $script:StatusText.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
    }
}

function Resolve-ToolPath {
    param([Parameter(Mandatory = $true)][string]$Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    if ($Name -eq 'gh') {
        $knownGhPaths = @(
            'C:\Program Files\GitHub CLI\gh.exe',
            (Join-Path $env:LOCALAPPDATA 'Programs\GitHub CLI\gh.exe')
        )
        foreach ($path in $knownGhPaths) {
            if (Test-Path -LiteralPath $path) {
                return $path
            }
        }
    }

    return $null
}

function Invoke-External {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$WorkingDirectory = $script:AppRoot,
        [switch]$AllowFailure,
        [switch]$Quiet
    )

    if (-not $Quiet) {
        Write-AppLog ("실행: {0} {1}" -f (Split-Path -Leaf $FilePath), ($Arguments -join ' '))
    }

    Push-Location -LiteralPath $WorkingDirectory
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5는 네이티브 프로그램의 stderr를 ErrorRecord로
        # 바꾸며, 전역 Stop 설정에서는 종료 코드를 확인하기 전에 예외를 낸다.
        # 여기서는 stderr까지 문자열로 수집한 뒤 종료 코드로 성공 여부를 판정한다.
        $ErrorActionPreference = 'Continue'
        $outputLines = & $FilePath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        $cleanOutputLines = foreach ($line in @($outputLines)) {
            if ($line -is [System.Management.Automation.ErrorRecord]) {
                $line.Exception.Message
            }
            else {
                [string]$line
            }
        }
        $output = ($cleanOutputLines | Out-String).Trim()
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        Pop-Location
    }

    if (($exitCode -ne 0) -and (-not $AllowFailure)) {
        if ([string]::IsNullOrWhiteSpace($output)) {
            $output = "종료 코드: $exitCode"
        }
        throw $output
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $output
    }
}

function Invoke-Gh {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure,
        [switch]$Quiet
    )

    if ([string]::IsNullOrWhiteSpace($script:GhPath)) {
        $script:GhPath = Resolve-ToolPath 'gh'
    }
    if ([string]::IsNullOrWhiteSpace($script:GhPath)) {
        throw 'GitHub CLI(gh)를 찾지 못했습니다. GitHub CLI를 설치한 뒤 프로그램을 다시 실행해 주세요.'
    }
    return Invoke-External -FilePath $script:GhPath -Arguments $Arguments -AllowFailure:$AllowFailure -Quiet:$Quiet
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$WorkingDirectory = $script:AppRoot,
        [switch]$AllowFailure,
        [switch]$Quiet
    )

    if ([string]::IsNullOrWhiteSpace($script:GitPath)) {
        $script:GitPath = Resolve-ToolPath 'git'
    }
    if ([string]::IsNullOrWhiteSpace($script:GitPath)) {
        throw 'Git을 찾지 못했습니다. Git for Windows를 설치한 뒤 프로그램을 다시 실행해 주세요.'
    }
    return Invoke-External -FilePath $script:GitPath -Arguments $Arguments -WorkingDirectory $WorkingDirectory -AllowFailure:$AllowFailure -Quiet:$Quiet
}

function Invoke-GhJsonApi {
    param(
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Endpoint,
        $Body = $null,
        [switch]$AllowFailure
    )

    $args = @(
        'api', '--method', $Method,
        '-H', 'Accept: application/vnd.github+json',
        '-H', "X-GitHub-Api-Version: $($script:ApiVersion)",
        $Endpoint
    )

    $temporaryFile = $null
    try {
        if ($null -ne $Body) {
            $temporaryFile = Join-Path ([System.IO.Path]::GetTempPath()) ("team-project-starter-{0}.json" -f [guid]::NewGuid().ToString('N'))
            $json = $Body | ConvertTo-Json -Depth 20 -Compress
            [System.IO.File]::WriteAllText($temporaryFile, $json, (New-Object System.Text.UTF8Encoding($false)))
            $args += @('--input', $temporaryFile)
        }
        return Invoke-Gh -Arguments $args -AllowFailure:$AllowFailure
    }
    finally {
        if (($null -ne $temporaryFile) -and (Test-Path -LiteralPath $temporaryFile)) {
            Remove-Item -LiteralPath $temporaryFile -Force
        }
    }
}

function Invoke-GhGraphQL {
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [hashtable]$Variables = @{},
        [switch]$AllowFailure
    )

    $body = @{
        query = $Query
        variables = $Variables
    }
    $temporaryFile = Join-Path ([System.IO.Path]::GetTempPath()) ("team-project-starter-graphql-{0}.json" -f [guid]::NewGuid().ToString('N'))
    try {
        $json = $body | ConvertTo-Json -Depth 20 -Compress
        [System.IO.File]::WriteAllText($temporaryFile, $json, (New-Object System.Text.UTF8Encoding($false)))
        return Invoke-Gh -Arguments @('api', 'graphql', '--input', $temporaryFile) -AllowFailure:$AllowFailure
    }
    finally {
        if (Test-Path -LiteralPath $temporaryFile) {
            Remove-Item -LiteralPath $temporaryFile -Force
        }
    }
}

function ConvertFrom-JsonSafe {
    param([string]$Text, [string]$Context)
    $cleanText = if ($null -eq $Text) { '' } else { $Text.Trim().TrimStart([char]0xFEFF) }

    # 일부 Windows PowerShell 환경에서 네이티브 명령의 안내 문구가 JSON 앞에
    # 섞이는 경우가 있어 실제 JSON 시작 위치부터 다시 해석한다.
    $objectStart = $cleanText.IndexOf('{')
    $arrayStart = $cleanText.IndexOf('[')
    $jsonStart = -1
    if (($objectStart -ge 0) -and ($arrayStart -ge 0)) {
        $jsonStart = [Math]::Min($objectStart, $arrayStart)
    }
    elseif ($objectStart -ge 0) { $jsonStart = $objectStart }
    elseif ($arrayStart -ge 0) { $jsonStart = $arrayStart }
    if ($jsonStart -gt 0) { $cleanText = $cleanText.Substring($jsonStart) }

    try {
        $parsed = ConvertFrom-Json -InputObject $cleanText
        # Windows PowerShell 5의 ConvertFrom-Json은 최상위 JSON 배열을
        # 파이프라인에 단일 Object[]로 내보낸다. 호출부가 각 항목을 같은
        # 방식으로 다룰 수 있도록 여기서 명시적으로 펼친다.
        if ($parsed -is [System.Array]) {
            foreach ($item in $parsed) {
                Write-Output $item
            }
            return
        }
        return $parsed
    }
    catch {
        throw "$Context 응답을 해석하지 못했습니다. $($_.Exception.Message)"
    }
}

function Test-RepositoryName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if (($Name -eq '.') -or ($Name -eq '..')) { return $false }
    return $Name -match '^[A-Za-z0-9._-]+$'
}

function Get-GitHubContext {
    # 전체 사용자 JSON을 PowerShell에서 다시 해석하지 않고 gh의 jq로 필요한
    # 두 값만 추출한다. Windows PowerShell 5의 인코딩 차이에도 안전하다.
    $userResult = Invoke-Gh -Arguments @('api', 'user', '--jq', '.login, .id') -Quiet
    $values = @($userResult.Output -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($values.Count -lt 2) {
        throw "GitHub 로그인 계정 정보를 읽지 못했습니다: $($userResult.Output)"
    }
    $script:Owner = [string]$values[0].Trim()
    $script:OwnerId = [string]$values[1].Trim()
    $user = [pscustomobject]@{
        login = $script:Owner
        id = $script:OwnerId
    }
    return $user
}

function Invoke-Preflight {
    Set-AppStatus '사전 점검 중...' 10
    Write-AppLog '사전 점검을 시작합니다.'

    $script:GitPath = Resolve-ToolPath 'git'
    $script:GhPath = Resolve-ToolPath 'gh'
    if ([string]::IsNullOrWhiteSpace($script:GitPath)) { throw 'Git을 찾지 못했습니다.' }
    if ([string]::IsNullOrWhiteSpace($script:GhPath)) { throw 'GitHub CLI(gh)를 찾지 못했습니다.' }

    $gitVersion = Invoke-Git -Arguments @('--version') -Quiet
    $ghVersion = Invoke-Gh -Arguments @('--version') -Quiet
    Write-AppLog $gitVersion.Output 'OK'
    Write-AppLog (($ghVersion.Output -split "`r?`n")[0]) 'OK'

    $auth = Invoke-Gh -Arguments @('auth', 'status', '--active', '--hostname', 'github.com') -Quiet
    Write-AppLog 'GitHub 로그인 상태가 정상입니다.' 'OK'

    $user = Get-GitHubContext
    Write-AppLog ("활성 계정: {0} (ID: {1})" -f $user.login, $user.id) 'OK'

    # 사전 점검에서는 한글 제목이 포함된 목록 전체를 받을 필요가 없다.
    # gh 내부의 jq로 숫자 하나만 추출하여 접근 권한만 확인한다.
    $projects = Invoke-Gh -Arguments @('project', 'list', '--owner', '@me', '--format', 'json', '--jq', '.totalCount') -Quiet
    $projectCount = 0
    if (-not [int]::TryParse($projects.Output.Trim(), [ref]$projectCount)) {
        throw "Projects 목록 개수를 확인하지 못했습니다: $($projects.Output)"
    }
    Write-AppLog ("GitHub Projects 접근 권한이 정상입니다. 현재 Project: {0}개" -f $projectCount) 'OK'

    if (-not (Test-Path -LiteralPath $script:GitIgnorePath -PathType Leaf)) {
        throw "고정 .gitignore 템플릿이 없습니다: $($script:GitIgnorePath)"
    }
    if (-not (Test-Path -LiteralPath $script:WikiTemplatePath -PathType Container)) {
        throw "Wiki 템플릿 폴더가 없습니다: $($script:WikiTemplatePath)"
    }
    $wikiFiles = @(Get-ChildItem -LiteralPath $script:WikiTemplatePath -Filter '*.md' -File)
    if ($wikiFiles.Count -lt 1) {
        throw 'wiki 폴더에는 Markdown 파일이 하나 이상 있어야 합니다.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $script:WikiTemplatePath 'Home.md') -PathType Leaf)) {
        throw 'wiki\Home.md가 없습니다.'
    }
    Write-AppLog ("고정 .gitignore와 Wiki Markdown 템플릿 {0}개를 확인했습니다." -f $wikiFiles.Count) 'OK'

    Set-AppStatus ("준비 완료 — {0}" -f $script:Owner) 100
    return $true
}

function Save-AppState {
    param([string]$Repository, [string]$RepositoryUrl, [int]$ProjectNumber = 0, [string]$ProjectUrl = '')

    $state = [ordered]@{
        owner = $script:Owner
        repository = $Repository
        repositoryUrl = $RepositoryUrl
        projectNumber = $ProjectNumber
        projectUrl = $ProjectUrl
        updatedAt = (Get-Date).ToString('o')
    }
    $json = $state | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($script:StatePath, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-AppState {
    if (-not (Test-Path -LiteralPath $script:StatePath -PathType Leaf)) { return $null }
    try {
        return (Get-Content -Raw -LiteralPath $script:StatePath) | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function New-MainRuleset {
    param([string]$Repository)

    $payload = [ordered]@{
        name = 'protect-main'
        target = 'branch'
        enforcement = 'active'
        bypass_actors = @(
            [ordered]@{
                actor_id = [int64]$script:OwnerId
                actor_type = 'User'
                bypass_mode = 'always'
            }
        )
        conditions = [ordered]@{
            ref_name = [ordered]@{
                include = @('~DEFAULT_BRANCH')
                exclude = @()
            }
        }
        rules = @(
            [ordered]@{
                type = 'pull_request'
                parameters = [ordered]@{
                    required_approving_review_count = 1
                    dismiss_stale_reviews_on_push = $true
                    require_code_owner_review = $false
                    require_last_push_approval = $false
                    required_review_thread_resolution = $false
                }
            },
            [ordered]@{
                type = 'non_fast_forward'
            }
        )
    }

    $result = Invoke-GhJsonApi -Method POST -Endpoint "repos/$($script:Owner)/$Repository/rulesets" -Body $payload
    $ruleset = ConvertFrom-JsonSafe -Text $result.Output -Context 'Ruleset 생성'
    if (($ruleset.name -ne 'protect-main') -or ($ruleset.enforcement -ne 'active')) {
        throw 'Ruleset이 생성되었지만 Active 상태를 확인하지 못했습니다.'
    }
    Write-AppLog 'protect-main Ruleset을 Active 상태로 생성했습니다.' 'OK'
}

function Enable-GitHubPages {
    param([string]$Repository)

    $payload = [ordered]@{
        build_type = 'legacy'
        source = [ordered]@{
            branch = 'main'
            path = '/docs'
        }
    }
    $result = Invoke-GhJsonApi -Method POST -Endpoint "repos/$($script:Owner)/$Repository/pages" -Body $payload
    $pages = ConvertFrom-JsonSafe -Text $result.Output -Context 'GitHub Pages 생성'
    Write-AppLog ("GitHub Pages를 main /docs로 설정했습니다: {0}" -f $pages.html_url) 'OK'
}

function ConvertTo-JavaArtifactName {
    param([string]$Repository)

    $artifact = ([string]$Repository).ToLowerInvariant() -replace '[^a-z0-9]', ''
    if ([string]::IsNullOrWhiteSpace($artifact)) { return 'application' }
    if ($artifact -match '^[0-9]') { return "app$artifact" }
    return $artifact
}

function Test-JavaPackageName {
    param([string]$Name)
    return (-not [string]::IsNullOrWhiteSpace($Name)) -and
        ($Name -match '^[a-z_][a-z0-9_]*(\.[a-z_][a-z0-9_]*)+$')
}

function Get-SpringInitializrUri {
    param(
        [Parameter(Mandatory = $true)][string]$Artifact,
        [Parameter(Mandatory = $true)][string]$Group,
        [Parameter(Mandatory = $true)][string]$Package,
        [Parameter(Mandatory = $true)][string]$ProjectName
    )

    # JPA와 MySQL은 후속 기능이 구현될 때 함께 추가한다.
    $parameters = [ordered]@{
        type = 'gradle-project'
        language = 'java'
        bootVersion = $script:SpringBootVersion
        groupId = $Group
        artifactId = $Artifact
        # 한글 논리명을 name에 사용하면 Java Application 클래스명도 한글이 되므로
        # 실행 클래스에는 안전한 Artifact를 쓰고 한글 이름은 설명으로 보존한다.
        name = $Artifact
        description = $ProjectName
        packageName = $Package
        packaging = 'jar'
        javaVersion = $script:JavaVersion
        configurationFileFormat = 'yaml'
        dependencies = 'web,mustache,lombok,devtools'
    }
    $query = @($parameters.GetEnumerator() | ForEach-Object {
        '{0}={1}' -f [uri]::EscapeDataString([string]$_.Key), [uri]::EscapeDataString([string]$_.Value)
    }) -join '&'
    return "https://start.spring.io/starter.zip?$query"
}

function Set-SpringProfileConfiguration {
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Package
    )

    $resourcesPath = Join-Path $Destination 'src\main\resources'
    $applicationPath = Join-Path $resourcesPath 'application.yaml'
    if (-not (Test-Path -LiteralPath $applicationPath -PathType Leaf)) {
        throw "Spring 설정 파일을 찾지 못했습니다: $applicationPath"
    }

    $application = Get-Content -Raw -LiteralPath $applicationPath
    if ($application -notmatch '(?m)^spring:\s*$') {
        throw 'application.yaml에서 spring 설정을 찾지 못했습니다.'
    }
    $application = $application.TrimEnd() + "`r`n  profiles:`r`n    active: dev`r`n"
    [System.IO.File]::WriteAllText($applicationPath, $application, $script:Utf8Encoding)

    $production = @"
server:
  port: 5000
"@
    [System.IO.File]::WriteAllText((Join-Path $resourcesPath 'application-prod.yaml'), $production, $script:Utf8Encoding)

    $development = @"
server:
  port: 8080

logging:
  level:
    root: INFO                  # 스프링과 라이브러리는 INFO 이상만 콘솔에 출력
    ${Package}: DEBUG    # 내가 작성한 코드는 DEBUG 이상까지 출력
"@
    [System.IO.File]::WriteAllText((Join-Path $resourcesPath 'application-dev.yaml'), $development, $script:Utf8Encoding)
    Write-AppLog "dev 프로필과 dev/prod 환경별 설정 파일을 생성했습니다. DEBUG 로거: $Package" 'OK'
}

function Initialize-SpringBootProject {
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Artifact,
        [Parameter(Mandatory = $true)][string]$Group,
        [Parameter(Mandatory = $true)][string]$Package,
        [Parameter(Mandatory = $true)][string]$ProjectName
    )

    $archivePath = Join-Path ([System.IO.Path]::GetTempPath()) ("team-project-starter-spring-{0}.zip" -f [guid]::NewGuid().ToString('N'))
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $uri = Get-SpringInitializrUri -Artifact $Artifact -Group $Group -Package $Package -ProjectName $ProjectName
        Write-AppLog ("Spring Initializr에서 Spring Boot {0} / Java {1} 프로젝트를 내려받습니다." -f $script:SpringBootVersion, $script:JavaVersion)
        Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $archivePath
        Expand-Archive -LiteralPath $archivePath -DestinationPath $Destination -Force
        Set-SpringProfileConfiguration -Destination $Destination -Package $Package

        $helpPath = Join-Path $Destination 'HELP.md'
        if (Test-Path -LiteralPath $helpPath -PathType Leaf) {
            Remove-Item -LiteralPath $helpPath -Force
        }
        Write-AppLog 'Spring Web, Mustache, Lombok, DevTools 기반 프로젝트를 준비했습니다. JPA와 MySQL은 제외했습니다.' 'OK'
    }
    finally {
        if (Test-Path -LiteralPath $archivePath -PathType Leaf) {
            Remove-Item -LiteralPath $archivePath -Force
        }
    }
}

function New-ProjectDocumentation {
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$ProjectName
    )

    $docsPath = Join-Path $Destination 'docs'
    if (-not (Test-Path -LiteralPath $docsPath -PathType Container)) {
        New-Item -ItemType Directory -Path $docsPath | Out-Null
    }

    $documents = [ordered]@{
        'requirements.md' = '요구사항'
        'business-rules.md' = '사용자 시나리오 및 업무 규칙'
        'database-design.md' = '데이터베이스 설계서 및 ERD'
        'screen-design.md' = '화면 설계서'
        'api-design.md' = 'REST API 설계서'
        'convention.md' = '코드 컨벤션'
    }
    foreach ($document in $documents.GetEnumerator()) {
        $content = "# $($document.Value)`r`n`r`n> 프로젝트 설계 과정에서 내용을 작성합니다.`r`n"
        [System.IO.File]::WriteAllText((Join-Path $docsPath $document.Key), $content, $script:Utf8Encoding)
    }

    $indexLines = @(
        '---',
        "title: $ProjectName",
        '---',
        '',
        "# $ProjectName",
        '',
        '- [요구사항](requirements.md)',
        '- [사용자 시나리오 및 업무 규칙](business-rules.md)',
        '- [데이터베이스 설계서 및 ERD](database-design.md)',
        '- [화면 설계서](screen-design.md)',
        '- [REST API 설계서](api-design.md)',
        '- [코드 컨벤션](convention.md)',
        ''
    )
    [System.IO.File]::WriteAllLines((Join-Path $docsPath 'index.md'), $indexLines, $script:Utf8Encoding)

    $readme = "# $ProjectName`r`n`r`n[프로젝트 설계 문서 보기](docs/index.md)`r`n"
    [System.IO.File]::WriteAllText((Join-Path $Destination 'README.md'), $readme, $script:Utf8Encoding)
    Write-AppLog 'README와 설계 문서 6개 및 문서 목차를 준비했습니다.' 'OK'
}

function New-GitHubRepository {
    param(
        [string]$Repository,
        [string]$Description,
        [bool]$InitializeSpringBoot = $false,
        [string]$SpringGroup = '',
        [string]$SpringArtifact = '',
        [string]$SpringPackage = ''
    )

    if (-not (Test-RepositoryName $Repository)) {
        throw '저장소 물리명에는 영문, 숫자, 점, 밑줄, 하이픈만 사용할 수 있습니다.'
    }
    if ([string]::IsNullOrWhiteSpace($Description)) {
        throw '저장소 논리명을 입력해 주세요.'
    }
    if ($InitializeSpringBoot) {
        if ($SpringGroup -notmatch '^[a-z_][a-z0-9_]*(\.[a-z_][a-z0-9_]*)+$') {
            throw 'Spring Group은 소문자 영문과 숫자로 구성된 점(.) 구분 이름이어야 합니다.'
        }
        if ($SpringArtifact -notmatch '^[a-z][a-z0-9]*$') {
            throw 'Spring Artifact는 소문자 영문으로 시작하고 소문자 영문과 숫자만 사용할 수 있습니다.'
        }
        if (-not (Test-JavaPackageName $SpringPackage)) {
            throw 'Spring Package는 소문자 영문과 숫자로 구성된 점(.) 구분 Java 패키지명이어야 합니다.'
        }
    }

    Invoke-Preflight | Out-Null
    $fullName = "$($script:Owner)/$Repository"
    $existing = Invoke-Gh -Arguments @('repo', 'view', $fullName, '--json', 'nameWithOwner') -AllowFailure -Quiet
    if ($existing.ExitCode -eq 0) {
        throw "이미 존재하는 저장소입니다: $fullName"
    }

    $workRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("team-project-starter-repo-{0}" -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $workRoot | Out-Null
    try {
        Set-AppStatus '로컬 기본 파일을 준비하는 중...' 20
        if ($InitializeSpringBoot) {
            Set-AppStatus 'Spring Boot 프로젝트를 내려받는 중...' 12
            Initialize-SpringBootProject -Destination $workRoot -Artifact $SpringArtifact -Group $SpringGroup -Package $SpringPackage -ProjectName $Description
        }
        New-ProjectDocumentation -Destination $workRoot -ProjectName $Description
        # Initializr가 만든 파일보다 프로그램 폴더의 고정 템플릿을 항상 우선한다.
        Copy-Item -LiteralPath $script:GitIgnorePath -Destination (Join-Path $workRoot '.gitignore')

        Invoke-Git -Arguments @('init', '-b', 'main') -WorkingDirectory $workRoot | Out-Null
        Invoke-Git -Arguments @('config', 'user.name', $script:Owner) -WorkingDirectory $workRoot | Out-Null
        Invoke-Git -Arguments @('config', 'user.email', "$($script:OwnerId)+$($script:Owner)@users.noreply.github.com") -WorkingDirectory $workRoot | Out-Null
        Invoke-Git -Arguments @('add', '.') -WorkingDirectory $workRoot | Out-Null
        Invoke-Git -Arguments @('commit', '-m', 'chore: initialize repository') -WorkingDirectory $workRoot | Out-Null

        Set-AppStatus 'Public 저장소를 만들고 main에 푸시하는 중...' 45
        Invoke-Gh -Arguments @(
            'repo', 'create', $fullName,
            '--public',
            '--description', $Description,
            '--source', $workRoot,
            '--remote', 'origin',
            '--push'
        ) | Out-Null
        Invoke-Gh -Arguments @('repo', 'edit', $fullName, '--enable-issues', '--enable-wiki', '--enable-projects') | Out-Null
        Write-AppLog "Public 저장소를 생성하고 main에 푸시했습니다: $fullName" 'OK'

        Set-AppStatus 'protect-main Ruleset을 적용하는 중...' 68
        New-MainRuleset -Repository $Repository

        Set-AppStatus 'GitHub Pages를 설정하는 중...' 85
        Enable-GitHubPages -Repository $Repository

        $repoResult = Invoke-Gh -Arguments @('repo', 'view', $fullName, '--json', 'url,defaultBranchRef,visibility') -Quiet
        $repo = ConvertFrom-JsonSafe -Text $repoResult.Output -Context '저장소 검증'
        if (($repo.visibility -ne 'PUBLIC') -or ($repo.defaultBranchRef.name -ne 'main')) {
            throw '저장소 생성 후 Public/main 상태를 확인하지 못했습니다.'
        }

        Save-AppState -Repository $Repository -RepositoryUrl ([string]$repo.url)
        Set-AppStatus '저장소 생성 완료' 100
        Write-AppLog "1단계 완료: $($repo.url)" 'OK'
        return $repo
    }
    finally {
        if (Test-Path -LiteralPath $workRoot) {
            Remove-Item -LiteralPath $workRoot -Recurse -Force
        }
    }
}

function Sync-WikiTemplates {
    param([string]$Repository)

    $workRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("team-project-starter-wiki-{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        $wikiUrl = "https://github.com/$($script:Owner)/$Repository.wiki.git"
        $clone = Invoke-Git -Arguments @('clone', $wikiUrl, $workRoot) -AllowFailure
        if ($clone.ExitCode -ne 0) {
            throw "Wiki 저장소를 복제하지 못했습니다. GitHub에서 Home 페이지를 먼저 수동 생성해 주세요.`n$($clone.Output)"
        }

        Invoke-Git -Arguments @('config', 'user.name', $script:Owner) -WorkingDirectory $workRoot | Out-Null
        Invoke-Git -Arguments @('config', 'user.email', "$($script:OwnerId)+$($script:Owner)@users.noreply.github.com") -WorkingDirectory $workRoot | Out-Null
        $wikiFiles = @(Get-ChildItem -LiteralPath $script:WikiTemplatePath -Filter '*.md' -File)
        $wikiFiles | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $workRoot $_.Name) -Force
        }
        $wikiImagesPath = Join-Path $script:WikiTemplatePath 'images'
        $wikiImageCount = 0
        if (Test-Path -LiteralPath $wikiImagesPath -PathType Container) {
            $wikiImages = @(Get-ChildItem -LiteralPath $wikiImagesPath -File)
            $wikiImageCount = $wikiImages.Count
            $wikiImagesDestination = Join-Path $workRoot 'images'
            if (-not (Test-Path -LiteralPath $wikiImagesDestination -PathType Container)) {
                New-Item -ItemType Directory -Path $wikiImagesDestination | Out-Null
            }
            $wikiImages | ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $wikiImagesDestination $_.Name) -Force
            }
        }

        $status = Invoke-Git -Arguments @('status', '--porcelain') -WorkingDirectory $workRoot -Quiet
        if ([string]::IsNullOrWhiteSpace($status.Output)) {
            Write-AppLog 'Wiki 문서는 이미 최신 상태입니다.' 'OK'
            return
        }

        Invoke-Git -Arguments @('add', '.') -WorkingDirectory $workRoot | Out-Null
        Invoke-Git -Arguments @('commit', '-m', 'docs: initialize team wiki') -WorkingDirectory $workRoot | Out-Null
        Invoke-Git -Arguments @('push', 'origin', 'HEAD') -WorkingDirectory $workRoot | Out-Null
        Write-AppLog ("초기화용 Home을 교체하고 Wiki Markdown 문서 {0}개와 이미지 {1}개를 푸시했습니다." -f $wikiFiles.Count, $wikiImageCount) 'OK'
    }
    finally {
        if (Test-Path -LiteralPath $workRoot) {
            Remove-Item -LiteralPath $workRoot -Recurse -Force
        }
    }
}

function Get-ProjectFields {
    param([int]$ProjectNumber)
    $result = Invoke-GhJsonApi -Method GET -Endpoint "users/$($script:Owner)/projectsV2/$ProjectNumber/fields?per_page=100"
    $parsedFields = @(ConvertFrom-JsonSafe -Text $result.Output -Context 'Project 필드 목록')
    foreach ($field in $parsedFields) {
        Write-Output $field
    }
}

function Set-ProjectStatusOptions {
    param([object[]]$Fields)

    $statusField = $Fields | Where-Object { $_.name -eq 'Status' } | Select-Object -First 1
    if ($null -eq $statusField) { throw 'Project의 기본 Status 필드를 찾지 못했습니다.' }

    $definitions = @(
        @{ name = 'Todo'; color = 'GRAY'; description = '작업 예정' },
        @{ name = 'In Progress'; color = 'BLUE'; description = '작업 진행 중' },
        @{ name = 'Done'; color = 'GREEN'; description = '작업 완료' }
    )
    $options = @()
    foreach ($definition in $definitions) {
        $existing = @($statusField.options) | Where-Object {
            $rawName = if ($_.name -is [string]) { $_.name } else { $_.name.raw }
            $rawName -eq $definition.name
        } | Select-Object -First 1
        $option = @{
            name = $definition.name
            color = $definition.color
            description = $definition.description
        }
        if ($null -ne $existing) { $option.id = [string]$existing.id }
        $options += $option
    }

    $query = @'
mutation($input: UpdateProjectV2FieldInput!) {
  updateProjectV2Field(input: $input) {
    projectV2Field { ... on ProjectV2SingleSelectField { id name } }
  }
}
'@
    $variables = @{
        input = @{
            fieldId = [string]$statusField.node_id
            singleSelectOptions = $options
        }
    }
    Invoke-GhGraphQL -Query $query -Variables $variables | Out-Null
    Write-AppLog 'Status 옵션을 Todo / In Progress / Done으로 정리했습니다.' 'OK'
}

function Ensure-DateField {
    param([int]$ProjectNumber, [object[]]$Fields, [string]$Name)

    $existing = $Fields | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if ($null -ne $existing) { return }
    Invoke-Gh -Arguments @(
        'project', 'field-create', [string]$ProjectNumber,
        '--owner', $script:Owner,
        '--name', $Name,
        '--data-type', 'DATE',
        '--format', 'json'
    ) | Out-Null
    Write-AppLog "날짜 필드를 추가했습니다: $Name" 'OK'
}

function Sync-RepositoryLabels {
    param([string]$Repository)

    $fullName = "$($script:Owner)/$Repository"
    $desired = [ordered]@{
        '설계' = @{ color = '8250DF'; description = '설계 및 구조 작업' }
        '기능구현' = @{ color = '1F6FEB'; description = '기능 구현 작업' }
        '테스트' = @{ color = '2DA44E'; description = '테스트 및 검증 작업' }
    }
    $list = Invoke-Gh -Arguments @('label', 'list', '--repo', $fullName, '--limit', '100', '--json', 'name') -Quiet
    $labels = @(ConvertFrom-JsonSafe -Text $list.Output -Context '저장소 라벨')

    foreach ($label in $labels) {
        if (-not $desired.Contains([string]$label.name)) {
            Invoke-Gh -Arguments @('label', 'delete', [string]$label.name, '--repo', $fullName, '--yes') | Out-Null
            Write-AppLog "기본 라벨 삭제: $($label.name)" 'INFO'
        }
    }

    foreach ($name in $desired.Keys) {
        $found = $labels | Where-Object { $_.name -eq $name } | Select-Object -First 1
        if ($null -eq $found) {
            Invoke-Gh -Arguments @(
                'label', 'create', $name,
                '--repo', $fullName,
                '--color', $desired[$name].color,
                '--description', $desired[$name].description
            ) | Out-Null
        }
        else {
            Invoke-Gh -Arguments @(
                'label', 'edit', $name,
                '--repo', $fullName,
                '--color', $desired[$name].color,
                '--description', $desired[$name].description
            ) | Out-Null
        }
    }
    Write-AppLog '저장소 라벨을 설계 / 기능구현 / 테스트로 정리했습니다.' 'OK'
}

function Get-ProjectViewsGraphQL {
    param([string]$ProjectNodeId)

    $query = @'
query($id: ID!) {
  node(id: $id) {
    ... on ProjectV2 {
      views(first: 100) { nodes { id name } }
    }
  }
}
'@
    $result = Invoke-GhGraphQL -Query $query -Variables @{ id = $ProjectNodeId }
    $data = ConvertFrom-JsonSafe -Text $result.Output -Context 'Project 보기 목록'
    foreach ($view in @($data.data.node.views.nodes)) {
        Write-Output $view
    }
}

function Remove-ProjectView {
    param([string]$ViewNodeId)
    $query = @'
mutation($input: DeleteProjectV2ViewInput!) {
  deleteProjectV2View(input: $input) { projectV2View { id } }
}
'@
    Invoke-GhGraphQL -Query $query -Variables @{ input = @{ viewId = $ViewNodeId } } | Out-Null
}

function Rename-ProjectView {
    param([string]$ViewNodeId, [string]$Name)
    $query = @'
mutation($input: UpdateProjectV2ViewInput!) {
  updateProjectV2View(input: $input) { projectV2View { id name } }
}
'@
    Invoke-GhGraphQL -Query $query -Variables @{ input = @{ viewId = $ViewNodeId; name = $Name } } | Out-Null
}

function Reset-ProjectViews {
    param([int]$ProjectNumber, [string]$ProjectNodeId, [object[]]$Fields)

    $fieldByName = @{}
    foreach ($field in $Fields) { $fieldByName[[string]$field.name] = $field }
    foreach ($required in @('Title', 'Assignees', 'Labels', 'Status', '시작일', '완료(예정)일')) {
        if (-not $fieldByName.ContainsKey($required)) {
            throw "Project 보기 구성에 필요한 필드를 찾지 못했습니다: $required"
        }
    }

    $prefix = '__team_project_starter_' + [guid]::NewGuid().ToString('N') + '_'
    $definitions = @(
        [ordered]@{
            finalName = '작업 보드'
            body = [ordered]@{
                name = $prefix + 'board'
                layout = 'board'
                filter = ''
                visible_fields = @([int64]$fieldByName['Title'].id, [int64]$fieldByName['Assignees'].id, [int64]$fieldByName['Labels'].id)
                vertical_group_by = @([int64]$fieldByName['Status'].id)
            }
        },
        [ordered]@{
            finalName = '작업 목록'
            body = [ordered]@{
                name = $prefix + 'table'
                layout = 'table'
                filter = '-status:Done'
                sort_by = @(
                    @([int64]$fieldByName['시작일'].id, 'asc'),
                    @([int64]$fieldByName['완료(예정)일'].id, 'asc')
                )
                visible_fields = @(
                    [int64]$fieldByName['Title'].id,
                    [int64]$fieldByName['Assignees'].id,
                    [int64]$fieldByName['Labels'].id,
                    [int64]$fieldByName['시작일'].id,
                    [int64]$fieldByName['완료(예정)일'].id
                )
            }
        },
        [ordered]@{
            finalName = '프로젝트 일정'
            body = [ordered]@{
                name = $prefix + 'roadmap'
                layout = 'roadmap'
            }
        }
    )

    foreach ($definition in $definitions) {
        # 사용자 소유 Project의 Views 엔드포인트는 숫자형 database ID가
        # 아니라 GitHub 로그인명을 경로 식별자로 사용한다.
        Invoke-GhJsonApi -Method POST -Endpoint "users/$($script:Owner)/projectsV2/$ProjectNumber/views" -Body $definition.body | Out-Null
    }

    $views = @()
    $newViews = @()
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $views = @(Get-ProjectViewsGraphQL -ProjectNodeId $ProjectNodeId)
        $newViews = @($views | Where-Object { $_.name -like "$prefix*" })
        if ($newViews.Count -eq 3) { break }
        Start-Sleep -Milliseconds 750
    }
    if ($newViews.Count -ne 3) {
        throw "새 Project 보기 3개를 생성했지만 $($newViews.Count)개만 확인되었습니다."
    }

    foreach ($view in $views) {
        if ($view.name -notlike "$prefix*") {
            Remove-ProjectView -ViewNodeId ([string]$view.id)
        }
    }

    foreach ($definition in $definitions) {
        $suffix = switch ($definition.finalName) {
            '작업 보드' { 'board' }
            '작업 목록' { 'table' }
            default { 'roadmap' }
        }
        $view = $newViews | Where-Object { $_.name -eq ($prefix + $suffix) } | Select-Object -First 1
        Rename-ProjectView -ViewNodeId ([string]$view.id) -Name $definition.finalName
    }
    Write-AppLog '기본 보기를 제거하고 작업 보드 / 작업 목록 / 프로젝트 일정만 구성했습니다.' 'OK'
}

function Get-OrCreateProject {
    param([string]$Title)

    $listResult = Invoke-Gh -Arguments @('project', 'list', '--owner', $script:Owner, '--limit', '100', '--format', 'json') -Quiet
    $list = ConvertFrom-JsonSafe -Text $listResult.Output -Context 'Project 목록'
    $matches = @($list.projects | Where-Object { $_.title -eq $Title -and (-not $_.closed) })
    if ($matches.Count -gt 1) {
        throw "같은 제목의 열린 Project가 여러 개입니다: $Title"
    }
    if ($matches.Count -eq 1) {
        Write-AppLog "기존 Project를 재사용합니다: $Title" 'INFO'
        return $matches[0]
    }

    $create = Invoke-Gh -Arguments @('project', 'create', '--owner', $script:Owner, '--title', $Title, '--format', 'json')
    $project = ConvertFrom-JsonSafe -Text $create.Output -Context 'Project 생성'
    Write-AppLog "새 Project를 생성했습니다: $Title" 'OK'
    return $project
}

function Set-ProjectRepositoryLink {
    param([int]$ProjectNumber, [string]$ProjectNodeId, [string]$Repository)

    $query = @'
query($id: ID!) {
  node(id: $id) {
    ... on ProjectV2 {
      repositories(first: 100) { nodes { nameWithOwner } }
    }
  }
}
'@
    $result = Invoke-GhGraphQL -Query $query -Variables @{ id = $ProjectNodeId }
    $data = ConvertFrom-JsonSafe -Text $result.Output -Context 'Project 연결 저장소 목록'
    $repositories = @($data.data.node.repositories.nodes)
    $targetRepository = "$($script:Owner)/$Repository"
    $targetIsLinked = $false

    foreach ($linkedRepository in $repositories) {
        $nameWithOwner = [string]$linkedRepository.nameWithOwner
        if ([string]::IsNullOrWhiteSpace($nameWithOwner)) { continue }
        if ($nameWithOwner -eq $targetRepository) {
            $targetIsLinked = $true
            continue
        }
        Invoke-Gh -Arguments @(
            'project', 'unlink', [string]$ProjectNumber,
            '--owner', $script:Owner,
            '--repo', $nameWithOwner
        ) | Out-Null
        Write-AppLog "Project 연결 저장소를 해제했습니다: $nameWithOwner" 'INFO'
    }

    if (-not $targetIsLinked) {
        Invoke-Gh -Arguments @(
            'project', 'link', [string]$ProjectNumber,
            '--owner', $script:Owner,
            '--repo', $targetRepository
        ) | Out-Null
    }
    Write-AppLog "Project 연결 저장소를 현재 저장소로 설정했습니다: $targetRepository" 'OK'
}

function Add-RepositoryCollaborator {
    param([string]$Repository, [string]$Login)
    $payload = @{ permission = 'push' }
    Invoke-GhJsonApi -Method PUT -Endpoint "repos/$($script:Owner)/$Repository/collaborators/$Login" -Body $payload | Out-Null
    Write-AppLog "저장소 WRITE 초대를 처리했습니다: $Login" 'OK'
}

function Add-ProjectCollaborator {
    param([string]$ProjectNodeId, [string]$Login)

    $userResult = Invoke-Gh -Arguments @('api', "users/$Login")
    $user = ConvertFrom-JsonSafe -Text $userResult.Output -Context "사용자 $Login"
    $query = @'
mutation($input: UpdateProjectV2CollaboratorsInput!) {
  updateProjectV2Collaborators(input: $input) { collaborators { totalCount } }
}
'@
    $variables = @{
        input = @{
            projectId = $ProjectNodeId
            collaborators = @(
                @{
                    userId = [string]$user.node_id
                    role = 'WRITER'
                }
            )
        }
    }
    Invoke-GhGraphQL -Query $query -Variables $variables | Out-Null
    Write-AppLog "Project WRITE 권한을 처리했습니다: $Login" 'OK'
}

function Parse-Members {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $items = $Text -split '[,;\r\n\t ]+'
    return @($items | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } | Select-Object -Unique)
}

function Configure-TeamProject {
    param([string]$Repository, [string]$ProjectTitle, [string[]]$Members)

    if (-not (Test-RepositoryName $Repository)) { throw '올바른 대상 저장소명을 입력해 주세요.' }
    if ([string]::IsNullOrWhiteSpace($ProjectTitle)) { throw 'Projects 논리명을 입력해 주세요.' }

    Invoke-Preflight | Out-Null
    $fullName = "$($script:Owner)/$Repository"
    $repoCheck = Invoke-Gh -Arguments @('repo', 'view', $fullName, '--json', 'url') -AllowFailure -Quiet
    if ($repoCheck.ExitCode -ne 0) { throw "대상 저장소를 찾지 못했습니다: $fullName" }

    Set-AppStatus 'Wiki 템플릿을 푸시하는 중...' 12
    Sync-WikiTemplates -Repository $Repository

    Set-AppStatus 'GitHub Project를 준비하는 중...' 28
    $project = Get-OrCreateProject -Title $ProjectTitle
    $projectNumber = [int]$project.number
    $projectNodeId = [string]$project.id

    Invoke-Gh -Arguments @('project', 'edit', [string]$projectNumber, '--owner', $script:Owner, '--visibility', 'PUBLIC') | Out-Null
    Set-ProjectRepositoryLink -ProjectNumber $projectNumber -ProjectNodeId $projectNodeId -Repository $Repository
    Write-AppLog 'Project를 Public으로 설정하고 현재 저장소를 연결했습니다.' 'OK'

    Set-AppStatus '필드와 라벨을 정리하는 중...' 46
    $fields = @(Get-ProjectFields -ProjectNumber $projectNumber)
    Set-ProjectStatusOptions -Fields $fields
    Ensure-DateField -ProjectNumber $projectNumber -Fields $fields -Name '시작일'
    Ensure-DateField -ProjectNumber $projectNumber -Fields $fields -Name '완료(예정)일'
    Sync-RepositoryLabels -Repository $Repository

    Set-AppStatus 'Project 보기를 구성하는 중...' 68
    $fields = @(Get-ProjectFields -ProjectNumber $projectNumber)
    Reset-ProjectViews -ProjectNumber $projectNumber -ProjectNodeId $projectNodeId -Fields $fields

    if ($Members.Count -gt 0) {
        Set-AppStatus '조원 초대를 처리하는 중...' 88
        foreach ($member in $Members) {
            if ($member -eq $script:Owner) {
                Write-AppLog "본인 계정은 초대에서 건너뜁니다: $member" 'INFO'
                continue
            }
            try {
                Add-RepositoryCollaborator -Repository $Repository -Login $member
                Add-ProjectCollaborator -ProjectNodeId $projectNodeId -Login $member
            }
            catch {
                Write-AppLog ("조원 {0} 처리 실패: {1}" -f $member, $_.Exception.Message) 'ERROR'
            }
        }
    }
    else {
        Write-AppLog '조원 목록이 비어 있어 저장소 및 Project 초대를 건너뜁니다.' 'INFO'
    }

    $projectUrl = if ([string]::IsNullOrWhiteSpace([string]$project.url)) {
        "https://github.com/users/$($script:Owner)/projects/$projectNumber"
    } else { [string]$project.url }
    Save-AppState -Repository $Repository -RepositoryUrl "https://github.com/$fullName" -ProjectNumber $projectNumber -ProjectUrl $projectUrl
    Set-AppStatus '팀 환경 구성 완료' 100
    Write-AppLog "2단계 완료: $projectUrl" 'OK'
    return [pscustomobject]@{
        RepositoryUrl = "https://github.com/$fullName"
        WikiUrl = "https://github.com/$fullName/wiki"
        ProjectUrl = $projectUrl
    }
}

function Open-WebUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return }
    Start-Process $Url
}

function Set-Placeholder {
    param(
        [Parameter(Mandatory = $true)]$TextBox,
        [Parameter(Mandatory = $true)][string]$Placeholder
    )

    $TextBox.Tag = $Placeholder
    $TextBox.Text = $Placeholder
    $TextBox.Foreground = [System.Windows.Media.Brushes]::Gray
    $TextBox.Add_GotFocus({
        if ($this.Text -eq [string]$this.Tag) {
            $this.Text = ''
            $this.Foreground = [System.Windows.Media.Brushes]::Black
        }
    })
    $TextBox.Add_LostFocus({
        if ([string]::IsNullOrWhiteSpace($this.Text)) {
            $this.Text = [string]$this.Tag
            $this.Foreground = [System.Windows.Media.Brushes]::Gray
        }
    })
}

function Get-InputText {
    param($TextBox)
    if ($TextBox.Text -eq [string]$TextBox.Tag) { return '' }
    return $TextBox.Text.Trim()
}

function Invoke-GuiAction {
    param([scriptblock]$Action)
    try {
        & $Action
    }
    catch {
        Set-AppStatus '오류가 발생했습니다.' 0
        Write-AppLog $_.Exception.Message 'ERROR'
        [System.Windows.MessageBox]::Show(
            $_.Exception.Message,
            '작업 실패',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
    }
}

Ensure-LocalFolders

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="팀 프로젝트 시작 도구" Height="800" Width="900"
        WindowStartupLocation="CenterScreen" ResizeMode="CanMinimize"
        Background="#F6F8FA" FontFamily="Segoe UI, Malgun Gothic">
  <Grid Margin="24">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="145"/>
    </Grid.RowDefinitions>

    <StackPanel Grid.Row="0" Margin="0,0,0,18">
      <TextBlock Text="팀 프로젝트 시작 도구" FontSize="28" FontWeight="Bold" Foreground="#24292F"/>
      <TextBlock Text="저장소 생성과 Wiki · GitHub Projects 초기 설정을 순서대로 진행합니다." FontSize="14" Foreground="#57606A" Margin="0,5,0,0"/>
    </StackPanel>

    <Border Grid.Row="1" Background="White" BorderBrush="#D0D7DE" BorderThickness="1" CornerRadius="8" Padding="12" Margin="0,0,0,14">
      <DockPanel>
        <Button Name="PreflightButton" Content="사전 점검" Width="110" Height="34" DockPanel.Dock="Right" Background="#0969DA" Foreground="White" BorderThickness="0"/>
        <TextBlock Name="AccountText" Text="GitHub 환경을 먼저 점검해 주세요." VerticalAlignment="Center" FontSize="13" Foreground="#57606A"/>
      </DockPanel>
    </Border>

    <TabControl Grid.Row="2" Name="MainTabs" Background="White" BorderBrush="#D0D7DE">
      <TabItem Header="1. 저장소 만들기">
        <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <Grid Margin="24">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <TextBlock Grid.Row="0" Text="저장소 물리명" FontWeight="SemiBold" Margin="0,0,0,6"/>
          <TextBox Grid.Row="1" Name="RepositoryNameBox" Height="38" FontSize="14" Padding="10,7" Margin="0,0,0,16"/>
          <TextBlock Grid.Row="2" Text="저장소 논리명 · Description" FontWeight="SemiBold" Margin="0,0,0,6"/>
          <TextBox Grid.Row="3" Name="DescriptionBox" Height="38" FontSize="14" Padding="10,7" Margin="0,0,0,18"/>
          <CheckBox Grid.Row="4" Name="SpringBootCheckBox" Content="Spring Boot 기초 프로젝트 초기화" FontWeight="SemiBold" Margin="0,0,0,10"/>
          <Border Grid.Row="5" Name="SpringMetadataPanel" Visibility="Collapsed" Background="#F6F8FA" BorderBrush="#D0D7DE" BorderThickness="1" CornerRadius="6" Padding="12" Margin="0,0,0,14">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/><ColumnDefinition Width="12"/>
                <ColumnDefinition Width="*"/><ColumnDefinition Width="12"/>
                <ColumnDefinition Width="1.45*"/>
              </Grid.ColumnDefinitions>
              <StackPanel Grid.Column="0">
                <TextBlock Text="Group" FontWeight="SemiBold" Margin="0,0,0,5"/>
                <TextBox Name="SpringGroupBox" Height="34" Padding="8,5"/>
              </StackPanel>
              <StackPanel Grid.Column="2">
                <TextBlock Text="Artifact" FontWeight="SemiBold" Margin="0,0,0,5"/>
                <TextBox Name="SpringArtifactBox" Height="34" Padding="8,5"/>
              </StackPanel>
              <StackPanel Grid.Column="4">
                <TextBlock Text="Package" FontWeight="SemiBold" Margin="0,0,0,5"/>
                <TextBox Name="SpringPackageBox" Height="34" Padding="8,5"/>
              </StackPanel>
            </Grid>
          </Border>
          <StackPanel Grid.Row="6" Orientation="Horizontal" Margin="0,0,0,18">
            <Button Name="CreateRepositoryButton" Content="저장소 생성" Width="140" Height="42" MinHeight="42" Background="#1F883D" Foreground="White" FontWeight="SemiBold" BorderThickness="0"/>
            <Button Name="OpenRepositoryButton" Content="저장소 열기" Width="125" Height="42" MinHeight="42" Margin="10,0,0,0" FontWeight="SemiBold"/>
          </StackPanel>
          <Border Grid.Row="7" Background="#FFF8C5" BorderBrush="#D4A72C" BorderThickness="1" CornerRadius="6" Padding="12">
            <TextBlock TextWrapping="Wrap" Text="Public 저장소에 고정 .gitignore, README, 설계 문서를 푸시합니다. Spring Boot 선택 시 Gradle Groovy · Java 21 · Boot 4.1.1과 Web · Mustache · Lombok · DevTools를 포함합니다. 이후 Ruleset과 Pages를 설정합니다." Foreground="#633C01"/>
          </Border>
        </Grid>
        </ScrollViewer>
      </TabItem>

      <TabItem Header="2. Wiki · Project 구성">
        <Grid Margin="24">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <TextBlock Grid.Row="0" Text="대상 저장소명" FontWeight="SemiBold" Margin="0,0,0,6"/>
          <TextBox Grid.Row="1" Name="TargetRepositoryBox" Height="36" FontSize="14" Padding="10,6" Margin="0,0,0,13"/>
          <TextBlock Grid.Row="2" Text="Projects 논리명" FontWeight="SemiBold" Margin="0,0,0,6"/>
          <TextBox Grid.Row="3" Name="ProjectTitleBox" Height="36" FontSize="14" Padding="10,6" Margin="0,0,0,13"/>
          <TextBlock Grid.Row="4" Text="조원 GitHub 사용자명 · 선택사항" FontWeight="SemiBold" Margin="0,0,0,6"/>
          <TextBox Grid.Row="5" Name="MembersBox" Height="70" FontSize="14" Padding="10,7" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Margin="0,0,0,13"/>
          <StackPanel Grid.Row="6" Orientation="Horizontal" Margin="0,0,0,14">
            <Button Name="ConfigureButton" Content="팀 환경 구성" Width="145" Height="42" MinHeight="42" Background="#1F883D" Foreground="White" FontWeight="SemiBold" BorderThickness="0"/>
            <Button Name="OpenWikiButton" Content="Wiki 열기" Width="110" Height="42" MinHeight="42" Margin="10,0,0,0" FontWeight="SemiBold"/>
            <Button Name="OpenProjectButton" Content="Project 열기" Width="115" Height="42" MinHeight="42" Margin="10,0,0,0" FontWeight="SemiBold"/>
            <Button Name="OpenProjectSettingsButton" Content="Project 설정" Width="125" Height="42" MinHeight="42" Margin="10,0,0,0" FontWeight="SemiBold"/>
          </StackPanel>
          <Border Grid.Row="7" Background="#FFEBE9" BorderBrush="#FF8182" BorderThickness="1" CornerRadius="6" Padding="10">
            <TextBlock TextWrapping="Wrap" Text="실행하면 Wiki의 초기화용 Home을 템플릿 Home으로 교체하고, 저장소 라벨과 Project 기본 보기를 삭제·재구성합니다. Project에는 현재 저장소만 연결하며, 조원 입력이 비어 있으면 초대는 건너뜁니다." Foreground="#82071E"/>
          </Border>
        </Grid>
      </TabItem>
    </TabControl>

    <Grid Grid.Row="3" Margin="0,14,0,10">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="220"/></Grid.ColumnDefinitions>
      <TextBlock Name="StatusText" Grid.Column="0" Text="대기 중" VerticalAlignment="Center" FontWeight="SemiBold" Foreground="#24292F"/>
      <ProgressBar Name="ProgressBar" Grid.Column="1" Height="18" Minimum="0" Maximum="100" Value="0"/>
    </Grid>

    <Border Grid.Row="4" Background="#0D1117" CornerRadius="6" Padding="8">
      <TextBox Name="LogBox" Background="#0D1117" Foreground="#C9D1D9" BorderThickness="0" IsReadOnly="True"
               FontFamily="Consolas, Malgun Gothic" FontSize="12" TextWrapping="Wrap"
               VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"/>
    </Border>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$preflightButton = $window.FindName('PreflightButton')
$accountText = $window.FindName('AccountText')
$repositoryNameBox = $window.FindName('RepositoryNameBox')
$descriptionBox = $window.FindName('DescriptionBox')
$springBootCheckBox = $window.FindName('SpringBootCheckBox')
$springMetadataPanel = $window.FindName('SpringMetadataPanel')
$springGroupBox = $window.FindName('SpringGroupBox')
$springArtifactBox = $window.FindName('SpringArtifactBox')
$springPackageBox = $window.FindName('SpringPackageBox')
$targetRepositoryBox = $window.FindName('TargetRepositoryBox')
$projectTitleBox = $window.FindName('ProjectTitleBox')
$membersBox = $window.FindName('MembersBox')
$createRepositoryButton = $window.FindName('CreateRepositoryButton')
$configureButton = $window.FindName('ConfigureButton')
$openRepositoryButton = $window.FindName('OpenRepositoryButton')
$openWikiButton = $window.FindName('OpenWikiButton')
$openProjectButton = $window.FindName('OpenProjectButton')
$openProjectSettingsButton = $window.FindName('OpenProjectSettingsButton')
$script:StatusText = $window.FindName('StatusText')
$script:ProgressBar = $window.FindName('ProgressBar')
$script:LogBox = $window.FindName('LogBox')

Set-Placeholder -TextBox $repositoryNameBox -Placeholder '예: study-room-reservation'
Set-Placeholder -TextBox $descriptionBox -Placeholder '예: 스터디룸 예약 시스템'
Set-Placeholder -TextBox $targetRepositoryBox -Placeholder '예: study-room-reservation'
Set-Placeholder -TextBox $projectTitleBox -Placeholder '예: 스터디룸 예약 프로젝트'
Set-Placeholder -TextBox $membersBox -Placeholder "선택사항 — 한 줄에 한 명`n예: member-one`nmember-two"

$springGroupBox.Text = $script:DefaultGroupId
$springArtifactBox.Text = 'application'
$springPackageBox.Text = "$($script:DefaultGroupId).application"

$springBootCheckBox.Add_Checked({
    $springMetadataPanel.Visibility = [System.Windows.Visibility]::Visible
})
$springBootCheckBox.Add_Unchecked({
    $springMetadataPanel.Visibility = [System.Windows.Visibility]::Collapsed
})
$repositoryNameBox.Add_TextChanged({
    $repository = Get-InputText $repositoryNameBox
    if ([string]::IsNullOrWhiteSpace($repository)) { return }
    $artifact = ConvertTo-JavaArtifactName $repository
    $springArtifactBox.Text = $artifact
    $springPackageBox.Text = "$($springGroupBox.Text.Trim()).$artifact"
})
$springGroupBox.Add_TextChanged({
    if (($null -eq $springArtifactBox) -or ($null -eq $springPackageBox)) { return }
    $artifact = $springArtifactBox.Text.Trim()
    if (-not [string]::IsNullOrWhiteSpace($artifact)) {
        $springPackageBox.Text = "$($springGroupBox.Text.Trim()).$artifact"
    }
})
$springArtifactBox.Add_TextChanged({
    if ($null -eq $springPackageBox) { return }
    $artifact = $springArtifactBox.Text.Trim()
    if (-not [string]::IsNullOrWhiteSpace($artifact)) {
        $springPackageBox.Text = "$($springGroupBox.Text.Trim()).$artifact"
    }
})

$state = Get-AppState
if ($null -ne $state) {
    if (-not [string]::IsNullOrWhiteSpace([string]$state.repository)) {
        $targetRepositoryBox.Text = [string]$state.repository
        $targetRepositoryBox.Foreground = [System.Windows.Media.Brushes]::Black
    }
}

$preflightButton.Add_Click({
    Invoke-GuiAction {
        Invoke-Preflight | Out-Null
        $accountText.Text = "GitHub 계정: $($script:Owner) · 템플릿 준비 완료"
    }
})

$createRepositoryButton.Add_Click({
    Invoke-GuiAction {
        $repository = Get-InputText $repositoryNameBox
        $description = Get-InputText $descriptionBox
        $initializeSpringBoot = [bool]$springBootCheckBox.IsChecked
        $springSummary = if ($initializeSpringBoot) {
            "사용 — Group: $($springGroupBox.Text.Trim()), Artifact: $($springArtifactBox.Text.Trim()), Package: $($springPackageBox.Text.Trim())"
        } else { '사용 안 함' }
        $message = @"
다음 Public 저장소를 생성하시겠습니까?

저장소: $repository
설명: $description
Spring Boot: $springSummary

main 보호 Ruleset과 공개 GitHub Pages도 함께 생성됩니다.
"@
        $answer = [System.Windows.MessageBox]::Show($message, '저장소 생성 확인', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }

        $repo = New-GitHubRepository `
            -Repository $repository `
            -Description $description `
            -InitializeSpringBoot $initializeSpringBoot `
            -SpringGroup $springGroupBox.Text.Trim() `
            -SpringArtifact $springArtifactBox.Text.Trim() `
            -SpringPackage $springPackageBox.Text.Trim()
        $targetRepositoryBox.Text = $repository
        $targetRepositoryBox.Foreground = [System.Windows.Media.Brushes]::Black
        $accountText.Text = "GitHub 계정: $($script:Owner) · 최근 저장소: $repository"
        [System.Windows.MessageBox]::Show("저장소 생성이 완료되었습니다.`n$($repo.url)`n`n이제 GitHub에서 Wiki Home을 한 번 수동 생성한 뒤 2단계를 실행하세요.", '완료', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
    }
})

$configureButton.Add_Click({
    Invoke-GuiAction {
        $repository = Get-InputText $targetRepositoryBox
        $title = Get-InputText $projectTitleBox
        $members = @(Parse-Members (Get-InputText $membersBox))
        $memberText = if ($members.Count -eq 0) { '없음 — 초대 건너뜀' } else { $members -join ', ' }
        $message = @"
다음 팀 환경을 구성하시겠습니까?

저장소: $repository
Project: $title
조원: $memberText

주의:
• Wiki Home을 템플릿으로 교체합니다.
• 저장소 라벨은 설계 / 기능구현 / 테스트만 남깁니다.
• Project 보기는 작업 보드 / 작업 목록 / 프로젝트 일정만 남깁니다.
• Project에는 현재 입력한 저장소만 연결합니다.
• Default repository는 Project 설정에서 수동으로 지정합니다.
"@
        $answer = [System.Windows.MessageBox]::Show($message, '팀 환경 구성 확인', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }

        $result = Configure-TeamProject -Repository $repository -ProjectTitle $title -Members $members
        [System.Windows.MessageBox]::Show("팀 환경 구성이 완료되었습니다.`n`n$result", '완료', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
    }
})

$openRepositoryButton.Add_Click({
    Invoke-GuiAction {
        if ([string]::IsNullOrWhiteSpace($script:Owner)) { Get-GitHubContext | Out-Null }
        $repository = Get-InputText $repositoryNameBox
        if ([string]::IsNullOrWhiteSpace($repository)) { $repository = Get-InputText $targetRepositoryBox }
        if ([string]::IsNullOrWhiteSpace($repository)) { throw '열 저장소명을 입력해 주세요.' }
        Open-WebUrl "https://github.com/$($script:Owner)/$repository"
    }
})

$openWikiButton.Add_Click({
    Invoke-GuiAction {
        if ([string]::IsNullOrWhiteSpace($script:Owner)) { Get-GitHubContext | Out-Null }
        $repository = Get-InputText $targetRepositoryBox
        if ([string]::IsNullOrWhiteSpace($repository)) { throw '대상 저장소명을 입력해 주세요.' }
        Open-WebUrl "https://github.com/$($script:Owner)/$repository/wiki"
    }
})

$openProjectButton.Add_Click({
    Invoke-GuiAction {
        $currentState = Get-AppState
        if (($null -eq $currentState) -or [string]::IsNullOrWhiteSpace([string]$currentState.projectUrl)) {
            throw '아직 저장된 Project 주소가 없습니다. 팀 환경 구성을 먼저 실행해 주세요.'
        }
        Open-WebUrl ([string]$currentState.projectUrl)
    }
})

$openProjectSettingsButton.Add_Click({
    Invoke-GuiAction {
        $currentState = Get-AppState
        if (($null -eq $currentState) -or [string]::IsNullOrWhiteSpace([string]$currentState.projectUrl)) {
            throw '아직 저장된 Project 주소가 없습니다. 팀 환경 구성을 먼저 실행해 주세요.'
        }
        $settingsUrl = ([string]$currentState.projectUrl).TrimEnd('/') + '/settings'
        Open-WebUrl $settingsUrl
    }
})

if ($ValidateOnly) {
    Write-Output 'GUI validation: OK'
    return
}

Write-AppLog '프로그램을 시작했습니다. 먼저 사전 점검을 실행해 주세요.'
[void]$window.ShowDialog()
