# 扫描本地古籍目录，生成站点数据（目录 catalog.json + 每本书单独的 books/<id>.json）
# 用法：在 PowerShell 中执行 .\scripts\scan-guji.ps1 [-GujiRoot <古籍目录>]
#
# 排序：编辑 <古籍目录>\排序.txt 中各行的顺序后重跑本脚本即可。
#       新增的分类/书籍会自动追加到该文件对应区域末尾。

param(
    [string]$GujiRoot = ""
)

$ErrorActionPreference = "Continue"

Write-Host "脚本启动..."

# --- 定位古籍目录 ---
if (-not $GujiRoot) {
    $candidates = @(
        (Join-Path $PSScriptRoot "..\..\古籍"),
        (Join-Path $PSScriptRoot "..\..\..\古文整理本地\古籍")
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $GujiRoot = (Resolve-Path $c).Path; break }
    }
}
if (-not $GujiRoot -or -not (Test-Path $GujiRoot)) {
    Write-Error "找不到古籍目录，请用 -GujiRoot 指定"
    exit 1
}

$OutputDir = Join-Path $PSScriptRoot "..\data"
$CatalogFile = Join-Path $OutputDir "catalog.json"
$BooksOutDir = Join-Path $OutputDir "books"
$OrderFile = Join-Path $GujiRoot "排序.txt"

Write-Host "GujiRoot: $GujiRoot"
Write-Host "OutputDir: $OutputDir"
Write-Host "OrderFile: $OrderFile"

function Get-Slug ($name) {
    # 去掉前导数字编号，如 "01_太上老君说常清静经" -> "太上老君说常清静经"
    $name -replace '^\d+[-_]', ''
}

function Convert-ChineseNumber ($text) {
    # 正确解析中文数字：一=1 ... 十=10, 十一=11, 二十=20, 二十一=21, 一百二十三=123
    $digits = @{ '零' = 0; '一' = 1; '二' = 2; '两' = 2; '三' = 3; '四' = 4; '五' = 5; '六' = 6; '七' = 7; '八' = 8; '九' = 9 }
    $units = @{ '十' = 10; '百' = 100; '千' = 1000 }
    $total = 0; $number = 0
    foreach ($c in $text.ToCharArray()) {
        $s = $c.ToString()
        if ($digits.ContainsKey($s)) { $number = $digits[$s] }
        elseif ($units.ContainsKey($s)) {
            if ($number -eq 0) { $number = 1 }
            $total += $number * $units[$s]
            $number = 0
        } else { return -1 }
    }
    return $total + $number
}

function Get-SortKey ($name) {
    $base = [System.IO.Path]::GetFileNameWithoutExtension($name)

    # 1. 前导阿拉伯数字，如 "01_xxx"
    if ($base -match '^(\d+)') { return [int]$matches[1] }

    # 2. "第N" 编号（可出现在任意位置），如 "道原第一" "第十二章"
    if ($base -match '第([零一二两三四五六七八九十百千]+|\d+)') {
        $n = $matches[1]
        if ($n -match '^\d+$') { return [int]$n }
        $v = Convert-ChineseNumber $n
        if ($v -ge 0) { return $v }
    }

    # 3. 前导中文数字（可带 卷/篇 前缀），如 "一宇" "卷三"
    if ($base -match '^[卷篇]?([零一二两三四五六七八九十百千]+)') {
        $v = Convert-ChineseNumber $matches[1]
        if ($v -ge 0) { return $v }
    }

    return [int]::MaxValue
}

function Read-TextFile ($path) {
    $reader = New-Object System.IO.StreamReader($path, $true)
    $text = $reader.ReadToEnd()
    $reader.Close()
    return $text
}

