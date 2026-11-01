#Requires -Version 5.1
<#
  Save editor - Midnight Club L.A. Recompiled (ReXGlue / mc4.sav)

  Formato (engenharia reversa, validado byte a byte contra um save real):

    header : u32 capacidade | u32 numSecoes
    secao  : u32 nameLen | name[nameLen] | u8 flag | u32 size | data[size]   (repete)

    Inteiros sao BIG-ENDIAN (o jogo e PowerPC / Xbox 360).
    Nao existe checksum: o walk das secoes termina exatamente no EOF, entao
    patch direto funciona - nao precisa rehash nem reassinar nada.

  Registro da tabela Stats (16 bytes, fourcc em offset absoluto % 16 == 2):
    fourcc[4] | u32 id @+4 | u8 tipo @+8 | u24 @+9 | valor @+12
    tipo 0x28 = float, demais = inteiro.

  Uso:
    .\mcla-save-editor.ps1 info
    .\mcla-save-editor.ps1 stats
    .\mcla-save-editor.ps1 garage
    .\mcla-save-editor.ps1 setcar 2 vp_aud_r8_08
    .\mcla-save-editor.ps1 find 5104
    .\mcla-save-editor.ps1 money
    .\mcla-save-editor.ps1 money 999999
    .\mcla-save-editor.ps1 get Career 0x2D9
    .\mcla-save-editor.ps1 set Career 0x2D9 999999
    .\mcla-save-editor.ps1 diff <saveA> <saveB>
    .\mcla-save-editor.ps1 selftest

  Feche o jogo antes de editar. Todo write gera backup .bak-<timestamp>.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'info',
    [Parameter(Position = 1)][string]$Arg1,
    [Parameter(Position = 2)][string]$Arg2,
    [Parameter(Position = 3)][string]$Arg3,
    [string]$Save
)

$ErrorActionPreference = 'Stop'

# Posicoes conhecidas, descobertas por busca de valor conhecido (dinheiro = 5104)
# e encontradas em duas secoes independentes. Toda escrita mantem as duas em
# sincronia, que e o estado em que o jogo as grava.
$KnownFields = @{
    money = @(
        # So a Career guarda o dinheiro. Stats+0x938 e o stat tPUR (carros
        # comprados), NAO um espelho: o jogo reescreve com a contagem de carros.
        @{ Section = 'Career'; Offset = 0x2D9; Note = 'dinheiro gastavel' }
    )
}

# Roster completo, extraido de tune/vehicle/0xe94bde63 (config mestre dentro de
# xarchive_cache.rpf). Nomes internos exatos: so estes carregam.
# vp_aud_r8_08 existe, mas no jogo original vem travado por Social Club e nao
# instancia so com edicao de save - precisa do mod no arquivo do jogo.
$Roster = @(
    'vp_am_vantage_07','vp_aud_r8_08','vp_aud_rs4_07','vp_buk_grandnational_87',
    'vp_chv_camaro_06','vp_chv_camaro_06_DUB','vp_chv_camaross_69','vp_chv_cobalt_05',
    'vp_chv_corvettez06_07','vp_chv_impala_96','vp_chv_police_96','vp_citybus_07',
    'vp_cry_300c_06','vp_dge_challenger_06','vp_dge_challenger_06_DUB',
    'vp_dge_challenger_70','vp_dge_charger_06','vp_dsn_280z_75','vp_duc_999r_06',
    'vp_duc_monster_s4r_07','vp_frd_boss302_69','vp_frd_cobra_04','vp_frd_focus_04',
    'vp_frd_gt_06','vp_frd_mustang_06','vp_kaw_ninja_zx14_06','vp_lam_gallardo_06',
    'vp_lam_miura_71','vp_lam_murcielago_06','vp_lam_murcielago_06_DUB',
    'vp_mbz_s600_07','vp_mbz_s600_07_DUB','vp_mbz_sl65_07','vp_mit_3000gt_99',
    'vp_mit_eclipse_99','vp_mit_evo_06','vp_mzd_rx7_95','vp_mzd_rx8_06',
    'vp_nsn_240sx_98','vp_nsn_350z_06','vp_nsn_skyline_99','vp_pon_solstice_06',
    'vp_pon_transam_79','vp_sln_s281_06','vp_sln_s7_06','vp_vw_golf_07',
    'vp_vw_golf_83','vp_vw_scirocco_88'
)

