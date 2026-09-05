; Local OCR orchestration. Windows.Media.Ocr is preferred; portable Tesseract is optional.

NormalizeOcrEngine(value) {
    normalized := StrLower(Trim(String(value)))
    return (normalized == "windows" || normalized == "tesseract") ? normalized : "auto"
}

NormalizeOcrLanguages(value) {
    normalized := []
    seen := Map()
    for _, rawCode in StrSplit(StrReplace(String(value), ";", ","), ",") {
        code := Trim(StrReplace(rawCode, "_", "-"))
        if !RegExMatch(code, "i)^[a-z]{2,3}(?:-[a-z]{2})?$")
            continue
        parts := StrSplit(code, "-")
        code := StrLower(parts[1])
        if (parts.Length > 1)
            code .= "-" StrUpper(parts[2])
        key := StrLower(code)
        if !seen.Has(key) {
            seen[key] := true
            normalized.Push(code)
        }
    }
    if (normalized.Length == 0)
        return "ko-KR,en-US"
    result := ""
    for index, code in normalized
        result .= (index == 1 ? "" : ",") code
    return result
}

GetOcrEngineOptions() {
    return [{ label: "Auto (Windows, then portable fallback)", value: "auto" },
        { label: "Windows OCR only", value: "windows" },
        { label: "Portable Tesseract only", value: "tesseract" }]
}

GetOcrEngineLabels() {
    labels := []
    for _, option in GetOcrEngineOptions()
        labels.Push(option.label)
    return labels
}

GetOcrEngineIndex(value) {
    value := NormalizeOcrEngine(value)
    for index, option in GetOcrEngineOptions() {
        if (option.value == value)
            return index
    }
    return 1
}

GetOcrEngineByLabel(label) {
    for _, option in GetOcrEngineOptions() {
        if (option.label == label)
            return option.value
    }
    return "auto"
}

QuoteOcrArgument(value) {
    value := String(value)
    if InStr(value, '"')
        throw Error("OCR path contains an unsupported quote character.")
    return '"' value '"'
}

ReadOcrStatus(statusPath) {
    if !FileExist(statusPath)
        return { ok: false, code: "NO_STATUS", message: "OCR helper returned no status." }
    status := Trim(FileRead(statusPath, "UTF-8"))
    parts := StrSplit(status, "|", , 3)
    if (parts.Length < 2)
        return { ok: false, code: "BAD_STATUS", message: status }
    message := parts.Length >= 3 ? parts[3] : ""
    return { ok: parts[1] == "OK", code: parts[2], message: message }
}

RunWindowsOcr(imagePath, languages) {
    global APP_TEMP_DIR
    if !DirExist(APP_TEMP_DIR)
        DirCreate(APP_TEMP_DIR)
    helperPath := PrepareWindowsOcrHelper()
    if (helperPath == "")
        return { ok: false, engine: "Windows OCR", language: "", text: "", error: "Windows OCR helper is unavailable." }

    id := DllCall("GetCurrentProcessId") "_" A_TickCount
    outputPath := APP_TEMP_DIR "\ocr_windows_" id ".txt"
    statusPath := APP_TEMP_DIR "\ocr_windows_" id ".status"
    powershellPath := A_WinDir "\System32\WindowsPowerShell\v1.0\powershell.exe"
    command := QuoteOcrArgument(powershellPath)
        . " -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " QuoteOcrArgument(helperPath)
        . " -ImagePath " QuoteOcrArgument(imagePath)
        . " -Languages " QuoteOcrArgument(languages)
        . " -OutputPath " QuoteOcrArgument(outputPath)
        . " -StatusPath " QuoteOcrArgument(statusPath)
    try {
        RunWait(command, , "Hide")
        status := ReadOcrStatus(statusPath)
        if !status.ok
            return { ok: false, engine: "Windows OCR", language: "", text: "", error: status.code ": " status.message }
        text := FileExist(outputPath) ? Trim(FileRead(outputPath, "UTF-8"), "`r`n `t") : ""
        return { ok: true, engine: "Windows OCR", language: status.code, text: text, error: "" }
    } catch as e {
        return { ok: false, engine: "Windows OCR", language: "", text: "", error: ShortErrorMessage(e.Message) }
    } finally {
        try FileDelete(outputPath)
        try FileDelete(statusPath)
    }
}

FindPortableTesseract() {
    candidates := []
    try {
        configuredDir := Trim(EnvGet("CLIPOCR_TESSERACT_DIR"))
        if (configuredDir != "")
            candidates.Push(configuredDir)
    }
    candidates.Push(A_ScriptDir "\ocr")
    if !A_IsCompiled
        candidates.Push(A_ScriptDir "\..\tools\tesseract")
    candidates.Push("C:\Program Files\Tesseract-OCR")

    for _, root in candidates {
        root := RTrim(Suite_ExpandEnvironment(root), "\/")
        executable := root "\tesseract.exe"
        tessdata := root "\tessdata"
        if (FileExist(executable) && DirExist(tessdata))
            return { executable: executable, tessdata: tessdata }
    }
    return 0
}