function Split-MarkdownBlocks ($content) {
    $paragraphs = $content -split "\r?\n\s*\r?\n" | ForEach-Object { $_.Trim() } | Where-Object {
        $_ -ne '' -and $_ -notmatch '^-{3,}$' -and $_ -notmatch '^(\*\s*){3,}$'
    }
    $blocks = @()
    $seq = 1
    foreach ($p in $paragraphs) {
        $type = if ($p -match '^#{1,6}\s') { 'title' } else { 'body' }
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
    # 译文文件以 > 引用原文（可能连续多行），其后段落为译文
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
            $inQuote = $false
            $currentTrans += $trimmed
        }
    }
    if ($currentOriginal.Count -gt 0 -or $currentTrans.Count -gt 0) {
        $transUnits += [ordered]@{
            original = ($currentOriginal -join "`n").Trim()
            translation = ($currentTrans -join "`n`n").Trim()
        }
    }

    $aligned = @()
    $transIndex = 0
    for ($i = 0; $i -lt $sourceBlocks.Count; $i++) {
        $block = [ordered]@{}
        $sourceBlocks[$i].Keys | ForEach-Object { $block[$_] = $sourceBlocks[$i][$_] }
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

# ======= 读取手动排序文件 =======
# 格式：
#   # 注释
#   [分类]        -> 分类顺序
#   [分类名]      -> 该分类下书籍顺序（书名一行一个，使用显示名）
$userCatOrder = @()
$userBookOrders = @{}

if (Test-Path $OrderFile) {
    $section = $null
    foreach ($raw in (Read-TextFile $OrderFile) -split "\r?\n") {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        if ($line -match '^\[(.+)\]$') {
            $section = $matches[1].Trim()
            continue
        }
        if ($section -eq '分类') {
            $userCatOrder += $line
        } elseif ($section) {
            if (-not $userBookOrders.ContainsKey($section)) { $userBookOrders[$section] = @() }
            $userBookOrders[$section] += $line
        }
    }
    Write-Host "已读取排序文件: 分类 $($userCatOrder.Count) 个, 书籍分组 $($userBookOrders.Keys.Count) 个"
} else {
    # 首次运行：使用默认分类顺序
    $userCatOrder = @('道源', '玄契', '炼性', '金丹')
    Write-Host "未找到排序文件，使用默认分类顺序，稍后将生成: $OrderFile"
}

# ======= 主流程 =======
$categories = @()
$categoryDirs = Get-ChildItem $GujiRoot -Directory | Sort-Object { Get-SortKey $_.Name }

foreach ($catDir in $categoryDirs) {
    $categoryName = $catDir.Name
    $categoryId = Get-Slug $categoryName
    $books = @()

    $bookDirs = Get-ChildItem $catDir.FullName -Directory | Sort-Object { Get-SortKey $_.Name }
    foreach ($bookDir in $bookDirs) {
        $book = Process-Book $bookDir.FullName $categoryId $categoryName
        if ($book) { $books += $book }
    }

    if ($books.Count -gt 0) {
        # 按手动顺序排序；未列入的按默认规则排在后面
        $orderList = $userBookOrders[$categoryName]
        $books = $books | Sort-Object {
            $i = -1
            if ($orderList) { $i = [array]::IndexOf($orderList, $_.title) }
            if ($i -ge 0) { $i } else { 10000 }
        }, { Get-SortKey $_.title }

        $categories += [ordered]@{
            id = $categoryId
            name = $categoryName
            books = $books
        }
    }
}

# 分类排序
$categories = $categories | Sort-Object {
    $i = [array]::IndexOf($userCatOrder, $_.name)
    if ($i -ge 0) { $i } else { 10000 }
}, { Get-SortKey $_.name }

# ======= 回写排序文件（保留用户顺序，追加新增条目） =======
$orderLines = @()
$orderLines += '# 玄门正典 · 排序文件'
$orderLines += '# 修改方法：调整下面各行的先后顺序，保存后重新运行 scripts\scan-guji.ps1 即可生效'
$orderLines += '# [分类] 区域决定分类顺序；每个 [分类名] 区域决定该分类下的书籍顺序'
$orderLines += '# 新增的分类或书籍会自动追加到对应区域末尾，可再手动调整位置'
$orderLines += ''
$orderLines += '[分类]'
foreach ($c in $categories) { $orderLines += $c.name }
foreach ($c in $categories) {
    $orderLines += ''
    $orderLines += "[$($c.name)]"
    foreach ($b in $c.books) { $orderLines += $b.title }
}
($orderLines -join "`r`n") | Out-File -FilePath $OrderFile -Encoding UTF8
Write-Host "已更新排序文件: $OrderFile"

# ======= 输出数据 =======
if (-not (Test-Path $BooksOutDir)) {
    New-Item -ItemType Directory -Path $BooksOutDir -Force | Out-Null
}

$catalogCategories = @()
$generatedIds = @{}

foreach ($cat in $categories) {
    $catalogBooks = @()
    foreach ($book in $cat.books) {
        $generatedIds[$book.id] = $true

        # 单书完整数据
        $bookFile = Join-Path $BooksOutDir ($book.id + '.json')
        $book | ConvertTo-Json -Depth 20 | Out-File -FilePath $bookFile -Encoding UTF8

        # 目录条目（不含正文）
        $chapList = @()
        foreach ($ch in $book.chapters) {
            $chapList += [ordered]@{ id = $ch.id; title = $ch.title }
        }
        $catalogBooks += [ordered]@{
            id = $book.id
            title = $book.title
            category = $book.category
            categoryId = $book.categoryId
            chapterCount = $book.chapters.Count
            chapters = $chapList
        }
    }
    $catalogCategories += [ordered]@{
        id = $cat.id
        name = $cat.name
        books = $catalogBooks
    }
}

# 清理已删除书籍的旧文件
Get-ChildItem $BooksOutDir -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object {
    -not $generatedIds.ContainsKey($_.BaseName)
} | ForEach-Object {
    Write-Host "清理过期文件: $($_.Name)"
    Remove-Item $_.FullName -Force
}

$catalog = [ordered]@{
    generatedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
    totalCategories = $catalogCategories.Count
    totalBooks = ($catalogCategories | ForEach-Object { $_.books.Count } | Measure-Object -Sum).Sum
    categories = $catalogCategories
}

$catalog | ConvertTo-Json -Depth 10 | Out-File -FilePath $CatalogFile -Encoding UTF8

Write-Host "已生成目录: $CatalogFile"
Write-Host "已生成单书数据: $BooksOutDir ($($generatedIds.Count) 本)"
foreach ($c in $categories) {
    Write-Host "  $($c.name): $($c.books.Count) 本"
}
