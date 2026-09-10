# 扫描本地古籍目录，生成结构化 books.json
# 用法：在 PowerShell 中执行 .\scripts\scan-guji.ps1

$ErrorActionPreference = "Continue"

Write-Host "脚本启动..."
Write-Host "PSScriptRoot: $PSScriptRoot"

$GujiRoot = Join-Path $PSScriptRoot "..\..\古籍"
$OutputFile = Join-Path $PSScriptRoot "..\data\books.json"

Write-Host "GujiRoot: $GujiRoot"
Write-Host "OutputFile: $OutputFile"

function Get-Slug ($name) {
    # 去掉前导数字编号，如 "01_太上老君说常清静经" -> "太上老君说常清静经"
    $name -replace '^\d+[-_]', ''
}

function Get-SortKey ($name) {
    # 支持前导数字编号和中文数字前缀排序
    $cnNums = @{
        '零' = 0; '一' = 1; '二' = 2; '三' = 3; '四' = 4;
        '五' = 5; '六' = 6; '七' = 7; '八' = 8; '九' = 9; '十' = 10
    }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($name)

    # 优先按前导阿拉伯数字排序
    if ($base -match '^(\d+)') {
        return [int]$matches[1]
    }

    # 否则解析开头连续的中文数字
    $total = 0
    $found = $false
    foreach ($c in $base.ToCharArray()) {
        $s = $c.ToString()
        if ($cnNums.ContainsKey($s)) {
            $v = $cnNums[$s]
            if ($total -eq 0 -and $v -eq 10) {
                $total = 10
            } else {
                $total = $total * 10 + $v
            }
            $found = $true
        } elseif ($found) {
            break
        }
    }
    if ($found) { return $total }

    # 无数字时按原名 Unicode 排序
    return [int]::MaxValue
}

function Get-FileEncoding ($path) {
    # 尝试 UTF-8，回退到系统默认编码
    [System.Text.Encoding]::UTF8
}

function Split-MarkdownBlocks ($content) {
    # 按空行分段，过滤空段落和 Markdown 分隔线
    $paragraphs = $content -split "\r?\n\s*\r?\n" | ForEach-Object { $_.Trim() } | Where-Object {
        $_ -ne '' -and $_ -notmatch '^-{3,}$' -and $_ -notmatch '^(\*\s*){3,}$'
    }
    $blocks = @()
    $seq = 1
    foreach ($p in $paragraphs) {
        # 识别 1-6 级 Markdown 标题
        $type = if ($p -match '^#{1,6}\s') { 'title' } else { 'body' }
        # 去掉标题的 # 标记用于纯文本显示
        $clean = $p -replace '^#{1,6}\s*', ''
        $blocks += [ordered]@{
            id = "block-{0:D3}" -f $seq
            seqno = $seq
            type = $type
            content = $clean
            translation = $null
        }
        $seq++
    }
    return $blocks
}

function Align-TranslationBlocks ($sourceBlocks, $translationContent) {
    # 译文文件通常以 > 引用原文，后面跟多段译文。
    # 注意：原文引用可能是多行连续的（如通玄真经），需要合并为同一段原文引用。
    # 我们以「连续 > 块」作为分隔锚点，把紧随其后的段落合并为同一个原文 block 的译文。
    $lines = $translationContent -split "\r?\n"
    $transUnits = @()
    $currentOriginal = @()
    $currentTrans = @()
    $inQuote = $false

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^>\s*(.*)$') {
            $quoteLine = $matches[1]
            if (-not $inQuote -and ($currentOriginal.Count -gt 0 -or $currentTrans.Count -gt 0)) {
                # 之前在收集译文，现在遇到新的原文引用，先把上一个单元保存
                $transUnits += [ordered]@{
                    original = ($currentOriginal -join "`n").Trim()
                    translation = ($currentTrans -join "`n`n").Trim()
                }
                $currentOriginal = @()
                $currentTrans = @()
            }
            $currentOriginal += $quoteLine
            $inQuote = $true
        } elseif ($trimmed -ne '' -and $trimmed -notmatch '^#{1,6}\s' -and $trimmed -notmatch '^-{3,}$') {
            # 非空、非标题、非分隔线的行视为译文
            $inQuote = $false
            $currentTrans += $trimmed
        }
    }
    # 保存最后一个单元
    if ($currentOriginal.Count -gt 0 -or $currentTrans.Count -gt 0) {
        $transUnits += [ordered]@{
            original = ($currentOriginal -join "`n").Trim()
            translation = ($currentTrans -join "`n`n").Trim()
        }
    }

    # 按顺序将 sourceBlocks 与 transUnits 配对
    $aligned = @()
    $transIndex = 0
    for ($i = 0; $i -lt $sourceBlocks.Count; $i++) {
        $block = [ordered]@{}
        $sourceBlocks[$i].Keys | ForEach-Object { $block[$_] = $sourceBlocks[$i][$_] }
        # 标题段落不附加译文
        if ($sourceBlocks[$i].type -eq 'title') {
            $block.translation = $null
        } elseif ($transIndex -lt $transUnits.Count) {
            $block.translation = $transUnits[$transIndex].translation
            $transIndex++
        }
        $aligned += $block
    }
    return $aligned
}

