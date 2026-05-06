# post-migration-validation.ps1

param(
    [string]$CsvPath = "repos.csv"
)

# Log file with timestamp
$LogFile = "validation-log-$(Get-Date -Format 'yyyyMMdd').txt"

# Branch validation threshold
$BranchValidationThreshold = 10

function Write-Log {
    param(
        [string]$Message
    )

    $Message | Tee-Object -FilePath $LogFile -Append
}

function Get-UtcTimestamp {
    return (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}

function UrlEncode {
    param(
        [string]$Value
    )

    return [System.Uri]::EscapeDataString($Value)
}

function Test-ArrayContains {
    param(
        [string]$Value,
        [string[]]$Array
    )

    return $Array -contains $Value
}

function Invoke-GitHubApi {
    param(
        [string]$ApiPath
    )

    try {
        $response = gh api $ApiPath 2>$null

        if ([string]::IsNullOrWhiteSpace($response)) {
            return $null
        }

        return $response | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Get-GitHubBranches {
    param(
        [string]$GitHubOrg,
        [string]$GitHubRepo
    )

    try {
        # Same GitHub branches API, using gh pagination support.
        # --slurp is used so paginated JSON remains valid.
        $response = gh api "/repos/$GitHubOrg/$GitHubRepo/branches" --paginate --slurp 2>$null

        if ([string]::IsNullOrWhiteSpace($response)) {
            return @()
        }

        $pages = $response | ConvertFrom-Json

        $branches = @()

        foreach ($page in $pages) {
            foreach ($branch in $page) {
                $branches += $branch.name
            }
        }

        return $branches
    }
    catch {
        return @()
    }
}

function Validate-Migration {
    param(
        [string]$AdoOrg,
        [string]$AdoTeamProject,
        [string]$AdoRepo,
        [string]$GitHubOrg,
        [string]$GitHubRepo
    )

    Write-Log "[$(Get-UtcTimestamp)] Validating migration: $GitHubRepo"

    # --- GitHub repo info ---
    try {
        gh repo view "$GitHubOrg/$GitHubRepo" --json createdAt,diskUsage,defaultBranchRef,isPrivate > "validation-$GitHubRepo.json" 2>$null
    }
    catch {
        # Optional information, so continue
    }

    # --- GitHub branches ---
    $GhBranchArray = @(Get-GitHubBranches -GitHubOrg $GitHubOrg -GitHubRepo $GitHubRepo)

    if ($GhBranchArray.Count -eq 0) {
        Write-Log "[$(Get-UtcTimestamp)] ERROR: Failed to fetch GitHub branches for $GitHubOrg/$GitHubRepo"
        return
    }

    # --- ADO auth ---
    if ([string]::IsNullOrWhiteSpace($env:ADO_PAT)) {
        Write-Log "[$(Get-UtcTimestamp)] ERROR: ADO_PAT environment variable is not set"
        return
    }

    $AuthToken = ":$($env:ADO_PAT)"
    $Base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($AuthToken))

    $Headers = @{
        Authorization = "Basic $Base64Auth"
        Accept        = "application/json"
    }

    # --- Encode project; resolve repo ID in that project ---
    $EncodedProject = UrlEncode $AdoTeamProject

    $RepoListUrl = "https://dev.azure.com/$AdoOrg/$EncodedProject/_apis/git/repositories?api-version=7.1"

    try {
        $RepoListResp = Invoke-RestMethod -Uri $RepoListUrl -Headers $Headers -Method Get
    }
    catch {
        Write-Log "[$(Get-UtcTimestamp)] ERROR: Failed to fetch ADO repo list. $($_.Exception.Message)"
        return
    }

    $RepoInfo = $RepoListResp.value | Where-Object { $_.name -eq $AdoRepo }

    if ($null -eq $RepoInfo) {
        Write-Log "[$(Get-UtcTimestamp)] ERROR: Repo '$AdoRepo' not found in project '$AdoTeamProject'"
        return
    }

    $RepoId = $RepoInfo.id

    # --- Get default branches ---
    $GhRepoInfo = Invoke-GitHubApi -ApiPath "repos/$GitHubOrg/$GitHubRepo"

    if ($null -eq $GhRepoInfo) {
        Write-Log "[$(Get-UtcTimestamp)] ERROR: Failed to fetch GitHub repo details for $GitHubOrg/$GitHubRepo"
        return
    }

    $GhDefaultBranch = $GhRepoInfo.default_branch

    $AdoDefaultBranch = $RepoInfo.defaultBranch
    $AdoDefaultBranch = $AdoDefaultBranch -replace "^refs/heads/", ""

    Write-Log "[$(Get-UtcTimestamp)] Default Branch: ADO=$AdoDefaultBranch | GitHub=$GhDefaultBranch"

    # --- ADO branches using repo_id ---
    $AdoBranchUrl = "https://dev.azure.com/$AdoOrg/$EncodedProject/_apis/git/repositories/$RepoId/refs?filter=heads/&api-version=7.1"

    try {
        $AdoBranchResponse = Invoke-RestMethod -Uri $AdoBranchUrl -Headers $Headers -Method Get
    }
    catch {
        Write-Log "[$(Get-UtcTimestamp)] ERROR: Failed to fetch ADO branches. $($_.Exception.Message)"
        return
    }

    if ($AdoBranchResponse.message) {
        Write-Log "[$(Get-UtcTimestamp)] ERROR from ADO API: $($AdoBranchResponse.message)"
        return
    }

    $AdoBranchArray = @(
        $AdoBranchResponse.value |
        ForEach-Object {
            $_.name -replace "^refs/heads/", ""
        }
    )

    # --- Compare branch counts ---
    $GhBranchCount = $GhBranchArray.Count
    $AdoBranchCount = $AdoBranchArray.Count

    $BranchCountStatus = "❌ Not Matching"

    if ($GhBranchCount -eq $AdoBranchCount) {
        $BranchCountStatus = "✅ Matching"
    }

    Write-Log "[$(Get-UtcTimestamp)] Branch Count: ADO=$AdoBranchCount | GitHub=$GhBranchCount | $BranchCountStatus"

    # --- Compare branch names ---
    $MissingInGh = @()
    $MissingInAdo = @()

    foreach ($AdoBranch in $AdoBranchArray) {
        if ($GhBranchArray -notcontains $AdoBranch) {
            $MissingInGh += $AdoBranch
        }
    }

    foreach ($GhBranch in $GhBranchArray) {
        if ($AdoBranchArray -notcontains $GhBranch) {
            $MissingInAdo += $GhBranch
        }
    }

    if ($MissingInGh.Count -gt 0) {
        Write-Log "[$(Get-UtcTimestamp)] Branches missing in GitHub: $($MissingInGh -join ' ')"
    }

    if ($MissingInAdo.Count -gt 0) {
        Write-Log "[$(Get-UtcTimestamp)] Branches missing in ADO: $($MissingInAdo -join ' ')"
    }

    # --- Decide which branches to validate ---
    $BranchesToValidate = @()
    $MaxBranchCount = [Math]::Max($AdoBranchCount, $GhBranchCount)

    if ($MaxBranchCount -gt $BranchValidationThreshold) {
        $BranchesToValidate = @($GhDefaultBranch)
        Write-Log "[$(Get-UtcTimestamp)] Branch count is above $BranchValidationThreshold. Validating default branch only: $GhDefaultBranch"
    }
    else {
        $BranchesToValidate = @($AdoBranchArray)
        Write-Log "[$(Get-UtcTimestamp)] Branch count is $BranchValidationThreshold or below. Validating all branches."
    }

    # --- Validate commit counts and latest commit IDs ---
    foreach ($BranchName in $BranchesToValidate) {

        if ([string]::IsNullOrWhiteSpace($BranchName) -or $BranchName -eq "null") {
            Write-Log "[$(Get-UtcTimestamp)] WARNING: Empty branch name found. Skipping validation."
            continue
        }

        if (-not (Test-ArrayContains -Value $BranchName -Array $GhBranchArray)) {
            Write-Log "[$(Get-UtcTimestamp)] WARNING: Branch '$BranchName' exists in ADO but missing in GitHub. Skipping commit/SHA validation for this branch."
            continue
        }

        if (-not (Test-ArrayContains -Value $BranchName -Array $AdoBranchArray)) {
            Write-Log "[$(Get-UtcTimestamp)] WARNING: Branch '$BranchName' exists in GitHub but missing in ADO. Skipping commit/SHA validation for this branch."
            continue
        }

        # --- GitHub commits ---
        $GhCommitCount = 0
        $GhLatestSha = ""
        $Page = 1
        $PerPage = 100

        while ($true) {
            $EncodedGhBranchName = UrlEncode $BranchName

            # Same GitHub commits API
            $GhCommitsPath = "/repos/$GitHubOrg/$GitHubRepo/commits?sha=$EncodedGhBranchName&page=$Page&per_page=$PerPage"

            try {
                $GhCommitsRaw = gh api $GhCommitsPath 2>$null

                if ([string]::IsNullOrWhiteSpace($GhCommitsRaw)) {
                    break
                }

                $GhCommits = $GhCommitsRaw | ConvertFrom-Json
            }
            catch {
                Write-Log "[$(Get-UtcTimestamp)] ERROR: Non-JSON GitHub commits for '$BranchName' page=$Page."
                break
            }

            $CommitBatchCount = @($GhCommits).Count

            if ($Page -eq 1 -and $CommitBatchCount -gt 0) {
                $GhLatestSha = @($GhCommits)[0].sha
            }

            $GhCommitCount += $CommitBatchCount
            $Page++

            if ($CommitBatchCount -lt $PerPage) {
                break
            }
        }

        # --- ADO commits ---
        $AdoCommitCount = 0
        $AdoLatestSha = ""
        $Skip = 0
        $BatchSize = 1000
        $EncodedBranch = UrlEncode $BranchName

        while ($true) {
            # Same ADO commits API
            $AdoUrl = "https://dev.azure.com/$AdoOrg/$EncodedProject/_apis/git/repositories/$RepoId/commits?`$top=$BatchSize&`$skip=$Skip&searchCriteria.itemVersion.version=$EncodedBranch&searchCriteria.itemVersion.versionType=branch&api-version=7.1"

            try {
                $AdoResponse = Invoke-RestMethod -Uri $AdoUrl -Headers $Headers -Method Get
            }
            catch {
                Write-Log "[$(Get-UtcTimestamp)] ERROR: Failed to fetch ADO commits for '$BranchName' skip=$Skip. $($_.Exception.Message)"
                break
            }

            if ($AdoResponse.message) {
                Write-Log "[$(Get-UtcTimestamp)] ERROR from ADO API for '$BranchName': $($AdoResponse.message)"
                break
            }

            $BatchCount = @($AdoResponse.value).Count

            if ($Skip -eq 0 -and $BatchCount -gt 0) {
                $AdoLatestSha = @($AdoResponse.value)[0].commitId
            }

            $AdoCommitCount += $BatchCount
            $Skip += $BatchSize

            if ($BatchCount -lt $BatchSize) {
                break
            }
        }

        # --- Match status ---
        $CommitCountStatus = "❌ Not Matching"
        $ShaStatus = "❌ Not Matching"

        if ($GhCommitCount -eq $AdoCommitCount) {
            $CommitCountStatus = "✅ Matching"
        }

        if (-not [string]::IsNullOrWhiteSpace($GhLatestSha) -and $GhLatestSha -eq $AdoLatestSha) {
            $ShaStatus = "✅ Matching"
        }

        Write-Log "[$(Get-UtcTimestamp)] Branch '$BranchName': ADO Commits=$AdoCommitCount | GitHub Commits=$GhCommitCount | $CommitCountStatus"
        Write-Log "[$(Get-UtcTimestamp)] Branch '$BranchName': ADO SHA=$AdoLatestSha | GitHub SHA=$GhLatestSha | $ShaStatus"
    }

    Write-Log "[$(Get-UtcTimestamp)] Validation complete for $GitHubRepo"
}

function Validate-FromCsv {
    param(
        [string]$CsvPath = "repos.csv"
    )

    if (-not (Test-Path $CsvPath)) {
        Write-Log "[$(Get-UtcTimestamp)] ERROR: CSV file not found: $CsvPath"
        return
    }

    $Rows = Import-Csv -Path $CsvPath

    foreach ($Row in $Rows) {
        $Org = $Row.org
        $TeamProject = $Row.teamproject
        $Repo = $Row.repo
        $GitHubOrg = $Row.github_org
        $GitHubRepo = $Row.github_repo

        if (
            [string]::IsNullOrWhiteSpace($Org) -or
            [string]::IsNullOrWhiteSpace($TeamProject) -or
            [string]::IsNullOrWhiteSpace($Repo) -or
            [string]::IsNullOrWhiteSpace($GitHubOrg) -or
            [string]::IsNullOrWhiteSpace($GitHubRepo)
        ) {
            Write-Log "[$(Get-UtcTimestamp)] WARNING: Skipping invalid or incomplete CSV row."
            continue
        }

        Write-Log "[$(Get-UtcTimestamp)] Processing: $Repo -> $GitHubRepo"

        Validate-Migration `
            -AdoOrg $Org `
            -AdoTeamProject $TeamProject `
            -AdoRepo $Repo `
            -GitHubOrg $GitHubOrg `
            -GitHubRepo $GitHubRepo
    }

    Write-Log "[$(Get-UtcTimestamp)] All validations from CSV completed"
}

# --- Batch mode ---
Validate-FromCsv -CsvPath $CsvPath
