<#
    Monta um mod de desbloqueio de veiculos para o mod loader do LARecomp, a
    partir do SEU proprio tune/vehicle/vehicle.lst. Nenhum dado do jogo e
    redistribuido com este script.

    O jogo guarda, por veiculo, um Group (a classe do carro) e um
    UnlockingGroup (a classe que o jogador precisa ter alcancado para o carro
    aparecer na loja). Na maioria dos carros os dois sao iguais. Em 18 deles o
    UnlockingGroup e mais alto que o Group, e esses sao os que ficam travados
    alem do que a classe do carro sugere -- o Audi R8 e um carro B0 exigindo A0.

    Igualar UnlockingGroup ao Group libera o carro quando voce alcanca a classe
    dele, que e a regra que o resto do roster ja segue. -Group forca outro
    valor, se voce quiser tudo disponivel desde o inicio.

    O arquivo se chama 0xe94bde63 dentro do xarchive_cache.rpf porque o RPF3
    guarda nomes como hash Jenkins one-at-a-time, e joaat("vehicle.lst") da
    exatamente 0xE94BDE63. O mod loader quer o nome de verdade.

    Uso:
      .\mcla-mod-unlock.ps1 list   -Lst <caminho>
      .\mcla-mod-unlock.ps1 build  -Lst <caminho> -Out <pasta> [-Cars a,b] [-Group D0] [-Name r8-liberado]

    O build escreve <Out>\<Name>\files\tune\vehicle\vehicle.lst, que e a pasta
    que voce copia para dentro de modloader\ ao lado do executavel do jogo.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)][ValidateSet('list', 'build')][string]$Command = 'list',
    [Parameter(Mandatory)][string]$Lst,
    [string]$Out,
    [string[]]$Cars,
    [string]$Group,
    [string]$Name = 'desbloqueio'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Lst)) { throw "nao achei o arquivo: $Lst" }

# Lido como texto cru, e reescrito linha a linha: um arquivo de dados do jogo
# nao pode ser reformatado, so as linhas que mudam podem mudar.
$lines = [System.IO.File]::ReadAllLines($Lst)
if ($lines.Count -lt 50) { throw "isto nao parece um vehicle.lst: so $($lines.Count) linhas" }

function Read-Blocks {
    param([string[]]$Text)
    $out = @()
    $cur = $null
    for ($i = 0; $i -lt $Text.Count; $i++) {
        $line = $Text[$i]
        if ($line -match '^\s*Vehicle\s*$') {
            $cur = [ordered]@{ Start = $i; Name = ''; Class = ''; Group = ''; Unlock = ''; Price = ''; UnlockLine = -1 }
            continue
        }
        if ($null -eq $cur) { continue }
        if ($line -match '^\s*Name\s+(\S+)') { $cur.Name = $Matches[1] }
        elseif ($line -match '^\s*Class\s+(\S+)') { $cur.Class = $Matches[1] }
        elseif ($line -match '^\s*UnlockingGroup\s+(\S+)') { $cur.Unlock = $Matches[1]; $cur.UnlockLine = $i }
        elseif ($line -match '^\s*Group\s+(\S+)') { $cur.Group = $Matches[1] }
        elseif ($line -match '^\s*Price\s+(\S+)') { $cur.Price = $Matches[1] }
        elseif ($line -match '^\s*\}') {
            if ($cur.Name) { $out += [pscustomobject]$cur }
            $cur = $null
        }
    }
    return $out
}

$blocks = Read-Blocks -Text $lines
if ($blocks.Count -lt 10) { throw "so consegui ler $($blocks.Count) blocos de veiculo; o arquivo parece errado" }

$gated = $blocks | Where-Object { $_.Group -and $_.Unlock -and $_.Group -ne $_.Unlock }