function Read-TextFile ($path) {
    # 使用 UTF-8 读取，并跳过 BOM
    $reader = New-Object System.IO.StreamReader($path, $true)
    $text = $reader.ReadToEnd()
    $reader.Close()
    return $text
}

function Process-Book ($bookPath, $categoryId, $categoryName) {
    $bookName = Split-Path $bookPath -Leaf
    $bookSlug = Get-Slug $bookName

    $sourceDir = Join-Path $bookPath "原文"
    $transDir = Join-Path $bookPath "译文"
    $blockDir = Join-Path $bookPath "原文块"

    $chapters = @()

    # 优先使用原文块 JSON
    if (Test-Path $blockDir) {
        $jsonFiles = Get-ChildItem $blockDir -Filter "*.json" | Sort-Object { Get-SortKey $_.Name }
        foreach ($jf in $jsonFiles) {
            try {
                $json = Read-TextFile $jf.FullName | ConvertFrom-Json
                $chapterTitle = $jf.BaseName
                if ($json.metadata -and $json.metadata.source_file) {
                    $chapterTitle = [System.IO.Path]::GetFileNameWithoutExtension($json.metadata.source_file)
                }
                $blocks = @()
                foreach ($b in $json.blocks) {
                    $type = $b.type
                    $content = $b.content -replace '^#{1,6}\s*', ''
                    $translation = if ($b.translation -and $type -ne 'title') {
                        ($b.translation -replace '^#{1,6}\s*', '') -replace '^\s*>\s*', ''
                    } else {
                        $null
                    }
                    # 如果 content 是 Markdown 标题但 type 未标记，则修正 type
                    if ($type -eq 'body' -and $b.content -match '^#{1,6}\s') {
                        $type = 'title'
                        $translation = $null
                    }
                    $blocks += [ordered]@{
                        id = $b.id
                        seqno = [int]$b.seqno
                        type = $type
                        content = $content
                        translation = $translation
                    }
                }
                $chapters += [ordered]@{
                    id = (Get-Slug $chapterTitle) -replace '\.', '-'
                    title = Get-Slug $chapterTitle
                    blocks = $blocks
                }
            } catch {
                Write-Warning "解析 JSON 失败: $($jf.FullName) - $($_.Exception.Message)"
            }
        }
    }

    # fallback：解析原文/译文 Markdown
    if ($chapters.Count -eq 0 -and (Test-Path $sourceDir)) {
        $sourceFiles = Get-ChildItem $sourceDir -Filter "*.md" | Sort-Object { Get-SortKey $_.Name }
        foreach ($sf in $sourceFiles) {
            $chapterTitle = $sf.BaseName
            $sourceContent = Read-TextFile $sf.FullName
            $sourceBlocks = Split-MarkdownBlocks $sourceContent

            # 尝试找对应译文
            $transPath = Join-Path $transDir $sf.Name
            if (Test-Path $transPath) {
                $transContent = Read-TextFile $transPath
                $sourceBlocks = Align-TranslationBlocks $sourceBlocks $transContent
            }

            $chapters += [ordered]@{
                id = (Get-Slug $chapterTitle) -replace '\.', '-'
                title = Get-Slug $chapterTitle
                blocks = $sourceBlocks
            }
        }
    }

    if ($chapters.Count -eq 0) { return $null }

    return [ordered]@{
        id = $bookSlug -replace '\.', '-'
        title = $bookSlug
        category = $categoryName
        categoryId = $categoryId
        chapters = $chapters
    }
}

# 主流程
$categories = @()
$categoryDirs = Get-ChildItem $GujiRoot -Directory | Sort-Object { Get-SortKey $_.Name }

foreach ($catDir in $categoryDirs) {
    $categoryName = $catDir.Name
    $categoryId = Get-Slug $categoryName
    $books = @()

    $bookDirs = Get-ChildItem $catDir.FullName -Directory | Sort-Object { Get-SortKey $_.Name }
    foreach ($bookDir in $bookDirs) {
        $book = Process-Book $bookDir.FullName $categoryId $categoryName
        if ($book) {
            $books += $book
        }
    }

    if ($books.Count -gt 0) {
        $categories += [ordered]@{
            id = $categoryId
            name = $categoryName
            books = $books
        }
    }
}

$categoryOrder = @('道源', '玄契', '炼性', '金丹')
$categories = $categories | Sort-Object {
    $idx = $categoryOrder.IndexOf($_.name)
    if ($idx -ge 0) { $idx } else { 999 }
}

$output = [ordered]@{
    generatedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
    totalCategories = $categories.Count
    totalBooks = ($categories | ForEach-Object { $_.books.Count } | Measure-Object -Sum).Sum
    categories = $categories
}

# 确保输出目录存在
$outDir = Split-Path $OutputFile -Parent
if (-not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

$output | ConvertTo-Json -Depth 20 | Out-File -FilePath $OutputFile -Encoding UTF8
Write-Host "已生成: $OutputFile"
Write-Host "分类数: $($categories.Count)"
foreach ($c in $categories) {
    Write-Host "  $($c.name): $($c.books.Count) 本"
}
