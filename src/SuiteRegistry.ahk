; Read-only PL Suite registry adapter for ClipOCR-Pro.
; App-owned preferences and privacy consent remain under HKCU\Software\ScreenClipTool.

global SUITE_REG_ROOT := "HKCU\Software\VB and VBA Program Settings\PL_Suite"

Suite_ExpandEnvironment(value) {
    value := String(value)
    if (value == "")
        return ""
    try return ComObject("WScript.Shell").ExpandEnvironmentStrings(value)
    catch
        return value
}

Suite_TryReadRaw(section, name, &value) {
    global SUITE_REG_ROOT
    try {
        value := Trim(String(RegRead(SUITE_REG_ROOT "\" section, name)))
        return true
    } catch {
        value := ""
        return false
    }
}

NormalizeSuiteBoolean(value, fallback := false) {
    normalized := StrLower(Trim(String(value)))
    if (normalized == "true" || normalized == "1" || normalized == "yes" || normalized == "on")
        return true
    if (normalized == "false" || normalized == "0" || normalized == "no" || normalized == "off")
        return false
    return !!fallback
}

Suite_IsIntegrationEnabled(appSection) {
    if !Suite_TryReadRaw(appSection, "IntegrationEnabled", &value)
        return false
    return NormalizeSuiteBoolean(value, false)
}

Suite_TryGetAppSetting(appSection, name, &value) {
    if !Suite_IsIntegrationEnabled(appSection) {
        value := ""
        return false
    }
    if !Suite_TryReadRaw(appSection, name, &value)
        return false
    value := Suite_ExpandEnvironment(value)
    return true
}

Suite_TryGetCommonSetting(appSection, name, &value) {
    if !Suite_IsIntegrationEnabled(appSection) {
        value := ""
        return false
    }
    if !Suite_TryReadRaw("Common", name, &value)
        return false
    value := Suite_ExpandEnvironment(value)
    return true
}

ResolveBooleanSetting(localFound, localValue, suiteFound, suiteValue, fallback := false) {
    if localFound
        return NormalizeSuiteBoolean(localValue, fallback)
    if suiteFound
        return NormalizeSuiteBoolean(suiteValue, fallback)
    return !!fallback
}

NormalizeCaptureHotkey(value) {
    normalized := StrLower(RegExReplace(Trim(String(value)), "\s+"))
    if (normalized == "win+drag" || normalized == "#lbutton")
        return "#LButton"
    return "#LButton"
}

IsCaptureHotkeySupported(value) {
    normalized := StrLower(RegExReplace(Trim(String(value)), "\s+"))
    return normalized == "win+drag" || normalized == "#lbutton"
}