if ($Command -eq 'list') {
    Write-Host ""
    Write-Host "$($blocks.Count) veiculos no roster, $($gated.Count) travados alem da propria classe" -ForegroundColor Cyan
    Write-Host ""
    $rows = $gated | ForEach-Object {
        [pscustomobject]@{
            Veiculo = $_.Name
            Classe  = $_.Class
            Grupo   = $_.Group
            Exige   = $_.Unlock
            Preco   = $_.Price
        }
    }
    ($rows | Format-Table -AutoSize | Out-String).TrimEnd().Split("`n") | ForEach-Object { Write-Host $_ }
    Write-Host ""
    Write-Host "Para liberar todos eles na classe do proprio carro:" -ForegroundColor DarkGray
    Write-Host "  .\mcla-mod-unlock.ps1 build -Lst `"$Lst`" -Out .\mods" -ForegroundColor DarkGray
    Write-Host ""
    return
}

if (-not $Out) { throw "o build precisa de -Out, a pasta onde o mod vai ser escrito" }

$alvos = if ($Cars) {
    $achados = @()
    foreach ($c in $Cars) {
        $m = $blocks | Where-Object { $_.Name -eq $c }
        if (-not $m) { throw "veiculo nao encontrado no roster: $c" }
        $achados += $m
    }
    $achados
} else {
    $gated
}

if (-not $alvos) { throw "nada a fazer: nenhum veiculo selecionado" }

# Aplica so nas linhas de UnlockingGroup dos alvos, preservando o recuo original.
$novo = [string[]]::new($lines.Count)
$lines.CopyTo($novo, 0)
$mudou = @()

foreach ($v in $alvos) {
    if ($v.UnlockLine -lt 0) { continue }
    $destino = if ($Group) { $Group } else { $v.Group }
    if ($v.Unlock -eq $destino) { continue }
    $orig = $lines[$v.UnlockLine]
    if ($orig -notmatch '^(\s*UnlockingGroup\s+)(\S+)(\s*)$') {
        throw "linha de UnlockingGroup com formato inesperado em $($v.Name): '$orig'"
    }
    $novo[$v.UnlockLine] = $Matches[1] + $destino + $Matches[3]
    $mudou += [pscustomobject]@{ Veiculo = $v.Name; De = $v.Unlock; Para = $destino }
}

if (-not $mudou) { throw "nenhuma linha precisou mudar; os alvos ja estao liberados" }

# O arquivo so vale se ele ainda parsear igual depois da edicao.
$conf = Read-Blocks -Text $novo
if ($conf.Count -ne $blocks.Count) {
    throw "a edicao mudou a contagem de blocos de $($blocks.Count) para $($conf.Count); nada foi gravado"
}
foreach ($v in $mudou) {
    $c = $conf | Where-Object { $_.Name -eq $v.Veiculo }
    if ($c.Unlock -ne $v.Para) { throw "a verificacao falhou em $($v.Veiculo); nada foi gravado" }
}

$destDir = Join-Path (Join-Path (Join-Path (Join-Path $Out $Name) 'files') 'tune') 'vehicle'
New-Item -ItemType Directory -Force -Path $destDir | Out-Null
$destFile = Join-Path $destDir 'vehicle.lst'

# CRLF, que e como o jogo guarda, e sem BOM.
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($destFile, ($novo -join "`r`n") + "`r`n", $enc)

Write-Host ""
Write-Host "$($mudou.Count) veiculos liberados:" -ForegroundColor Green
($mudou | Format-Table -AutoSize | Out-String).TrimEnd().Split("`n") | ForEach-Object { Write-Host $_ }
Write-Host ""
Write-Host "mod escrito em: $destFile" -ForegroundColor Cyan
Write-Host ""
Write-Host "Copie a pasta '$Name' para dentro de modloader\ ao lado do executavel do jogo." -ForegroundColor DarkGray
Write-Host "O loader empacota em xarchive_mods.rpf, que entra por ultimo na lista e" -ForegroundColor DarkGray
Write-Host "vence arquivo por arquivo. Os arquivos originais do jogo nao sao tocados," -ForegroundColor DarkGray
Write-Host "entao a traducao PT-BR continua vindo do arquivo de origem." -ForegroundColor DarkGray
Write-Host ""