# "vp_aud_r8_08" -> "08 R8", no mesmo formato que o jogo usa no rotulo da lista.
function Get-AutoLabel {
    param([string]$Prefab)
    if ($Prefab -match '^vp_[a-z0-9]+_(.+?)_(\d{2})(_DUB)?$') {
        $lbl = "{0} {1}" -f $Matches[2], ($Matches[1] -replace '_', ' ').ToUpper()
        if ($Matches[3]) { $lbl += ' DUB' }
        return $lbl
    }
    return $Prefab.ToUpper()
}

function Resolve-SavePath {
    param([string]$Explicit)
    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit -PathType Leaf)) {
            throw "Save nao encontrado: $Explicit"
        }
        return (Resolve-Path -LiteralPath $Explicit).Path
    }
    # ponytail: busca ingenua nos lugares obvios; se ficar lenta, passe -Save
    $roots = @(
        (Join-Path $PSScriptRoot '..'),
        (Join-Path $env:USERPROFILE 'Downloads')
    )
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        $hit = Get-ChildItem -LiteralPath $r -Filter 'mc4.sav' -File -Recurse -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    throw "mc4.sav nao encontrado. Passe -Save <caminho>."
}

function Get-BE32 {
    param([byte[]]$Bytes, [int]$Offset)
    $t = @($Bytes[$Offset], $Bytes[$Offset + 1], $Bytes[$Offset + 2], $Bytes[$Offset + 3])
    [array]::Reverse($t)
    return [BitConverter]::ToUInt32($t, 0)
}

function Get-BEFloat {
    param([byte[]]$Bytes, [int]$Offset)
    $t = @($Bytes[$Offset], $Bytes[$Offset + 1], $Bytes[$Offset + 2], $Bytes[$Offset + 3])
    [array]::Reverse($t)
    return [BitConverter]::ToSingle($t, 0)
}

function Set-BE32 {
    param([byte[]]$Bytes, [int]$Offset, [uint32]$Value)
    $t = [BitConverter]::GetBytes($Value)
    [array]::Reverse($t)
    for ($i = 0; $i -lt 4; $i++) { $Bytes[$Offset + $i] = $t[$i] }
}

# Percorre as secoes. Se o walk nao terminar exatamente no EOF, o arquivo nao e
# um mc4.sav valido (ou esta corrompido) e nos recusamos a escrever nele.
function Get-Sections {
    param([byte[]]$Bytes)
    $sections = New-Object System.Collections.ArrayList
    $o = 8
    $len = $Bytes.Length
    while ($o + 4 -le $len) {
        $nameLen = Get-BE32 $Bytes $o
        if ($nameLen -eq 0 -or $nameLen -gt 64) { break }
        if ($o + 4 + $nameLen + 5 -gt $len) { break }
        $name = [Text.Encoding]::ASCII.GetString($Bytes, $o + 4, [int]$nameLen)
        if ($name -notmatch '^[\x20-\x7E]+$') { break }
        $flag = $Bytes[$o + 4 + $nameLen]
        $size = Get-BE32 $Bytes ($o + 4 + $nameLen + 1)
        $data = $o + 4 + $nameLen + 5
        if ($data + $size -gt $len) { break }
        [void]$sections.Add([pscustomobject]@{
            Name = $name; Flag = $flag; Size = [int]$size; Data = [int]$data
        })
        $o = $data + $size
    }
    return [pscustomobject]@{
        Sections = $sections
        EndedAt  = $o
        Valid    = ($o -eq $len -and $sections.Count -gt 0)
    }
}

function Open-Save {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $walk = Get-Sections $bytes
    if (-not $walk.Valid) {
        throw ("Estrutura invalida: o walk parou em 0x{0:X} mas o arquivo tem 0x{1:X} bytes. " +
               "Nao vou escrever num save que nao consigo validar." -f $walk.EndedAt, $bytes.Length)
    }
    return [pscustomobject]@{ Path = $Path; Bytes = $bytes; Walk = $walk }
}

function Get-SectionByName {
    param($Doc, [string]$Name)
    $s = $Doc.Walk.Sections | Where-Object { $_.Name -eq $Name }
    if (-not $s) { throw "Secao '$Name' nao existe neste save." }
    return $s
}

function Get-SectionAt {
    param($Doc, [int]$Absolute)
    return $Doc.Walk.Sections | Where-Object {
        $Absolute -ge $_.Data -and $Absolute -lt ($_.Data + $_.Size)
    } | Select-Object -First 1
}

