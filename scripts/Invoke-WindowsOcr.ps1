[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ImagePath,
    [Parameter(Mandatory = $true)]
    [string]$Languages,
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,
    [Parameter(Mandatory = $true)]
    [string]$StatusPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Status {
    param([string]$State, [string]$Code, [string]$Message)
    $safeMessage = ($Message -replace '[\r\n|]+', ' ').Trim()
    [IO.File]::WriteAllText($StatusPath, "$State|$Code|$safeMessage", [Text.UTF8Encoding]::new($false))
}

function Await-WinRt {
    param($Operation, [Type]$ResultType)

    $method = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object {
            $_.Name -eq "GetAwaiter" -and
            $_.IsGenericMethodDefinition -and
            $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType.Name -eq "IAsyncOperation``1"
        } |
        Select-Object -First 1
    if ($null -eq $method) {
        throw "Windows Runtime awaiter adapter is unavailable."
    }
    return $method.MakeGenericMethod($ResultType).Invoke($null, @($Operation)).GetResult()
}

try {
    if (-not (Test-Path -LiteralPath $ImagePath -PathType Leaf)) {
        throw "Image file was not found."
    }
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Globalization.Language, Windows.Foundation, ContentType = WindowsRuntime]
    $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
    $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]
    $null = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Foundation, ContentType = WindowsRuntime]
    $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
    $null = [Windows.Storage.FileAccessMode, Windows.Storage, ContentType = WindowsRuntime]
    $null = [Windows.Storage.Streams.IRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]

    $requested = @($Languages.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $available = @([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages | ForEach-Object { $_.LanguageTag })
    $selected = $null
    foreach ($request in $requested) {
        $selected = $available | Where-Object { $_ -ieq $request } | Select-Object -First 1
        if (-not [string]::IsNullOrWhiteSpace($selected)) {
            break
        }
        $baseLanguage = $request.Split('-')[0]
        $selected = $available | Where-Object { $_.Split('-')[0] -ieq $baseLanguage } | Select-Object -First 1
        if (-not [string]::IsNullOrWhiteSpace($selected)) {
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($selected)) {
        Write-Status "ERROR" "NO_LANGUAGE" ("Installed OCR languages: " + ($available -join ','))
        exit 2
    }

    $language = [Windows.Globalization.Language]::new($selected)
    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($language)
    if ($null -eq $engine) {
        Write-Status "ERROR" "NO_ENGINE" "Windows could not create an OCR engine for $selected."
        exit 3
    }

    $stream = $null
    $bitmap = $null
    $fileOperation = [Windows.Storage.StorageFile]::GetFileFromPathAsync([IO.Path]::GetFullPath($ImagePath))
    $file = Await-WinRt $fileOperation ([Windows.Storage.StorageFile])
    $streamOperation = $file.OpenAsync([Windows.Storage.FileAccessMode]::Read)
    $stream = Await-WinRt $streamOperation ([Windows.Storage.Streams.IRandomAccessStream])
    try {
        $decoderOperation = [Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)
        $decoder = Await-WinRt $decoderOperation ([Windows.Graphics.Imaging.BitmapDecoder])
        if ($decoder.PixelWidth -gt [Windows.Media.Ocr.OcrEngine]::MaxImageDimension -or
            $decoder.PixelHeight -gt [Windows.Media.Ocr.OcrEngine]::MaxImageDimension) {
            Write-Status "ERROR" "IMAGE_TOO_LARGE" "Image exceeds Windows OCR maximum dimension."
            exit 4
        }
        $bitmapOperation = $decoder.GetSoftwareBitmapAsync()
        $bitmap = Await-WinRt $bitmapOperation ([Windows.Graphics.Imaging.SoftwareBitmap])
        try {
            $resultOperation = $engine.RecognizeAsync($bitmap)
            $result = Await-WinRt $resultOperation ([Windows.Media.Ocr.OcrResult])
            [IO.File]::WriteAllText($OutputPath, [string]$result.Text, [Text.UTF8Encoding]::new($false))
            Write-Status "OK" $selected "Windows OCR"
        } finally {
            if ($null -ne $bitmap) {
                $bitmap.Dispose()
            }
        }
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
} catch {
    Write-Status "ERROR" "EXCEPTION" $_.Exception.Message
    exit 1
}