GetTesseractLanguageCode(language) {
    languageMap := Map("ko", "kor", "en", "eng", "pl", "pol", "de", "deu", "fr", "fra", "es", "spa")
    baseLanguage := StrLower(StrSplit(language, "-")[1])
    return languageMap.Has(baseLanguage) ? languageMap[baseLanguage] : baseLanguage
}

ResolveTesseractLanguages(languages, tessdataPath) {
    codes := []
    missing := []
    seen := Map()
    for _, language in StrSplit(NormalizeOcrLanguages(languages), ",") {
        code := GetTesseractLanguageCode(language)
        if seen.Has(code)
            continue
        seen[code] := true
        if FileExist(tessdataPath "\" code ".traineddata")
            codes.Push(code)
        else
            missing.Push(code)
    }
    joined := ""
    for index, code in codes
        joined .= (index == 1 ? "" : "+") code
    return { value: joined, missing: missing }
}

RunTesseractOcr(imagePath, languages) {
    global APP_TEMP_DIR
    if !DirExist(APP_TEMP_DIR)
        DirCreate(APP_TEMP_DIR)
    installation := FindPortableTesseract()
    if !IsObject(installation)
        return { ok: false, engine: "Tesseract", language: "", text: "", error: "Portable Tesseract is not installed." }

    resolvedLanguages := ResolveTesseractLanguages(languages, installation.tessdata)
    if (resolvedLanguages.value == "")
        return { ok: false, engine: "Tesseract", language: "", text: "", error: "Requested Tesseract language data is missing." }

    id := DllCall("GetCurrentProcessId") "_" A_TickCount
    outputBase := APP_TEMP_DIR "\ocr_tesseract_" id
    outputPath := outputBase ".txt"
    command := QuoteOcrArgument(installation.executable) " " QuoteOcrArgument(imagePath) " " QuoteOcrArgument(outputBase)
        . " -l " resolvedLanguages.value " --tessdata-dir " QuoteOcrArgument(installation.tessdata) " --psm 6"
    try {
        exitCode := RunWait(command, , "Hide")
        if (exitCode != 0 || !FileExist(outputPath))
            return { ok: false, engine: "Tesseract", language: resolvedLanguages.value, text: "", error: "Tesseract exited with code " exitCode "." }
        text := Trim(FileRead(outputPath, "UTF-8"), "`r`n `t")
        warning := resolvedLanguages.missing.Length > 0 ? "Some requested language data was unavailable." : ""
        return { ok: true, engine: "Tesseract", language: resolvedLanguages.value, text: text, error: warning }
    } catch as e {
        return { ok: false, engine: "Tesseract", language: resolvedLanguages.value, text: "", error: ShortErrorMessage(e.Message) }
    } finally {
        try FileDelete(outputPath)
    }
}

JoinOcrErrors(errors) {
    text := ""
    for _, message in errors {
        if (message != "")
            text .= (text == "" ? "" : " | ") message
    }
    return text
}

RunLocalOcr(imagePath, engine, languages) {
    engine := NormalizeOcrEngine(engine)
    languages := NormalizeOcrLanguages(languages)
    errors := []

    if (engine == "windows") {
        result := RunWindowsOcr(imagePath, languages)
        if (result.ok && result.text != "")
            return result
        return { ok: false, engine: result.engine, language: result.language, text: "",
            error: result.ok ? "No text was detected." : result.error }
    }
    if (engine == "tesseract") {
        result := RunTesseractOcr(imagePath, languages)
        if (result.ok && result.text != "")
            return result
        return { ok: false, engine: result.engine, language: result.language, text: "",
            error: result.ok ? "No text was detected." : result.error }
    }

    languageList := StrSplit(languages, ",")
    primaryLanguage := languageList[1]
    result := RunWindowsOcr(imagePath, primaryLanguage)
    if (result.ok && result.text != "")
        return result
    errors.Push(result.ok ? "Windows OCR detected no text." : result.error)

    result := RunTesseractOcr(imagePath, languages)
    if (result.ok && result.text != "")
        return result
    errors.Push(result.ok ? "Tesseract detected no text." : result.error)

    if (languageList.Length > 1) {
        fallbackLanguages := ""
        loop languageList.Length - 1
            fallbackLanguages .= (A_Index == 1 ? "" : ",") languageList[A_Index + 1]
        result := RunWindowsOcr(imagePath, fallbackLanguages)
        if (result.ok && result.text != "")
            return result
        errors.Push(result.ok ? "Windows fallback detected no text." : result.error)
    }

    return { ok: false, engine: "Local OCR", language: "", text: "", error: JoinOcrErrors(errors) }
}