function Save-Bytes {
    param($Doc, [switch]$NoBackup)
    # Revalida antes de gravar: o tamanho nunca muda e a estrutura tem de
    # continuar fechando no EOF.
    $check = Get-Sections $Doc.Bytes
    if (-not $check.Valid) { throw "Abortado: a edicao quebraria a estrutura do save." }
    if (-not $NoBackup) {
        $bak = "{0}.bak-{1}" -f $Doc.Path, (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $Doc.Path -Destination $bak
        Write-Host "backup: $bak" -ForegroundColor DarkGray
    }
    [IO.File]::WriteAllBytes($Doc.Path, $Doc.Bytes)
}

function Convert-ToInt {
    param([string]$Text)
    if ($Text -match '^0[xX]') { return [Convert]::ToInt64($Text.Substring(2), 16) }
    return [Convert]::ToInt64($Text, 10)
}

function Read-CString {
    param([byte[]]$Bytes, [int]$Offset, [int]$Max)
    $limit = [Math]::Min($Offset + $Max, $Bytes.Length)
    $end = $Offset
    # para no \0 e tambem em qualquer byte nao imprimivel (padding 0xCD do jogo)
    while ($end -lt $limit -and $Bytes[$end] -ge 0x20 -and $Bytes[$end] -le 0x7E) { $end++ }
    if ($end -eq $Offset) { return '' }
    return [Text.Encoding]::ASCII.GetString($Bytes, $Offset, $end - $Offset)
}

function Get-StatRecords {
    param($Doc)
    $s = Get-SectionByName $Doc 'Stats'
    $b = $Doc.Bytes
    $out = New-Object System.Collections.ArrayList
    # fourcc fica em offset absoluto % 16 == 2; comeca no primeiro alinhado
    $start = $s.Data + ((2 - ($s.Data % 16)) + 16) % 16
    for ($o = $start; $o -lt ($s.Data + $s.Size - 16); $o += 16) {
        $key = [Text.Encoding]::ASCII.GetString($b, $o, 4)
        if ($key -notmatch '^[A-Za-z][A-Za-z0-9]{3}$') { continue }
        $type = $b[$o + 8]
        [void]$out.Add([pscustomobject]@{
            Offset  = $o
            Key     = $key
            Id      = Get-BE32 $b ($o + 4)
            Type    = $type
            Int     = Get-BE32 $b ($o + 12)
            Float   = Get-BEFloat $b ($o + 12)
            # 0x28 e 0x00 guardam float (ex: ghTC = 0x3F386BED = 0.7204)
            IsFloat = ($type -eq 0x28 -or $type -eq 0x00)
        })
    }
    return $out
}

function Find-Value {
    param($Doc, [int64]$Value)
    $b = $Doc.Bytes
    $u = [BitConverter]::GetBytes([uint32]$Value); [array]::Reverse($u)
    $f = [BitConverter]::GetBytes([float]$Value);  [array]::Reverse($f)
    $pats = @(@{ Name = 'u32 BE'; P = $u }, @{ Name = 'f32 BE'; P = $f })
    $hits = New-Object System.Collections.ArrayList
    $limit = $b.Length - 4
    foreach ($pat in $pats) {
        $p = $pat.P
        for ($o = 0; $o -le $limit; $o++) {
            if ($b[$o] -ne $p[0]) { continue }
            if ($b[$o + 1] -ne $p[1] -or $b[$o + 2] -ne $p[2] -or $b[$o + 3] -ne $p[3]) { continue }
            $sec = Get-SectionAt $Doc $o
            $name = '???'; $rel = 0
            if ($sec) { $name = $sec.Name; $rel = $o - $sec.Data }
            [void]$hits.Add([pscustomobject]@{
                Encoding = $pat.Name; Absolute = $o; Section = $name; Relative = $rel
            })
        }
    }
    return $hits
}

# ---------------------------------------------------------------- comandos

switch ($Command.ToLower()) {

    'info' {
        $doc = Open-Save (Resolve-SavePath $Save)
        Write-Host "save : $($doc.Path)"
        Write-Host ("bytes: {0:N0}   capacidade={1}  secoes={2}" -f $doc.Bytes.Length,
            (Get-BE32 $doc.Bytes 0), (Get-BE32 $doc.Bytes 4))
        Write-Host "estrutura valida: walk fechou no EOF, sem checksum" -ForegroundColor Green
        Write-Host ''
        $doc.Walk.Sections | Format-Table -AutoSize `
            @{ L = 'SECAO';   E = { $_.Name } },
            @{ L = 'FLAG';    E = { $_.Flag } },
            @{ L = 'DATA@';   E = { '0x{0:X}' -f $_.Data } },
            @{ L = 'TAMANHO'; E = { '{0:N0}' -f $_.Size } }
        foreach ($fld in $KnownFields.money) {
            $s = Get-SectionByName $doc $fld.Section
            $v = Get-BE32 $doc.Bytes ($s.Data + $fld.Offset)
            Write-Host ("money  {0}+0x{1:X} = {2:N0}   ({3})" -f $fld.Section, $fld.Offset, $v, $fld.Note)
        }
    }

    'stats' {
        $doc = Open-Save (Resolve-SavePath $Save)
        $recs = Get-StatRecords $doc
        Write-Host ("{0} registros de stat" -f $recs.Count) -ForegroundColor Green
        $recs | Format-Table -AutoSize `
            @{ L = 'OFF';   E = { '0x{0:X}' -f $_.Offset } },
            @{ L = 'KEY';   E = { $_.Key } },
            @{ L = 'ID';    E = { $_.Id } },
            @{ L = 'TIPO';  E = { '0x{0:X2}' -f $_.Type } },
            @{ L = 'VALOR'; E = { if ($_.IsFloat) { '{0:N4}' -f $_.Float } else { '{0:N0}' -f $_.Int } } }
    }

    'garage' {
        # Slots de 8176 bytes dentro de LocalOptions. No slot: nome do prefab em
        # +0 (terminado em \0, padding 0xCD) e a placa em +2186. Slot livre tem
        # a string literal "blank" no lugar do nome.
        $doc = Open-Save (Resolve-SavePath $Save)
        $lo = Get-SectionByName $doc 'LocalOptions'
        $first = $lo.Data + 0x24FD
        $stride = 8176
        $rows = New-Object System.Collections.ArrayList
        $n = 0
        for ($o = $first; $o + $stride -le ($lo.Data + $lo.Size); $o += $stride) {
            $name = Read-CString $doc.Bytes $o 40
            $plate = Read-CString $doc.Bytes ($o + 2186) 16
            $car = $name
            if ($name -eq 'blank' -or $name -eq '') { $car = '<livre>' }
            [void]$rows.Add([pscustomobject]@{
                Slot = $n; Offset = $o; Car = $car; Plate = $plate
            })
            $n++
        }
        $busy = @($rows | Where-Object { $_.Car -ne '<livre>' }).Count
        Write-Host ("{0} slots | {1} ocupados | {2} livres" -f $rows.Count, $busy, ($rows.Count - $busy)) -ForegroundColor Green
        $rows | Format-Table -AutoSize `
            @{ L = 'SLOT';  E = { $_.Slot } },
            @{ L = 'NOME@'; E = { '0x{0:X}' -f $_.Offset } },
            @{ L = 'CARRO'; E = { $_.Car } },
            @{ L = 'PLACA'; E = { $_.Plate } }
    }

    'roster' {
        Write-Host ("{0} veiculos no roster do jogo (nome interno exato)" -f $Roster.Count) -ForegroundColor Green
        Write-Host "so estes carregam; qualquer outro nome deixa o slot vazio" -ForegroundColor DarkGray
        Write-Host ''
        foreach ($r in $Roster) { Write-Host ("  {0,-26} {1}" -f $r, (Get-AutoLabel $r)) }
    }

    'cars' {
        # O jogo le os slots da garagem EM SEQUENCIA a partir do 0, e so ate
        # esta contagem. Nome em slot alem da contagem fica invisivel.
        #   LocalOptions+0x53F = quantidade de carros
        #   LocalOptions+0x543 = indice do ultimo (= quantidade - 1)
        $doc = Open-Save (Resolve-SavePath $Save)
        $lo = Get-SectionByName $doc 'LocalOptions'
        $cnt = $lo.Data + 0x53F
        $idx = $lo.Data + 0x543
        if (-not $Arg1) {
            Write-Host ("carros: {0}   ultimo indice: {1}" -f $doc.Bytes[$cnt], $doc.Bytes[$idx])
            break
        }
        $n = [int](Convert-ToInt $Arg1)
        if ($n -lt 1 -or $n -gt 29) { throw "use um valor entre 1 e 29" }
        $old = $doc.Bytes[$cnt]
        $doc.Bytes[$cnt] = [byte]$n
        $doc.Bytes[$idx] = [byte]($n - 1)
        Save-Bytes $doc
        Write-Host ("carros: {0} -> {1} (indice do ultimo: {2})" -f $old, $n, ($n - 1)) -ForegroundColor Green
    }

    'setcar' {
        # Escreve o nome do prefab no campo de 32 bytes em +0 do slot. E a
        # alteracao minima possivel: o resto do slot fica com a config que o
        # jogo ja deixou ali, em vez de herdar pecas de outro veiculo.
        if (-not $Arg1 -or -not $Arg2) { throw "uso: setcar <slot> <nomeDoPrefab> [rotulo]" }
        $doc = Open-Save (Resolve-SavePath $Save)
        $lo = Get-SectionByName $doc 'LocalOptions'
        $slot = [int](Convert-ToInt $Arg1)
        if ($slot -lt 0) { throw "slot invalido" }
        $o = $lo.Data + 0x24FD + ($slot * 8176)
        if ($o + 8176 -gt ($lo.Data + $lo.Size)) { throw "slot $slot nao existe neste save" }
        $name = $Arg2
        if ($name.Length -gt 31) { throw "nome passa dos 31 chars do campo" }
        if ($name -notmatch '^[\x20-\x7E]+$') { throw "nome tem de ser ASCII imprimivel" }
        if ($Roster -notcontains $name) {
            Write-Host "aviso: '$name' nao esta no roster conhecido; o jogo provavelmente nao vai carregar" -ForegroundColor Yellow
        }
        $old = Read-CString $doc.Bytes $o 40
        # O jogo grava nome + \0 e preenche o resto do campo com 0xCD, nao com
        # zero. Reproduzimos igual para o slot ficar byte-identico a uma compra.
        $ascii = [Text.Encoding]::ASCII.GetBytes($name)
        for ($i = 0; $i -lt 32; $i++) {
            if ($i -lt $ascii.Length) { $doc.Bytes[$o + $i] = $ascii[$i] }
            elseif ($i -eq $ascii.Length) { $doc.Bytes[$o + $i] = 0 }
            else { $doc.Bytes[$o + $i] = 0xCD }
        }
        # +32: rotulo mostrado na lista da garagem, outro campo de 32 bytes.
        # Sempre escrevemos: sem ele a linha sai em branco mesmo com o carro
        # carregando certo. Sem rotulo explicito, derivamos do proprio prefab.
        $label = $Arg3
        if (-not $label) { $label = Get-AutoLabel $name }
        if ($label.Length -gt 31) { throw "rotulo passa dos 31 chars" }
        if ($label -notmatch '^[\x20-\x7E]+$') { throw "rotulo tem de ser ASCII imprimivel" }
        # 33 bytes: o jogo preenche ate +64 inclusive com 0xCD.
        $lab = [Text.Encoding]::ASCII.GetBytes($label)
        for ($i = 0; $i -lt 33; $i++) {
            if ($i -lt $lab.Length) { $doc.Bytes[$o + 32 + $i] = $lab[$i] }
            elseif ($i -eq $lab.Length) { $doc.Bytes[$o + 32 + $i] = 0 }
            else { $doc.Bytes[$o + 32 + $i] = 0xCD }
        }
        Save-Bytes $doc
        Write-Host ("slot {0} (0x{1:X}): '{2}' -> '{3}' [{4}]" -f $slot, $o, $old, $name, $label) -ForegroundColor Green
    }

    'find' {
        if (-not $Arg1) { throw "uso: find <valor>" }
        $doc = Open-Save (Resolve-SavePath $Save)
        $v = Convert-ToInt $Arg1
        $hits = Find-Value $doc $v
        if ($hits.Count -eq 0) { Write-Host "nenhuma ocorrencia de $v neste save"; break }
        Write-Host ("{0} ocorrencia(s) de {1}" -f $hits.Count, $v) -ForegroundColor Green
        $hits | Format-Table -AutoSize `
            @{ L = 'ENCODING'; E = { $_.Encoding } },
            @{ L = 'ABS';      E = { '0x{0:X}' -f $_.Absolute } },
            @{ L = 'SECAO';    E = { $_.Section } },
            @{ L = 'REL';      E = { '0x{0:X}' -f $_.Relative } }
        Write-Host "para gravar:  .\mcla-save-editor.ps1 set <SECAO> <REL> <novoValor>" -ForegroundColor DarkGray
    }

    'get' {
        if (-not $Arg1 -or -not $Arg2) { throw "uso: get <Secao> <offsetRelativo>" }
        $doc = Open-Save (Resolve-SavePath $Save)
        $s = Get-SectionByName $doc $Arg1
        $off = [int](Convert-ToInt $Arg2)
        if ($off -lt 0 -or $off + 4 -gt $s.Size) { throw "offset fora da secao '$Arg1' (size $($s.Size))" }
        $abs = $s.Data + $off
        Write-Host ("{0}+0x{1:X} (abs 0x{2:X})  u32={3:N0}  f32={4}" -f `
            $s.Name, $off, $abs, (Get-BE32 $doc.Bytes $abs), (Get-BEFloat $doc.Bytes $abs))
    }

    'set' {
        if (-not $Arg1 -or -not $Arg2 -or -not $Arg3) { throw "uso: set <Secao> <offsetRelativo> <valor>" }
        $doc = Open-Save (Resolve-SavePath $Save)
        $s = Get-SectionByName $doc $Arg1
        $off = [int](Convert-ToInt $Arg2)
        if ($off -lt 0 -or $off + 4 -gt $s.Size) { throw "offset fora da secao '$Arg1' (size $($s.Size))" }
        $new = Convert-ToInt $Arg3
        if ($new -lt 0 -or $new -gt [uint32]::MaxValue) { throw "valor fora do range u32" }
        # Career+0x2DD parece ser o grupo liberado, na ordem do config, onde
        # A0=0 (mais alto) ate D0=3. O save tem 2, que bate com C0, os carros
        # que o jogador pode comprar. Escrever 4 travou o jogo no carregamento,
        # entao a faixa valida vai ate 3.
        if ($s.Name -eq 'Career' -and $off -eq 0x2DD) {
            throw "Career+0x2DD nao e o grupo liberado: 0, 1 e 4 travaram o jogo. So o valor original funciona, nao escreva aqui."
        }
        $abs = $s.Data + $off
        $old = Get-BE32 $doc.Bytes $abs
        Set-BE32 $doc.Bytes $abs ([uint32]$new)
        Save-Bytes $doc
        Write-Host ("{0}+0x{1:X}: {2:N0} -> {3:N0}" -f $s.Name, $off, $old, $new) -ForegroundColor Green
    }

    'progress' {
        # Career+0x2E5 = quantidade de blocos. Os blocos tem 65 bytes e comecam
        # em Career+0x2E9; o ULTIMO byte de cada um e o flag de concluido.
        #   progress            -> quantas estao concluidas
        #   progress all        -> marca todas como concluidas
        #   progress <save>     -> copia os flags daquele save (para desfazer)
        $doc = Open-Save (Resolve-SavePath $Save)
        $s = Get-SectionByName $doc 'Career'
        $n = [int](Get-BE32 $doc.Bytes ($s.Data + 0x2E5))
        if ($n -lt 1 -or $n -gt 200) { throw "contagem de progressao implausivel: $n" }
        $base = $s.Data + 0x2E9
        $stride = 65
        if (-not $Arg1) {
            $done = 0
            for ($i = 0; $i -lt $n; $i++) { if ($doc.Bytes[$base + $i * $stride + 64] -ne 0) { $done++ } }
            Write-Host ("progressao: {0} de {1} concluidas" -f $done, $n)
            break
        }
        if ($Arg1 -eq 'all') {
            for ($i = 0; $i -lt $n; $i++) { $doc.Bytes[$base + $i * $stride + 64] = 1 }
            Save-Bytes $doc
            Write-Host ("todas as {0} progressoes marcadas como concluidas" -f $n) -ForegroundColor Green
            break
        }
        $ref = Open-Save (Resolve-SavePath $Arg1)
        $rs = Get-SectionByName $ref 'Career'
        $rn = [int](Get-BE32 $ref.Bytes ($rs.Data + 0x2E5))
        if ($rn -ne $n) { throw "o save de referencia tem $rn blocos e este tem $n" }
        $rbase = $rs.Data + 0x2E9
        $chg = 0
        for ($i = 0; $i -lt $n; $i++) {
            $v = $ref.Bytes[$rbase + $i * $stride + 64]
            if ($doc.Bytes[$base + $i * $stride + 64] -ne $v) { $chg++ }
            $doc.Bytes[$base + $i * $stride + 64] = $v
        }
        Save-Bytes $doc
        Write-Host ("flags copiados do save de referencia ({0} alterados)" -f $chg) -ForegroundColor Green
    }

    'rep' {
        # Career+0x2E1, logo depois do dinheiro no mesmo struct. Valor unico,
        # sem espelho em outra secao.
        $doc = Open-Save (Resolve-SavePath $Save)
        $s = Get-SectionByName $doc 'Career'
        $abs = $s.Data + 0x2E1
        if (-not $Arg1) {
            Write-Host ("reputacao: {0:N0}   (Career+0x2E1)" -f (Get-BE32 $doc.Bytes $abs))
            break
        }
        $new = Convert-ToInt $Arg1
        if ($new -lt 0 -or $new -gt 2000000000) { throw "use um valor entre 0 e 2000000000" }
        $old = Get-BE32 $doc.Bytes $abs
        Set-BE32 $doc.Bytes $abs ([uint32]$new)
        Save-Bytes $doc
        Write-Host ("reputacao: {0:N0} -> {1:N0}" -f $old, $new) -ForegroundColor Green
    }

    'money' {
        $doc = Open-Save (Resolve-SavePath $Save)
        if (-not $Arg1) {
            foreach ($fld in $KnownFields.money) {
                $s = Get-SectionByName $doc $fld.Section
                Write-Host ("{0}+0x{1:X} = {2:N0}   ({3})" -f $fld.Section, $fld.Offset,
                    (Get-BE32 $doc.Bytes ($s.Data + $fld.Offset)), $fld.Note)
            }
            break
        }
        $new = Convert-ToInt $Arg1
        if ($new -lt 0 -or $new -gt 2000000000) { throw "use um valor entre 0 e 2000000000" }
        foreach ($fld in $KnownFields.money) {
            $s = Get-SectionByName $doc $fld.Section
            $abs = $s.Data + $fld.Offset
            $old = Get-BE32 $doc.Bytes $abs
            Set-BE32 $doc.Bytes $abs ([uint32]$new)
            Write-Host ("{0}+0x{1:X}: {2:N0} -> {3:N0}" -f $fld.Section, $fld.Offset, $old, $new)
        }
        Save-Bytes $doc
        Write-Host "ok" -ForegroundColor Green
    }

    'diff' {
        if (-not $Arg1 -or -not $Arg2) { throw "uso: diff <saveA> <saveB>" }
        $a = Open-Save (Resolve-SavePath $Arg1)
        $b = Open-Save (Resolve-SavePath $Arg2)
        if ($a.Bytes.Length -ne $b.Bytes.Length) {
            Write-Host ("tamanhos diferentes: {0:N0} vs {1:N0}" -f $a.Bytes.Length, $b.Bytes.Length) -ForegroundColor Yellow
        }
        $n = [Math]::Min($a.Bytes.Length, $b.Bytes.Length)
        $runs = New-Object System.Collections.ArrayList
        $o = 0
        while ($o -lt $n) {
            if ($a.Bytes[$o] -eq $b.Bytes[$o]) { $o++; continue }
            $start = $o
            while ($o -lt $n -and $a.Bytes[$o] -ne $b.Bytes[$o]) { $o++ }
            [void]$runs.Add([pscustomobject]@{ Start = $start; Length = $o - $start })
        }
        Write-Host ("{0} trecho(s) diferente(s)" -f $runs.Count) -ForegroundColor Green
        foreach ($r in $runs) {
            $sec = Get-SectionAt $a $r.Start
            $name = '???'; $rel = 0
            if ($sec) { $name = $sec.Name; $rel = $r.Start - $sec.Data }
            # alinha em 4 bytes pra ler como u32 de um jeito util
            $q = $r.Start - ($r.Start % 4)
            $line = "0x{0:X6}  {1,-14} +0x{2:X}  len={3}" -f $r.Start, $name, $rel, $r.Length
            if ($q + 4 -le $n) {
                $line += ("  u32: {0:N0} -> {1:N0}" -f (Get-BE32 $a.Bytes $q), (Get-BE32 $b.Bytes $q))
            }
            Write-Host $line
        }
    }

    'selftest' {
        $path = Resolve-SavePath $Save
        Write-Host "usando: $path`n" -ForegroundColor DarkGray
        $tmp = Join-Path $env:TEMP ("mc4-selftest-{0}.sav" -f (Get-Random))
        Copy-Item -LiteralPath $path -Destination $tmp
        $fail = 0
        try {
            $orig = [IO.File]::ReadAllBytes($tmp)
            $doc = Open-Save $tmp

            if (-not $doc.Walk.Valid) { Write-Host "FALHOU: walk invalido" -ForegroundColor Red; $fail++ }
            else { Write-Host "ok   walk fecha no EOF ($($doc.Walk.Sections.Count) secoes)" -ForegroundColor Green }

            $declared = Get-BE32 $doc.Bytes 4
            if ($declared -ne $doc.Walk.Sections.Count) {
                Write-Host "FALHOU: header declara $declared secoes, walk achou $($doc.Walk.Sections.Count)" -ForegroundColor Red; $fail++
            } else { Write-Host "ok   contagem de secoes do header bate com o walk" -ForegroundColor Green }

            $recs = Get-StatRecords $doc
            if ($recs.Count -lt 50) { Write-Host "FALHOU: so $($recs.Count) stats encontrados" -ForegroundColor Red; $fail++ }
            else { Write-Host "ok   tabela de stats: $($recs.Count) registros" -ForegroundColor Green }

            # as duas posicoes de dinheiro tem de concordar entre si
            $vals = @()
            foreach ($fld in $KnownFields.money) {
                $s = Get-SectionByName $doc $fld.Section
                $vals += (Get-BE32 $doc.Bytes ($s.Data + $fld.Offset))
            }
            if ($vals[0] -gt 2000000000) {
                Write-Host "AVISO: dinheiro fora de faixa plausivel ($($vals[0]))" -ForegroundColor Yellow
            } else { Write-Host "ok   dinheiro legivel ($($vals[0]))" -ForegroundColor Green }

            $lo = Get-SectionByName $doc 'LocalOptions'
            $cnt = $doc.Bytes[$lo.Data + 0x53F]
            $idx = $doc.Bytes[$lo.Data + 0x543]
            if ($idx -ne $cnt - 1) {
                Write-Host "AVISO: contagem de carros ($cnt) e indice ($idx) inconsistentes" -ForegroundColor Yellow
            } else { Write-Host "ok   contagem de carros $cnt com indice $idx" -ForegroundColor Green }

            # round trip: escreve valor novo, confere, restaura, compara byte a byte
            $s = Get-SectionByName $doc 'Career'
            $abs = $s.Data + 0x2D9
            $before = Get-BE32 $doc.Bytes $abs
            Set-BE32 $doc.Bytes $abs ([uint32]1234567)
            if ((Get-BE32 $doc.Bytes $abs) -ne 1234567) {
                Write-Host "FALHOU: write/read u32 BE" -ForegroundColor Red; $fail++
            } else { Write-Host "ok   write/read u32 big-endian" -ForegroundColor Green }

            Save-Bytes $doc -NoBackup
            $reread = Open-Save $tmp
            if ((Get-BE32 $reread.Bytes $abs) -ne 1234567) {
                Write-Host "FALHOU: valor nao persistiu" -ForegroundColor Red; $fail++
            } elseif (-not $reread.Walk.Valid) {
                Write-Host "FALHOU: estrutura quebrou depois de gravar" -ForegroundColor Red; $fail++
            } else { Write-Host "ok   valor persistiu e a estrutura continua valida" -ForegroundColor Green }

            Set-BE32 $reread.Bytes $abs ([uint32]$before)
            Save-Bytes $reread -NoBackup
            $final = [IO.File]::ReadAllBytes($tmp)
            if ($final.Length -ne $orig.Length) {
                Write-Host "FALHOU: tamanho do arquivo mudou" -ForegroundColor Red; $fail++
            } else {
                $diff = 0
                for ($i = 0; $i -lt $final.Length; $i++) { if ($final[$i] -ne $orig[$i]) { $diff++ } }
                if ($diff -ne 0) {
                    Write-Host "FALHOU: $diff bytes diferentes depois de restaurar" -ForegroundColor Red; $fail++
                } else { Write-Host "ok   round-trip byte-identico (0 bytes de diferenca)" -ForegroundColor Green }
            }
        } finally {
            Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        }
        if ($fail -gt 0) { Write-Host "`n$fail teste(s) falharam" -ForegroundColor Red; exit 1 }
        Write-Host "`ntodos os testes passaram" -ForegroundColor Green
    }

    default {
        throw "comando '$Command' desconhecido. Use: info | stats | garage | roster | cars | setcar | find | get | set | money | rep | progress | diff | selftest"
    }
}
