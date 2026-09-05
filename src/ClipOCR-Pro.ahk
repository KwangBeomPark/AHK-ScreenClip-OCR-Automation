#Requires AutoHotkey v2.0
#SingleInstance Force
;@Ahk2Exe-SetMainIcon ..\assets\ClipOCR-Pro.ico
;@Ahk2Exe-SetVersion 1.4.0.0
#Include Gdip_All.ahk
#Include SuiteRegistry.ahk

; ── App metadata ──
global APP_NAME := "ClipOCR-Pro"
global APP_VERSION := "1.4.0"
global APP_ICON_PATH := A_IsCompiled ? A_ScriptFullPath : A_ScriptDir "\..\assets\ClipOCR-Pro.ico"
global APP_SOURCE_ICON_PATH := A_ScriptDir "\..\assets\ClipOCR-Pro.ico"
global GITHUB_RELEASES_URL := "https://github.com/KwangBeomPark/01_ClipOCR-Pro/releases"
global GITHUB_LATEST_RELEASE_API := "https://api.github.com/repos/KwangBeomPark/01_ClipOCR-Pro/releases/latest"

; ── Global asset paths and initialization ──
; Keep app-owned temp files in a dedicated subfolder instead of the shared Temp root.
global APP_TEMP_DIR := A_Temp "\ClipOCR-Pro"
global bmcBtnPath := APP_TEMP_DIR "\bmc_btn.png"
global githubIconPath := ""

; Headless build/CI check for version parsing, release-asset parsing, hashing, and quality settings.
if (A_Args.Length > 0 && A_Args[1] == "--health-check")
    ExitApp(RunInternalHealthCheck())

; Use the bundled GitHub icon asset instead of downloading one at runtime.
githubIconPath := PrepareBundledGithubIcon()

PrepareBundledGithubIcon() {
    global APP_TEMP_DIR
    ; Source run: load directly from the repository assets folder when available.
    sourceAsset := A_ScriptDir "\..\assets\github_icon.png"
    if (!A_IsCompiled && FileExist(sourceAsset))
        return sourceAsset
    ; Compiled run (or missing source): extract the embedded copy into the app temp folder.
    ; Overwriting every launch guarantees the loaded file is always our trusted asset.
    try {
        if !DirExist(APP_TEMP_DIR)
            DirCreate(APP_TEMP_DIR)
        FileInstall("..\assets\github_icon.png", APP_TEMP_DIR "\github_icon.png", 1)
        if FileExist(APP_TEMP_DIR "\github_icon.png")
            return APP_TEMP_DIR "\github_icon.png"
    }
    return ""
}

; ── Per-Monitor DPI Aware V2: fixes scaling mismatches across monitors ──
; Use physical pixels for all coordinates so capture remains accurate across mixed-DPI monitors.
DllCall("SetThreadDpiAwarenessContext", "ptr", -4, "ptr")

if !pToken := Gdip_Startup() {
    MsgBox "GDI+ failed to start."
    ExitApp
}

OnExit AppCleanup

AppCleanup(*) {
    global pToken, TEMP_FILES
    try Gdip_Shutdown(pToken)
    try {
        for _, filePath in TEMP_FILES {
            if FileExist(filePath)
                FileDelete(filePath)
        }
    }
}

; ── UI and behavior constants ──
global MINI_SIZE := 80          ; Minimized window size (px)
global MINI_OPACITY := 128      ; Minimized opacity (0-255)
global WINDOW_BORDER_WIDTH := 1 ; Floating capture window border width (px)
global ANNOTATION_BORDER_WIDTH := 3 ; Red annotation rectangle width (px)
global UNDO_MAX := 5            ; Maximum undo steps
global TEXT_TRANSLATE_MAX_CHARS := 5000 ; Safe maximum length for Google Text Translation GET requests
global MAIL_COPY_TIMEOUT_SECONDS := 3
global MAIL_SUBJECT_ALLOWANCE_BYTES := 8 * 1024
global MAIL_HEADER_ALLOWANCE_BYTES := 64 * 1024
global MAIL_ENCODING_FACTOR := 1.37

; ── User settings: keep the Registry path name for backward compatibility ──
global REG_PATH := "HKCU\Software\ScreenClipTool"
global CLIP_WIDTH := 1000
global COPY_OUTLINE_ENABLED := true
global SAVE_IMAGE_FORMAT := "png" ; Ctrl+S output format: jpg or png
global JPG_QUALITY := 90 ; Ctrl+S JPG save and size-estimate quality
global TEXT_TRANSLATE_LANG := "ko"
global TEXT_TRANSLATE_HOTKEY := "#CapsLock"
global TEXT_TRANSLATE_FONT_SIZE := 10
global IMAGE_TRANSLATE_LANGS := "ko,en,pl"
global MANUAL_LANG := GetDefaultUILang() ; Also used as the general UI language for core tooltips
global TRANSLATE_CONSENT := false ; One-time consent before sending data to external translation services
global SAVE_FOLDER := "" ; Ctrl+S save destination; empty means Desktop (backward compatible)
global SAVE_FOLDER_SOURCE := "desktop"
global AUTO_CLIPBOARD := true
global CAPTURE_HOTKEY := "#LButton"

; ── Runtime state ──
global TRAY_TEXT_TRANSLATE_ITEM := ""
global TextTranslatePopupHwnd := 0
global DashboardHwnd := 0
global ManualHwnd := 0
global ANNOTATION_MODE := ""
global ANNOTATION_TARGET_HWND := 0
global TEXT_SOURCE_LAST_HWND := 0
global TEMP_FILES := []
global ENABLE_BMC_AUTO_DOWNLOAD := false
global MAIL_SIZE_CHECK_RUNNING := false
global UPDATE_CHECK_STATE := { status: "idle", latestVersion: "", releaseUrl: GITHUB_RELEASES_URL,
    downloadUrl: "", assetName: "", assetSize: 0, sha256: "", lastError: "", request: 0, startedTick: 0,
    statusCtrl: 0, detailCtrl: 0, updateBtn: 0, dashboardHwnd: 0 }

try {
    CLIP_WIDTH := NormalizeClipWidth(RegRead(REG_PATH, "ClipboardWidth"))
} catch {
    CLIP_WIDTH := 1000
}

try {
    COPY_OUTLINE_ENABLED := NormalizeCopyOutline(RegRead(REG_PATH, "CopyOutline"))
} catch {
    COPY_OUTLINE_ENABLED := true
}

try {
    JPG_QUALITY := NormalizeJpegQuality(RegRead(REG_PATH, "JpegQuality"))
} catch {
    JPG_QUALITY := 90
}

try {
    SAVE_IMAGE_FORMAT := NormalizeSaveImageFormat(RegRead(REG_PATH, "SaveImageFormat"))
} catch {
    SAVE_IMAGE_FORMAT := "png"
}

try {
    savedLang := RegRead(REG_PATH, "TranslateLang")
    if IsTextTranslateLangSupported(savedLang)
        TEXT_TRANSLATE_LANG := savedLang
} catch {
    TEXT_TRANSLATE_LANG := "ko"
}

try {
    savedHotkey := RegRead(REG_PATH, "TranslateHotkey")
    if IsTextTranslateHotkeySupported(savedHotkey)
        TEXT_TRANSLATE_HOTKEY := savedHotkey
} catch {
    TEXT_TRANSLATE_HOTKEY := "#CapsLock"
}

try {
    TEXT_TRANSLATE_FONT_SIZE := NormalizeTextTranslateFontSize(RegRead(REG_PATH, "TextTranslateFontSize"))
} catch {
    TEXT_TRANSLATE_FONT_SIZE := 10
}

try {
    savedImageLangs := RegRead(REG_PATH, "ImageTranslateLangs")
    IMAGE_TRANSLATE_LANGS := NormalizeLangCodeList(savedImageLangs)
} catch {
    IMAGE_TRANSLATE_LANGS := NormalizeLangCodeList(IMAGE_TRANSLATE_LANGS)
}

try {
    savedManualLang := RegRead(REG_PATH, "ManualLang")
    if (savedManualLang == "ko" || savedManualLang == "en" || savedManualLang == "pl" || savedManualLang == "de" || savedManualLang == "fr" || savedManualLang == "es")
        MANUAL_LANG := savedManualLang
} catch {
    MANUAL_LANG := GetDefaultUILang()
}

try {
    ; Privacy invariant: consent is app-owned and is never read from or written to PL_Suite.
    TRANSLATE_CONSENT := (Trim(String(RegRead(REG_PATH, "TranslateConsent"))) == "1")
} catch {
    TRANSLATE_CONSENT := false
}

localSaveFound := TryReadLocalSetting("SaveFolder", &localSaveFolder)
suiteSaveFound := false
suiteSaveFolder := ""
if !localSaveFound
    suiteSaveFound := Suite_TryGetCommonSetting("ClipOCR", "CaptureOutputDir", &suiteSaveFolder)
resolvedSaveFolder := ResolveSaveFolderSetting(localSaveFound, localSaveFolder, suiteSaveFound, suiteSaveFolder)
SAVE_FOLDER := resolvedSaveFolder.folder
SAVE_FOLDER_SOURCE := resolvedSaveFolder.source

localAutoFound := TryReadLocalSetting("AutoClipboard", &localAutoClipboard)
suiteAutoFound := false
suiteAutoClipboard := ""
if !localAutoFound
    suiteAutoFound := Suite_TryGetAppSetting("ClipOCR", "AutoClipboard", &suiteAutoClipboard)
AUTO_CLIPBOARD := ResolveBooleanSetting(localAutoFound, localAutoClipboard, suiteAutoFound, suiteAutoClipboard, true)

localCaptureFound := TryReadLocalSetting("CaptureHotkey", &localCaptureHotkey)
suiteCaptureFound := false
suiteCaptureHotkey := ""
if !localCaptureFound
    suiteCaptureFound := Suite_TryGetAppSetting("ClipOCR", "CaptureHotkey", &suiteCaptureHotkey)
captureHotkeyValue := localCaptureFound ? localCaptureHotkey : (suiteCaptureFound ? suiteCaptureHotkey : "Win+Drag")
CAPTURE_HOTKEY := NormalizeCaptureHotkey(captureHotkeyValue)

; ── System tray icon and menu customization ──
try {
    if FileExist(APP_ICON_PATH)
        TraySetIcon(APP_ICON_PATH)
    else if FileExist(APP_SOURCE_ICON_PATH)
        TraySetIcon(APP_SOURCE_ICON_PATH)
    else
        TraySetIcon("shell32.dll", 260) ; Scissors icon fallback
} catch {
    ; Ignore failures and keep the default icon.
}
A_IconTip := APP_NAME
Tray := A_TrayMenu
Tray.Delete()
Tray.Add("📸 Capture (Win+Drag)", StartConfiguredCapture)
TRAY_TEXT_TRANSLATE_ITEM := "🌐 Translate Selected Text (" GetTextTranslateHotkeyLabel(TEXT_TRANSLATE_HOTKEY) ")"
Tray.Add(TRAY_TEXT_TRANSLATE_ITEM, (*) => TranslateSelectedText(true))
Tray.Add("⚙️ Preferences & About", (*) => ShowDashboardDialog())
Tray.Add()
Tray.Add("📐 Sort All Clips (Ctrl+Left)", (*) => SCW_SortCascade())
Tray.Add("🔽 Minimize All (Ctrl+Up)", (*) => SCW_MinimizeAll())
Tray.Add("🔼 Restore All (Ctrl+Down)", (*) => SCW_RestoreAll())
Tray.Add("❌ Close All Clips (Ctrl+Esc)", (*) => SCW_CloseAll())
Tray.Add()
Tray.Add("🔄 Reload Script", (*) => Reload())
Tray.Add("🚪 Exit App", (*) => ExitApp())

; ── Capture window and context-menu state ──
global ClipWins := Map()
global RightClickedHwnd := 0
global ClipMenu := Menu()

; bmcBtnPath is defined with the global asset paths near the top of the script.

; Do not auto-download external images by default in corporate security environments.
if ENABLE_BMC_AUTO_DOWNLOAD
    SetTimer(DownloadBmcButton, -100)

DownloadBmcButton() {
    global bmcBtnPath, APP_TEMP_DIR
    if !FileExist(bmcBtnPath) {
        try {
            if !DirExist(APP_TEMP_DIR)
                DirCreate(APP_TEMP_DIR)
            Download("https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png", bmcBtnPath)
        }
    }
}

; Google Image Translation submenu for target-language selection.
global ImgTransMenu := Menu()

UpdateImageTranslateMenu() {
    global ImgTransMenu, IMAGE_TRANSLATE_LANGS
    ImgTransMenu.Delete()
    IMAGE_TRANSLATE_LANGS := NormalizeLangCodeList(IMAGE_TRANSLATE_LANGS)

    langArray := StrSplit(IMAGE_TRANSLATE_LANGS, ",")
    if (langArray.Length == 0)
        langArray := ["ko"]

    options := GetTextTranslateLangOptions()

    for _, code in langArray {
        code := Trim(code)
        if (code == "")
            continue

        label := "🌐 Translate to " code
        for _, opt in options {
            if (opt.code == code) {
                label := "🌐 Translate to " opt.label
                break
            }
        }

        ; Bind through a local-scope function for lambda closure safety.
        BindGoogleImageTranslate(c) {
            return (*) => GoogleImageTranslate(c)
        }

        ImgTransMenu.Add(label, BindGoogleImageTranslate(code))
    }
}

UpdateImageTranslateMenu()

ClipMenu.Add("🌐 1. Google Translate (Image)", ImgTransMenu)
ClipMenu.Add() ; Separator

ClipMenu.Add("🟥 2. Red Box (Shift+Drag)", MenuHandler)
ClipMenu.Add("🟨 3. Yellow Highlight (Ctrl+Drag)", MenuHandler)
ClipMenu.Add("🟩 4. Green Highlight (Alt+Drag)", MenuHandler)
ClipMenu.Add("➡️ 5. Arrow (Drag)", MenuHandler)
ClipMenu.Add("🔢 6. Number Pin (Click)", MenuHandler)
ClipMenu.Add("🌫️ 7. Mosaic (Drag)", MenuHandler)
ClipMenu.Add("✍️ 8. Text Markup (Shift+Ctrl+Click)", MenuHandler)
ClipMenu.Add("↩️ 9. Undo Draw (Ctrl+Z)", MenuHandler)
ClipMenu.Add() ; Separator

ClipMenu.Add("📋 10. Copy to Clipboard (Ctrl+C)", MenuHandler)
ClipMenu.Add("💾 11. Save to File (Ctrl+S)", MenuHandler)
ClipMenu.Add("🎨 12. Copy To Paint", MenuHandler)
ClipMenu.Add() ; Separator

; 13. Clipboard width submenu
WidthMenu := Menu()
WidthMenu.Add("Original Size (Ctrl+0)", (*) => SetClipWidth(0))
WidthMenu.Add()
WidthMenu.Add("400 px (Ctrl+1)", (*) => SetClipWidth(400))
WidthMenu.Add("600 px (Ctrl+2)", (*) => SetClipWidth(600))
WidthMenu.Add("800 px (Ctrl+3)", (*) => SetClipWidth(800))
WidthMenu.Add("1000 px (Ctrl+4)", (*) => SetClipWidth(1000))
WidthMenu.Add("1200 px (Ctrl+5)", (*) => SetClipWidth(1200))
WidthMenu.Add("1400 px (Ctrl+6)", (*) => SetClipWidth(1400))
WidthMenu.Add("1600 px (Ctrl+7)", (*) => SetClipWidth(1600))
UpdateWidthMenu()

ClipMenu.Add("⚙️ 13. Clipboard Width", WidthMenu)

; 14. Persisted image format/quality preset submenu
global ImagePresetMenu := Menu()
for presetIndex, preset in GetImageSavePresetOptions()
    ImagePresetMenu.Add(preset.label, BindImageSavePreset(presetIndex))
UpdateImageSavePresetMenu()
ClipMenu.Add("🖼️ 14. Image Quality && Size", ImagePresetMenu)
ClipMenu.Add() ; Separator
ClipMenu.Add("📐 15. Sort All Clips (Ctrl+Left)", (*) => SCW_SortCascade())
ClipMenu.Add("🔽 16. Minimize All (Ctrl+Up)", (*) => SCW_MinimizeAll())
ClipMenu.Add("🔼 17. Restore All (Ctrl+Down)", (*) => SCW_RestoreAll())
ClipMenu.Add("❌ 18. Close All Clips (Ctrl+Esc)", (*) => SCW_CloseAll())
ClipMenu.Add("⚙️ 19. Preferences & About", (*) => ShowDashboardDialog())

; ── Startup welcome tooltip ──
ToolTip(UIText("startup_ready", Map("app", APP_NAME, "hotkey", GetTextTranslateHotkeyLabel(TEXT_TRANSLATE_HOTKEY))))
SetTimer(() => ToolTip(), -4000)

SetTimer(TrackLastTextSourceWindow, 250)
ApplyCaptureHotkey()
ApplyTextTranslateHotkey()

; Optional support/QA entry point: open the settings window directly.
if (A_Args.Length > 0 && A_Args[1] == "--settings")
    SetTimer(ShowDashboardDialog, -100)

; ── Register capture-window mouse message handlers once (they dispatch by hwnd) ──
OnMessage(0x0201, WM_LBUTTONDOWN)     ; WM_LBUTTONDOWN
OnMessage(0x0203, WM_LBUTTONDOWN)     ; WM_LBUTTONDBLCLK (double click)
OnMessage(0x0204, WM_RBUTTONDOWN)     ; WM_RBUTTONDOWN (right click)

; Hotkeys
$^#0:: EstimateOutlookWebMailSize()

#HotIf WinActive("ScreenClippingWindow ahk_class AutoHotkeyGUI")
^c:: SCW_Win2Clipboard()
^s:: SCW_Win2File()
^z:: SCW_Undo()
^0:: SCW_SetWidthAndCopy(0)
^1:: SCW_SetWidthAndCopy(400)
^2:: SCW_SetWidthAndCopy(600)
^3:: SCW_SetWidthAndCopy(800)
^4:: SCW_SetWidthAndCopy(1000)
^5:: SCW_SetWidthAndCopy(1200)
^6:: SCW_SetWidthAndCopy(1400)
^7:: SCW_SetWidthAndCopy(1600)
^Left:: SCW_SortCascade()
^Up:: SCW_MinimizeAll()
^Down:: SCW_RestoreAll()
Esc:: SCW_CloseWin()
^Esc:: SCW_CloseAll() ; Ctrl+Esc -> close all
#HotIf

StartConfiguredCapture(*) {
    global AUTO_CLIPBOARD
    ScreenClip2Win(AUTO_CLIPBOARD ? 1 : 0)
}

ApplyCaptureHotkey() {
    global CAPTURE_HOTKEY
    try {
        Hotkey(CAPTURE_HOTKEY, StartConfiguredCapture, "On")
        return true
    } catch as e {
        ToolTip("⚠️ 캡처 단축키 설정 실패: " e.Message)
        SetTimer(() => ToolTip(), -3000)
        return false
    }
}

/**
 * 지정한 화면 영역을 캡처하여 항상-위 플로팅 이미지 창을 생성하는 핵심 함수
 * Captures a selected screen area and displays it in a floating always-on-top window.
 * @param {Integer} clipToClipboard - 1인 경우 클립보드로 자동 복사 수행 / Auto-copy to clipboard if 1
 * @returns {None}
 */
ScreenClip2Win(clipToClipboard := 0) {
    Area := SelectArea()
    if (Area.W < 10 || Area.H < 10)
        return

    pBitmap := Gdip_BitmapFromScreen(Area.X "|" Area.Y "|" Area.W "|" Area.H)
    if !pBitmap {
        ToolTip(UIText("capture_failed"))
        SetTimer(() => ToolTip(), -3000)
        return
    }

    hwnd := CreateClipWin(pBitmap, Area.X, Area.Y)

    if clipToClipboard {
        WinActivate("ahk_id " hwnd)
        SCW_Win2Clipboard()
    }
}

NormalizeClipWidth(value) {
    try {
        width := Integer(value)
    } catch {
        return 1000
    }

    for _, allowed in [0, 400, 600, 800, 1000, 1200, 1400, 1600] {
        if (width == allowed)
            return allowed
    }
    return 1000
}

NormalizeCopyOutline(value) {
    value := Trim(String(value))
    if (value == "0")
        return false
    if (value == "1")
        return true
    return true
}

NormalizeJpegQuality(value) {
    try {
        quality := Integer(value)
    } catch {
        return 90
    }

    for _, allowed in [70, 80, 90] {
        if (quality == allowed)
            return allowed
    }
    return 90
}

NormalizeSaveImageFormat(value) {
    value := StrLower(Trim(String(value)))
    return (value == "jpg") ? "jpg" : "png"
}

NormalizeTextTranslateFontSize(value) {
    try {
        fontSize := Integer(value)
    } catch {
        return 10
    }

    ; Keep the translation popup in a practical size range.
    if (fontSize < 8 || fontSize > 18)
        return 10
    return fontSize
}

NormalizeLangCodeList(csvText, defaultCsv := "ko,en,pl") {
    result := []
    seen := Map()

    AddCode(code) {
        code := StrLower(Trim(code))
        if (code == "" || seen.Has(code) || !IsTextTranslateLangSupported(code))
            return
        seen[code] := true
        result.Push(code)
    }

    for _, code in StrSplit(String(csvText), ",")
        AddCode(code)

    if (result.Length == 0) {
        for _, code in StrSplit(defaultCsv, ",")
            AddCode(code)
    }

    if (result.Length == 0)
        result.Push("ko")

    normalized := ""
    for index, code in result
        normalized .= (index == 1 ? "" : ",") code
    return normalized
}

SafeClipboardBackup() {
    try {
        return { ok: true, data: ClipboardAll() }
    } catch {
        return { ok: false, data: "" }
    }
}

SafeClipboardRestore(clipBackup) {
    try {
        if clipBackup.ok {
            A_Clipboard := clipBackup.data
            return true
        }
    } catch {
        ; If the clipboard is locked, ignore only the restore failure and keep the app running.
    }
    return false
}

EstimateOutlookWebMailSize() {
    global MAIL_SIZE_CHECK_RUNNING, MAIL_COPY_TIMEOUT_SECONDS

    if MAIL_SIZE_CHECK_RUNNING {
        ShowMailSizeTooltip("A mail size estimate is already running.")
        return
    }

    sourceHwnd := WinExist("A")
    if !IsOutlookWebMailContext(sourceHwnd) {
        ShowMailSizeTooltip("Open an Outlook web mail compose window and try again.")
        return
    }

    MAIL_SIZE_CHECK_RUNNING := true
    Critical("On")
    clipBackup := { ok: false, data: "" }
    mailClip := ""
    restoreRequired := false
    restoreOk := true
    copiedBody := false
    message := ""

    try {
        clipBackup := SafeClipboardBackup()
        if !clipBackup.ok
            throw Error("Could not back up the clipboard.")
        restoreRequired := true

        if !WinActive("ahk_id " sourceHwnd)
            throw Error("The Outlook window is no longer active.")

        A_Clipboard := ""
        sequenceBeforeCopy := DllCall("GetClipboardSequenceNumber", "UInt")
        Send("^a")
        Sleep(80)

        if !WinActive("ahk_id " sourceHwnd)
            throw Error("The Outlook window changed before the message body was copied.")

        Send("^c")
        if !WaitForClipboardChange(sequenceBeforeCopy, MAIL_COPY_TIMEOUT_SECONDS)
            throw Error("Could not copy the message body within 3 seconds.")

        Sleep(150)
        if !WinActive("ahk_id " sourceHwnd)
            throw Error("The Outlook window changed while reading the message body.")
        if !ClipboardHasHtmlFormat()
            throw Error("Click inside the message body and try again.")

        mailClip := ClipboardAll()
        if (mailClip.Size <= 0)
            throw Error("The copied message body is empty.")

        estimatedBytes := CalculateOutlookWebMailBytes(mailClip.Size)
        estimatedMb := estimatedBytes / 1048576
        message := "Outlook web mail estimate: ~" Format("{:.2f}", estimatedMb) " MB"
        message .= "`r`nBody + subject/header allowance, attachments excluded"
        message .= "`r`nActual sent size may differ."
        copiedBody := true
    } catch as e {
        message := "Mail size estimate failed: " ShortErrorMessage(e.Message)
    } finally {
        mailClip := ""
        if restoreRequired
            restoreOk := SafeClipboardRestore(clipBackup)
        clipBackup := { ok: false, data: "" }

        if (copiedBody && WinActive("ahk_id " sourceHwnd))
            Send("{Right}")

        MAIL_SIZE_CHECK_RUNNING := false
        Critical("Off")
    }

    if !restoreOk
        message .= "`r`nWarning: The original clipboard could not be restored."
    ShowMailSizeTooltip(message, restoreOk ? 5000 : 7000)
}

IsOutlookWebMailContext(hwnd) {
    if !hwnd
        return false

    try {
        hostProcess := StrLower(WinGetProcessName("ahk_id " hwnd))
        windowTitle := WinGetTitle("ahk_id " hwnd)
    } catch {
        return false
    }

    focusedProcess := GetFocusedWindowProcessName(hwnd)
    return IsSupportedOutlookWebMailHost(hostProcess, focusedProcess, windowTitle)
}

IsSupportedOutlookWebMailHost(hostProcess, focusedProcess, windowTitle) {
    hostProcess := StrLower(hostProcess)
    focusedProcess := StrLower(focusedProcess)
    titleHasOutlook := InStr(windowTitle, "Outlook", false) > 0

    if (hostProcess == "olk.exe" || hostProcess == "outlook.exe")
        return true
    if ((hostProcess == "msedge.exe" || hostProcess == "chrome.exe") && titleHasOutlook)
        return true
    return ((hostProcess == "msedgewebview2.exe" || focusedProcess == "msedgewebview2.exe") && titleHasOutlook)
}

CalculateOutlookWebMailBytes(clipboardBytes) {
    global MAIL_SUBJECT_ALLOWANCE_BYTES, MAIL_HEADER_ALLOWANCE_BYTES, MAIL_ENCODING_FACTOR
    clipboardBytes := Max(0, Integer(clipboardBytes))
    return Ceil((clipboardBytes + MAIL_SUBJECT_ALLOWANCE_BYTES) * MAIL_ENCODING_FACTOR
        + MAIL_HEADER_ALLOWANCE_BYTES)
}

GetFocusedWindowProcessName(activeHwnd) {
    try {
        activeThreadId := DllCall("GetWindowThreadProcessId", "Ptr", activeHwnd, "UInt*", &activePid := 0, "UInt")
        if !activeThreadId
            return ""

        guiInfo := Buffer(8 + 6 * A_PtrSize + 16, 0)
        NumPut("UInt", guiInfo.Size, guiInfo, 0)
        if !DllCall("GetGUIThreadInfo", "UInt", activeThreadId, "Ptr", guiInfo.Ptr)
            return ""

        focusHwnd := NumGet(guiInfo, 8 + A_PtrSize, "Ptr")
        if !focusHwnd
            return ""
        DllCall("GetWindowThreadProcessId", "Ptr", focusHwnd, "UInt*", &focusPid := 0)
        return focusPid ? StrLower(ProcessGetName(focusPid)) : ""
    } catch {
        return ""
    }
}

WaitForClipboardChange(sequenceBefore, timeoutSeconds) {
    deadline := A_TickCount + Round(timeoutSeconds * 1000)
    while (A_TickCount < deadline) {
        if (DllCall("GetClipboardSequenceNumber", "UInt") != sequenceBefore && ClipWait(0.1, true))
            return true
        Sleep(25)
    }
    return false
}

ClipboardHasHtmlFormat() {
    htmlFormat := DllCall("RegisterClipboardFormat", "Str", "HTML Format", "UInt")
    return htmlFormat && DllCall("IsClipboardFormatAvailable", "UInt", htmlFormat)
}

ShowMailSizeTooltip(message, durationMs := 5000) {
    ToolTip(message)
    SetTimer(() => ToolTip(), -durationMs)
}

; Returns a non-existing file path, appending _2, _3 ... on collision to avoid silent overwrite.
GetUniqueFilePath(dir, baseName, ext) {
    candidate := dir "\" baseName "." ext
    if !FileExist(candidate)
        return candidate
    index := 2
    loop {
        candidate := dir "\" baseName "_" index "." ext
        if !FileExist(candidate)
            return candidate
        index++
    }
}

; ── Ctrl+S save destination (local explicit value, then Suite default, then Desktop) ──
ResolveSaveFolderSetting(localFound, localValue, suiteFound, suiteValue) {
    if localFound {
        localPath := Trim(String(localValue))
        ; Blank or invalid local values deliberately fall back to Desktop, never to Suite.
        return { folder: (localPath != "" && DirExist(localPath)) ? localPath : "", source: "local" }
    }

    if suiteFound {
        suitePath := Trim(String(suiteValue))
        if (suitePath != "" && DirExist(suitePath))
            return { folder: suitePath, source: "suite" }
    }
    return { folder: "", source: "desktop" }
}

GetSaveFolder() {
    global SAVE_FOLDER
    if (SAVE_FOLDER != "" && DirExist(SAVE_FOLDER))
        return SAVE_FOLDER
    return A_Desktop
}

SetSaveFolder(folder) {
    global SAVE_FOLDER, SAVE_FOLDER_SOURCE, REG_PATH
    folder := Trim(String(folder))
    ; Store the Desktop path as empty so the default keeps following the user's Desktop.
    if (folder == "" || folder == A_Desktop)
        SAVE_FOLDER := ""
    else
        SAVE_FOLDER := folder
    if !SafeRegWriteString(SAVE_FOLDER, REG_PATH, "SaveFolder")
        return false
    SAVE_FOLDER_SOURCE := "local"
    return true
}

SetAutoClipboard(enabled) {
    global AUTO_CLIPBOARD, REG_PATH
    AUTO_CLIPBOARD := !!enabled
    return SafeRegWriteString(AUTO_CLIPBOARD ? 1 : 0, REG_PATH, "AutoClipboard")
}

SafeSaveBitmapToFile(pBitmap, filePath, quality := 75) {
    if (!pBitmap || filePath == "")
        return false
    try {
        SplitPath(filePath, , , &extension)
        if RegExMatch(extension, "i)^(jpg|jpeg|jpe|jfif)$")
            result := SaveJpegBitmapToFile(pBitmap, filePath, quality)
        else
            result := Gdip_SaveBitmapToFile(pBitmap, filePath)
        return (result == 0 && FileExist(filePath))
    } catch {
        return false
    }
}

SaveJpegBitmapToFile(pBitmap, filePath, quality := 85) {
    quality := Max(0, Min(100, Integer(quality)))
    DllCall("gdiplus\GdipGetImageEncodersSize", "UInt*", &encoderCount := 0, "UInt*", &encoderSize := 0)
    if (!encoderCount || !encoderSize)
        return -2

    codecInfo := Buffer(encoderSize, 0)
    DllCall("gdiplus\GdipGetImageEncoders", "UInt", encoderCount, "UInt", encoderSize, "UPtr", codecInfo.Ptr)
    pCodec := 0
    loop encoderCount {
        offset := (48 + 7 * A_PtrSize) * (A_Index - 1)
        mimePtr := NumGet(codecInfo, offset + 32 + 4 * A_PtrSize, "UPtr")
        if (mimePtr && StrGet(mimePtr, "UTF-16") == "image/jpeg") {
            pCodec := codecInfo.Ptr + offset
            break
        }
    }
    if !pCodec
        return -3

    qualityValue := Buffer(4, 0)
    NumPut("UInt", quality, qualityValue)
    encoderParams := Buffer(24 + 2 * A_PtrSize, 0)
    NumPut("UPtr", 1, encoderParams, 0)
    DllCall("ole32\CLSIDFromString", "WStr", "{1D5BE4B5-FA4A-452D-9CDD-5DB35105E7EB}",
        "UPtr", encoderParams.Ptr + A_PtrSize, "HRESULT")
    NumPut("UInt", 1, encoderParams, 16 + A_PtrSize)
    NumPut("UInt", 4, encoderParams, 20 + A_PtrSize)
    NumPut("UPtr", qualityValue.Ptr, encoderParams, 24 + A_PtrSize)

    return DllCall("gdiplus\GdipSaveImageToFile", "UPtr", pBitmap, "UPtr", StrPtr(filePath),
        "UPtr", pCodec, "UPtr", encoderParams.Ptr)
}

SafeRegWriteString(value, regPath, valueName) {
    try {
        RegWrite(String(value), "REG_SZ", regPath, valueName)
        return true
    } catch {
        return false
    }
}

TryReadLocalSetting(valueName, &value) {
    global REG_PATH
    try {
        value := RegRead(REG_PATH, valueName)
        return true
    } catch {
        value := ""
        return false
    }
}

ShortErrorMessage(message, maxLen := 120) {
    message := Trim(String(message))
    if (message == "")
        message := "Unknown error"
    message := StrReplace(message, "`r`n", " ")
    message := StrReplace(message, "`n", " ")
    message := StrReplace(message, "`r", " ")
    if (StrLen(message) > maxLen)
        message := SubStr(message, 1, maxLen) "..."
    return message
}

; ── UI localization ──
; Core runtime tooltips follow the Manual language preference (MANUAL_LANG).
; This is an incremental pass: only high-frequency messages are localized here.
GetDefaultUILang() {
    ; Derive a sensible default UI language from the Windows UI locale.
    switch A_Language {
        case "0412": return "ko"
        case "0415": return "pl"
        case "0407", "0807", "0c07": return "de"
        case "040c", "080c", "0c0c", "100c": return "fr"
        case "040a", "080a", "0c0a": return "es"
        default: return "en"
    }
}

GetUILang() {
    global MANUAL_LANG
    return MANUAL_LANG
}

UIText(key, replacements := 0) {
    static table := BuildUIStringTable()
    if !table.Has(key)
        return key
    entry := table[key]
    lang := GetUILang()
    text := entry.Has(lang) ? entry[lang] : entry["en"]
    if IsObject(replacements) {
        for name, value in replacements
            text := StrReplace(text, "{" name "}", String(value))
    }
    return text
}

BuildUIStringTable() {
    t := Map()
    t["startup_ready"] := Map(
        "ko", "📸 {app} 준비 완료!`r`nWin+드래그: 캡처`r`n{hotkey}: 선택 텍스트 번역",
        "en", "📸 {app} Ready!`r`nWin+Drag: Capture`r`n{hotkey}: Translate selected text",
        "pl", "📸 {app} gotowe!`r`nWin+przeciągnij: przechwyć`r`n{hotkey}: przetłumacz zaznaczony tekst",
        "de", "📸 {app} bereit!`r`nWin+Ziehen: Aufnahme`r`n{hotkey}: markierten Text übersetzen",
        "fr", "📸 {app} prêt !`r`nWin+glisser : capturer`r`n{hotkey} : traduire le texte sélectionné",
        "es", "📸 {app} listo!`r`nWin+arrastrar: capturar`r`n{hotkey}: traducir texto seleccionado")
    t["capture_failed"] := Map(
        "ko", "⚠️ 화면 캡처에 실패했습니다.",
        "en", "⚠️ Screen capture failed.",
        "pl", "⚠️ Przechwytywanie ekranu nie powiodło się.",
        "de", "⚠️ Bildschirmaufnahme fehlgeschlagen.",
        "fr", "⚠️ Échec de la capture d'écran.",
        "es", "⚠️ Error en la captura de pantalla.")
    t["copy_ok"] := Map(
        "ko", "✅ 클립보드 복사 완료: {w}×{h}`r`n{format} 예상 {size} ({quality}) | Outline {outline}",
        "en", "✅ Copied to clipboard: {w}×{h}`r`nEst. {format} {size} ({quality}) | Outline {outline}",
        "pl", "✅ Skopiowano do schowka: {w}×{h}`r`nSzac. {format} {size} ({quality}) | Kontur {outline}",
        "de", "✅ In Zwischenablage kopiert: {w}×{h}`r`nGesch. {format} {size} ({quality}) | Kontur {outline}",
        "fr", "✅ Copié dans le presse-papiers : {w}×{h}`r`n{format} est. {size} ({quality}) | Contour {outline}",
        "es", "✅ Copiado al portapapeles: {w}×{h}`r`n{format} est. {size} ({quality}) | Contorno {outline}")
    t["copy_savewarn"] := Map(
        "ko", "`r`n⚠️ 가로폭 설정을 Registry에 저장하지 못했습니다.",
        "en", "`r`n⚠️ Could not save the width setting to the Registry.",
        "pl", "`r`n⚠️ Nie udało się zapisać ustawienia szerokości w rejestrze.",
        "de", "`r`n⚠️ Breiteneinstellung konnte nicht in der Registry gespeichert werden.",
        "fr", "`r`n⚠️ Impossible d'enregistrer le réglage de largeur dans le Registre.",
        "es", "`r`n⚠️ No se pudo guardar el ajuste de ancho en el Registro.")
    t["size_unknown"] := Map(
        "ko", "확인 불가", "en", "unknown", "pl", "nieznany",
        "de", "unbekannt", "fr", "inconnu", "es", "desconocido")
    t["lossless"] := Map(
        "ko", "무손실", "en", "lossless", "pl", "bezstratny",
        "de", "verlustfrei", "fr", "sans perte", "es", "sin pérdida")
    t["copy_failed"] := Map(
        "ko", "⚠️ 클립보드 복사 실패: {error}",
        "en", "⚠️ Copy to clipboard failed: {error}",
        "pl", "⚠️ Kopiowanie do schowka nie powiodło się: {error}",
        "de", "⚠️ Kopieren in die Zwischenablage fehlgeschlagen: {error}",
        "fr", "⚠️ Échec de la copie dans le presse-papiers : {error}",
        "es", "⚠️ Error al copiar al portapapeles: {error}")
    t["save_ok"] := Map(
        "ko", "✅ {format} 저장 완료: {w}×{h} | {size}`r`n{path}",
        "en", "✅ {format} saved: {w}×{h} | {size}`r`n{path}",
        "pl", "✅ Zapisano {format}: {w}×{h} | {size}`r`n{path}",
        "de", "✅ {format} gespeichert: {w}×{h} | {size}`r`n{path}",
        "fr", "✅ {format} enregistré : {w}×{h} | {size}`r`n{path}",
        "es", "✅ {format} guardado: {w}×{h} | {size}`r`n{path}")
    t["save_failed"] := Map(
        "ko", "⚠️ 파일 저장 실패: {error}",
        "en", "⚠️ File save failed: {error}",
        "pl", "⚠️ Zapis pliku nie powiódł się: {error}",
        "de", "⚠️ Speichern der Datei fehlgeschlagen: {error}",
        "fr", "⚠️ Échec de l'enregistrement du fichier : {error}",
        "es", "⚠️ Error al guardar el archivo: {error}")
    t["translating"] := Map(
        "ko", "🌐 번역 중...", "en", "🌐 Translating...", "pl", "🌐 Tłumaczenie...",
        "de", "🌐 Übersetze...", "fr", "🌐 Traduction...", "es", "🌐 Traduciendo...")
    t["translate_failed"] := Map(
        "ko", "❌ 번역 실패: {error}",
        "en", "❌ Translation failed: {error}",
        "pl", "❌ Tłumaczenie nie powiodło się: {error}",
        "de", "❌ Übersetzung fehlgeschlagen: {error}",
        "fr", "❌ Échec de la traduction : {error}",
        "es", "❌ Error de traducción: {error}")
    return t
}

/**
 * 선택한 화면 영역을 Google 이미지 번역 페이지로 보냅니다.
 * Sends a selected screen area to Google Translate Image.
 * @returns {None}
 */
ScreenClip2GoogleImage() {
    if !EnsureTranslationConsent()
        return
    Area := SelectArea()
    if (Area.W < 10 || Area.H < 10)
        return
    pBitmap := Gdip_BitmapFromScreen(Area.X "|" Area.Y "|" Area.W "|" Area.H)
    if !pBitmap {
        ToolTip(UIText("capture_failed"))
        SetTimer(() => ToolTip(), -3000)
        return
    }

    clipBackup := SafeClipboardBackup()
    if !clipBackup.ok {
        Gdip_DisposeImage(pBitmap)
        ToolTip("⚠️ 클립보드를 백업하지 못했습니다.`r`n⚠️ Could not back up clipboard.")
        SetTimer(() => ToolTip(), -3000)
        return
    }

    try {
        Gdip_SetBitmapToClipboard(pBitmap)
        Run("https://translate.google.com/?sl=auto&tl=ko&op=images")
        ToolTip("🌐 구글 번역(이미지) 열기 중...`r`n🌐 Opening Google Image Translation...")
        AutoPasteToGoogleTranslate(clipBackup)
    } catch as e {
        SafeClipboardRestore(clipBackup)
        ToolTip("⚠️ 이미지 번역 실행 실패: " ShortErrorMessage(e.Message) "`r`n⚠️ Image translation failed.")
        SetTimer(() => ToolTip(), -3500)
    } finally {
        Gdip_DisposeImage(pBitmap)
    }
}

/**
 * 플로팅 창의 우클릭 메뉴에서 특정 타겟 언어를 선택하여 구글 이미지 번역을 실행하는 함수
 * Triggers Google Image Translation with a user-selected target language from the context menu.
 * @param {String} targetLang - 타겟 언어 코드 (ko, en, pl 등) / Target language code
 * @returns {None}
 */
GoogleImageTranslate(targetLang) {
    global RightClickedHwnd
    if !ClipWins.Has(RightClickedHwnd)
        return
    if !IsTextTranslateLangSupported(targetLang)
        targetLang := "ko"
    if !EnsureTranslationConsent()
        return

    clipBackup := SafeClipboardBackup()
    if !clipBackup.ok {
        ToolTip("⚠️ 클립보드를 백업하지 못했습니다.`r`n⚠️ Could not back up clipboard.")
        SetTimer(() => ToolTip(), -3000)
        return
    }

    pBitmap := ClipWins[RightClickedHwnd].pBitmap
    try {
        Gdip_SetBitmapToClipboard(pBitmap)
        Run("https://translate.google.com/?sl=auto&tl=" UriEncode(targetLang) "&op=images")
        ToolTip("🌐 구글 번역(이미지) 열기 중...`r`n🌐 Opening Google Image Translation...")
        AutoPasteToGoogleTranslate(clipBackup)
    } catch as e {
        SafeClipboardRestore(clipBackup)
        ToolTip("⚠️ 이미지 번역 실행 실패: " ShortErrorMessage(e.Message) "`r`n⚠️ Image translation failed.")
        SetTimer(() => ToolTip(), -3500)
    }
}

IsGoogleTranslateWindow(hwnd, patterns) {
    if !hwnd
        return false
    try {
        title := WinGetTitle("ahk_id " hwnd)
    } catch {
        return false
    }
    for _, pattern in patterns {
        if InStr(title, pattern)
            return true
    }
    return false
}

/**
 * 구글 번역 브라우저 창을 감지하고 활성화한 후 클립보드의 이미지를 자동으로 붙여넣는(Ctrl+V) RPA 루틴
 * Detects the active browser translation tab and automates clipboard paste (Ctrl+V) inputs.
 * @returns {None}
 */
AutoPasteToGoogleTranslate(clipBackup := "") {
    SetTimer(_DoPaste, -1000)

    _DoPaste() {
        global ClipWins
        ; Multilingual browser title patterns.
        patterns := ["Google Translate", "Google 번역", "Tłumacz Google", "translate.google"]
        hwndTarget := 0
        loweredClips := []

        try {
            activeHwnd := WinExist("A")
            if IsGoogleTranslateWindow(activeHwnd, patterns)
                hwndTarget := activeHwnd

            ; Wait up to 5 seconds for the browser window.
            loop 10 {
                if hwndTarget
                    break
                for _, pattern in patterns {
                    if hwnd := WinExist(pattern) {
                        hwndTarget := hwnd
                        break
                    }
                }
                if hwndTarget
                    break
                Sleep(500)
            }

            if !hwndTarget {
                ToolTip(
                    "⚠️ 브라우저를 찾을 수 없습니다. 이미지 번역을 다시 실행해 주세요.`r`n⚠️ Browser not found. Please try image translation again.")
                SetTimer(() => ToolTip(), -4000)
                return
            }

            ; Disable AlwaysOnTop on all capture windows and send them to the bottom of the z-order.
            for clipHwnd, _ in ClipWins {
                try {
                    WinSetAlwaysOnTop(false, "ahk_id " clipHwnd)
                    loweredClips.Push(clipHwnd)
                    ; HWND_BOTTOM=1, SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE=0x0013
                    DllCall("SetWindowPos", "ptr", clipHwnd, "ptr", 1, "int", 0, "int", 0, "int", 0, "int", 0,
                        "uint", 0x0013)
                }
            }

            try {
                WinActivate("ahk_id " hwndTarget)
                WinWaitActive("ahk_id " hwndTarget, , 3)
            }
            if !WinActive("ahk_id " hwndTarget)
                throw Error("Browser activation failed")
            if !IsGoogleTranslateWindow(WinExist("A"), patterns)
                throw Error("Active window is not Google Translate")

            Sleep(1500) ; Wait for page loading (1.5 seconds)

            ; Click the browser center to ensure page focus before pasting.
            WinGetPos(&winX, &winY, &winW, &winH, "ahk_id " hwndTarget)
            CoordMode("Mouse", "Screen")
            Click(winX + winW // 2, winY + winH // 2)
            Send("^v")
            Sleep(300)

            ToolTip("✅ 이미지 붙여넣기 완료!`r`n✅ Image pasted to Google Translate!")
            SetTimer(() => ToolTip(), -3000)
        } catch as e {
            ToolTip("⚠️ 이미지 붙여넣기 실패: " ShortErrorMessage(e.Message) "`r`n⚠️ Image paste failed.")
            SetTimer(() => ToolTip(), -4000)
        } finally {
            for _, clipHwnd in loweredClips {
                if WinExist("ahk_id " clipHwnd)
                    try WinSetAlwaysOnTop(true, "ahk_id " clipHwnd)
            }
            SafeClipboardRestore(clipBackup)
        }
    }
}

TrackLastTextSourceWindow() {
    global TEXT_SOURCE_LAST_HWND
    hwnd := WinExist("A")
    if !IsTextSourceWindow(hwnd)
        return
    TEXT_SOURCE_LAST_HWND := hwnd
}

IsTextSourceWindow(hwnd) {
    if !hwnd
        return false

    try className := WinGetClass("ahk_id " hwnd)
    catch
        return false

    if (className == "AutoHotkeyGUI" || className == "#32768" || className == "Shell_TrayWnd"
        || className == "NotifyIconOverflowWindow" || className == "WorkerW" || className == "Progman")
        return false

    return true
}

GetCopySourceHwnd(fromTray := false) {
    global TEXT_SOURCE_LAST_HWND
    activeHwnd := WinExist("A")
    if (!fromTray && IsTextSourceWindow(activeHwnd))
        return activeHwnd
    if (IsTextSourceWindow(TEXT_SOURCE_LAST_HWND) && WinExist("ahk_id " TEXT_SOURCE_LAST_HWND))
        return TEXT_SOURCE_LAST_HWND
    return IsTextSourceWindow(activeHwnd) ? activeHwnd : 0
}

/**
 * 외부 번역 서비스로 데이터를 전송하기 전에 최초 1회 개인정보 동의를 확인하는 함수
 * Shows a one-time privacy notice before any translation feature sends data to Google.
 * @returns {Integer} 사용자가 동의(또는 이전에 동의)했으면 true, 취소하면 false / True if consented
 */
EnsureTranslationConsent() {
    global TRANSLATE_CONSENT, REG_PATH, APP_NAME
    if TRANSLATE_CONSENT
        return true

    message := "번역 기능은 선택한 텍스트 또는 캡처 이미지를 외부 서비스(Google 번역)로 전송합니다.`r`n"
        . "계좌번호, 급여, 비밀번호, 개인정보, 내부 시스템 화면 등 민감정보가 포함되지 않았는지 먼저 확인하세요.`r`n`r`n"
        . "This feature sends the selected text or captured image to an external service (Google Translate).`r`n"
        . "Make sure it contains no sensitive data such as account numbers, salaries, passwords, or internal screens.`r`n`r`n"
        . "번역을 계속 사용하시겠습니까?  /  Continue using translation?"

    ; YesNo + warning icon + MB_TOPMOST (0x40000) so the notice is not hidden behind always-on-top windows.
    result := MsgBox(message, APP_NAME " - 번역 개인정보 안내 / Translation Privacy Notice", "YesNo Icon! 0x40000")
    if (result != "Yes")
        return false

    TRANSLATE_CONSENT := true
    ; Privacy invariant: consent remains in the app-owned registry path, never PL_Suite.
    SafeRegWriteString(1, REG_PATH, "TranslateConsent")
    return true
}

TranslateSelectedText(fromTray := false) {
    global TEXT_TRANSLATE_LANG, TEXT_TRANSLATE_MAX_CHARS
    sourceHwnd := GetCopySourceHwnd(fromTray)
    if !EnsureTranslationConsent()
        return
    clipSaved := SafeClipboardBackup()
    if !clipSaved.ok {
        ToolTip("⚠️ 클립보드를 백업하지 못했습니다.`r`n⚠️ Could not back up clipboard.")
        SetTimer(() => ToolTip(), -3000)
        return
    }

    try {
        if sourceHwnd {
            WinActivate("ahk_id " sourceHwnd)
            WinWaitActive("ahk_id " sourceHwnd, , 0.6)
            Sleep(80)
        }

        A_Clipboard := ""
        Send("^c")

        if !ClipWait(0.7) {
            Sleep(80)
            SendInput("^c")
        }

        if !ClipWait(0.8) {
            ToolTip("⚠️ 선택 텍스트를 복사하지 못했습니다.`r`n텍스트를 선택한 앱이 활성화되어 있는지 확인하세요.")
            SetTimer(() => ToolTip(), -2500)
            return
        }

        sourceText := Trim(A_Clipboard, "`r`n `t")
        if (sourceText == "") {
            ToolTip("⚠️ 선택된 텍스트가 없습니다.`r`n⚠️ No selected text.")
            SetTimer(() => ToolTip(), -2500)
            return
        }

        if (StrLen(sourceText) > TEXT_TRANSLATE_MAX_CHARS) {
            ToolTip("⚠️ 선택 텍스트가 너무 깁니다. " TEXT_TRANSLATE_MAX_CHARS "자 이하만 번역합니다.`r`n⚠️ Selected text is too long.")
            SetTimer(() => ToolTip(), -3500)
            return
        }

        ToolTip(UIText("translating"))
        translatedText := TranslateTextViaGoogle(sourceText, TEXT_TRANSLATE_LANG)
        ToolTip()
        ShowTextTranslationPopup(sourceText, translatedText)
    } catch as e {
        ToolTip(UIText("translate_failed", Map("error", ShortErrorMessage(e.Message))))
        SetTimer(() => ToolTip(), -3500)
    } finally {
        SafeClipboardRestore(clipSaved)
    }
}

TranslateTextViaGoogle(text, targetLang) {
    global TEXT_TRANSLATE_MAX_CHARS
    if !IsTextTranslateLangSupported(targetLang)
        targetLang := "ko"
    if (Trim(text) == "")
        throw Error("No text to translate")
    if (StrLen(text) > TEXT_TRANSLATE_MAX_CHARS)
        throw Error("Text is too long. Max " TEXT_TRANSLATE_MAX_CHARS " characters.")

    url := "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl="
        . targetLang . "&dt=t&q=" . UriEncode(text)

    http := ComObject("WinHttp.WinHttpRequest.5.1")
    http.Open("GET", url, false)
    ; (resolve, connect, send, receive) in ms — tolerant of corporate proxies and slow links.
    http.SetTimeouts(5000, 5000, 5000, 15000)
    http.SetRequestHeader("User-Agent", "Mozilla/5.0")
    http.Send()

    if (http.Status != 200)
        throw Error("HTTP " http.Status)

    result := ParseGoogleTranslateResponse(http.ResponseText)
    if (result == "")
        throw Error("Empty result")

    return result
}

ParseGoogleTranslateResponse(json) {
    if (SubStr(json, 1, 3) != "[[[")
        return ""

    pos := 4
    len := StrLen(json)
    text := ""

    while (pos <= len) {
        ; Append only the first string in each translation result array.
        char := SubStr(json, pos, 1)
        if (char == "`"") {
            pos++
            str := ""
            while (pos <= len) {
                c := SubStr(json, pos, 1)
                if (c == "\") {
                    str .= "\" . SubStr(json, pos + 1, 1)
                    pos += 2
                } else if (c == "`"") {
                    pos++
                    break
                } else {
                    str .= c
                    pos++
                }
            }
            text .= JsonUnescape(str)

            ; Skip source text and pronunciation data within the same sentence segment.
            bracketCount := 1
            inString := false
            while (pos <= len && bracketCount > 0) {
                c := SubStr(json, pos, 1)
                if (inString) {
                    if (c == "\")
                        pos += 2
                    else if (c == "`"") {
                        inString := false
                        pos++
                    } else {
                        pos++
                    }
                } else {
                    if (c == "`"") {
                        inString := true
                        pos++
                    } else if (c == "[") {
                        bracketCount++
                        pos++
                    } else if (c == "]") {
                        bracketCount--
                        pos++
                    } else {
                        pos++
                    }
                }
            }
        } else {
            if (char == "]") {
                break
            }
            pos++
        }

        ; Move to the next translation segment.
        nextSegFound := false
        while (pos <= len) {
            c := SubStr(json, pos, 1)
            if (c == "[") {
                pos++
                nextSegFound := true
                break
            } else if (c == "]") {
                break 2
            }
            pos++
        }
        if (!nextSegFound)
            break
    }
    return text
}

JsonUnescape(text) {
    out := "", i := 1
    while (i <= StrLen(text)) {
        ch := SubStr(text, i, 1)
        if (ch != "\") {
            out .= ch, i++
            continue
        }

        i++, esc := SubStr(text, i, 1)
        if (esc == "n")
            out .= "`n"
        else if (esc == "r")
            out .= "`r"
        else if (esc == "t")
            out .= A_Tab
        else if (esc == "b")
            out .= Chr(8)
        else if (esc == "f")
            out .= Chr(12)
        else if (esc == "u") {
            hex := SubStr(text, i + 1, 4)
            if RegExMatch(hex, "^[0-9A-Fa-f]{4}$")
                out .= Chr(Integer("0x" hex)), i += 4
        } else {
            out .= esc
        }
        i++
    }
    return out
}

GetTextTranslationPopupLangItems() {
    langItems := ["ORIGINAL"]
    for _, label in GetTextTranslateLangLabels()
        langItems.Push(label)
    return langItems
}

UpdateTextTranslationPopupResult(sourceText, selectedLabel, resultEdit, currentTextRef) {
    if (selectedLabel == "ORIGINAL") {
        try {
            currentTextRef.Value := sourceText
            resultEdit.Value := sourceText
        }
        return
    }

    targetLang := GetTextTranslateLangCodeByLabel(selectedLabel)
    try resultEdit.Value := "🌐 Translating..."

    try {
        translated := TranslateTextViaGoogle(sourceText, targetLang)
        try {
            currentTextRef.Value := translated
            resultEdit.Value := translated
        }
    } catch as e {
        try {
            currentTextRef.Value := ""
            resultEdit.Value := "❌ Translation failed: " ShortErrorMessage(e.Message)
        }
    }
}

GetCenteredPositionOnMouseMonitor(windowW, windowH) {
    CoordMode("Mouse", "Screen")
    MouseGetPos(&mx, &my)

    workLeft := 0, workTop := 0, workRight := A_ScreenWidth, workBottom := A_ScreenHeight
    try MonitorGetWorkArea(1, &workLeft, &workTop, &workRight, &workBottom)

    loop MonitorGetCount() {
        MonitorGet(A_Index, &monitorLeft, &monitorTop, &monitorRight, &monitorBottom)
        if (mx >= monitorLeft && mx < monitorRight && my >= monitorTop && my < monitorBottom) {
            MonitorGetWorkArea(A_Index, &workLeft, &workTop, &workRight, &workBottom)
            break
        }
    }

    centeredX := workLeft + (workRight - workLeft - windowW) // 2
    centeredY := workTop + (workBottom - workTop - windowH) // 2
    return {
        x: Max(workLeft, centeredX),
        y: Max(workTop, centeredY)
    }
}

GetPopupPositionNearMouse(popupW, popupH) {
    CoordMode("Mouse", "Screen")
    MouseGetPos(&mx, &my)
    workLeft := 0, workTop := 0, workRight := A_ScreenWidth, workBottom := A_ScreenHeight
    loop MonitorGetCount() {
        MonitorGetWorkArea(A_Index, &mLeft, &mTop, &mRight, &mBottom)
        if (mx >= mLeft && mx <= mRight && my >= mTop && my <= mBottom) {
            workLeft := mLeft, workTop := mTop, workRight := mRight, workBottom := mBottom
            break
        }
    }

    xMax := Max(workLeft, workRight - popupW)
    yMax := Max(workTop, workBottom - popupH)
    return {
        x: Min(Max(mx + 16, workLeft), xMax),
        y: Min(Max(my + 16, workTop), yMax)
    }
}

ShowTextTranslationPopup(sourceText, translatedText) {
    global TextTranslatePopupHwnd, TEXT_TRANSLATE_LANG, TEXT_TRANSLATE_FONT_SIZE

    if (TextTranslatePopupHwnd && WinExist("ahk_id " TextTranslatePopupHwnd))
        WinClose("ahk_id " TextTranslatePopupHwnd)

    PopGui := Gui("+AlwaysOnTop +ToolWindow +Border +Resize -DPIScale +MinSize320x200", "Translation by Google")
    PopGui.BackColor := "1E1E24"
    PopGui.SetFont("s10", "Segoe UI")

    ; ── Top area: title and temporary translation-language selector ──
    TitleLabel := PopGui.Add("Text", "x14 y12 w220 h22 +BackgroundTrans cFFFFFF", "🌐 Translation by Google")
    TitleLabel.SetFont("s10 Bold", "Segoe UI")

    LangCombo := PopGui.Add("DropDownList", "x250 y9 w156 Choose" GetTextTranslateLangIndex(TEXT_TRANSLATE_LANG) + 1,
        GetTextTranslationPopupLangItems())

    ; ── Divider ──
    SepLine := PopGui.Add("Text", "x14 y38 w392 h1 Background3F3F46", "")

    ; ── Translation result text box (single read-only multiline control with scroll) ──
    ResultEdit := PopGui.Add("Edit", "x14 y46 w392 h164 ReadOnly +Multi +VScroll", translatedText)
    ResultEdit.SetFont("s" TEXT_TRANSLATE_FONT_SIZE, "Segoe UI")

    ; ── Bottom buttons ──
    CopyBtn := PopGui.Add("Button", "x218 y220 w90 h30", "Copy")
    CloseBtn := PopGui.Add("Button", "x316 y220 w90 h30", "Close")

    ; Store the currently displayed text in an object shared by internal events.
    currentText := { Value: translatedText }

    ; ── ComboBox change triggers automatic retranslation ──
    OnLangChange(*) {
        selectedLabel := LangCombo.Text
        if (selectedLabel != "ORIGINAL") {
            targetLang := GetTextTranslateLangCodeByLabel(selectedLabel)
            SetTextTranslateLang(targetLang)
        }
        UpdateTextTranslationPopupResult(sourceText, selectedLabel, ResultEdit, currentText)
    }
    LangCombo.OnEvent("Change", OnLangChange)

    ; ── Copy button ──
    CopyTranslated(*) {
        A_Clipboard := currentText.Value
        ToolTip("✅ 번역 결과 복사 완료`r`n✅ Translation copied.")
        SetTimer(() => ToolTip(), -1500)
    }

    ; ── Close handling ──
    DestroyPopup(*) {
        global TextTranslatePopupHwnd := 0
        PopGui.Destroy()
    }

    CopyBtn.OnEvent("Click", CopyTranslated)
    CloseBtn.OnEvent("Click", DestroyPopup)
    PopGui.OnEvent("Close", DestroyPopup)
    PopGui.OnEvent("Escape", DestroyPopup)

    ; ── Resize handler: dynamically adjust control positions and sizes ──
    OnPopupResize(thisGui, MinMax, Width, Height) {
        if (MinMax == -1)  ; Skip resizing while minimized.
            return
        m := 14
        LangCombo.Move(Width - 170, 9, 156)
        SepLine.Move(m, 38, Width - m * 2)
        ResultEdit.Move(m, 46, Width - m * 2, Height - 46 - 50)
        CopyBtn.Move(Width - 202, Height - 40, 90, 30)
        CloseBtn.Move(Width - 104, Height - 40, 90, 30)
    }
    PopGui.OnEvent("Size", OnPopupResize)

    ; ── Show near the mouse cursor with dynamic size based on text length ──
    sizeFactor := Max(1.0, TEXT_TRANSLATE_FONT_SIZE / 10)
    popupW := Round(630 * sizeFactor)
    txtLen := Max(StrLen(sourceText), StrLen(translatedText))

    if (txtLen < 400)
        popupH := 540
    else if (txtLen < 1200)
        popupH := 1080
    else
        popupH := 1620

    ; Prevent the popup from becoming too large relative to the primary monitor.
    if (popupH > A_ScreenHeight - 80)
        popupH := A_ScreenHeight - 80

    popupPos := GetPopupPositionNearMouse(popupW, popupH)
    PopGui.Show("x" popupPos.x " y" popupPos.y " w" popupW " h" popupH)
    OnPopupResize(PopGui, 0, popupW, popupH)
    TextTranslatePopupHwnd := PopGui.Hwnd
}

SelectArea() {
    CoordMode "Mouse", "Screen"
    MouseGetPos &MX, &MY

    SelGui := Gui("+AlwaysOnTop -Caption +Border +ToolWindow -DPIScale")
    WinSetTransparent 80, SelGui.Hwnd
    SelGui.BackColor := "Yellow"

    loop {
        if !GetKeyState("LButton", "P")
            break
        if GetKeyState("Esc", "P") {
            SelGui.Destroy()
            return { X: 0, Y: 0, W: 0, H: 0 }
        }
        Sleep 10
        MouseGetPos &MXend, &MYend
        w := Abs(MX - MXend)
        h := Abs(MY - MYend)
        X := (MX < MXend) ? MX : MXend
        Y := (MY < MYend) ? MY : MYend
        SelGui.Show("x" X " y" Y " w" w " h" h " NA")
    }
    SelGui.Destroy()

    MouseGetPos &MXend, &MYend
    X := (MX < MXend) ? MX : MXend
    Y := (MY < MYend) ? MY : MYend
    W := Abs(MX - MXend)
    H := Abs(MY - MYend)

    return { X: X, Y: Y, W: W, H: H }
}

DrawRectPreview(bgColor, hasBorder := true) {
    CoordMode("Mouse", "Screen")
    MouseGetPos(&screenStartX, &screenStartY)
    options := "+AlwaysOnTop -Caption +ToolWindow +E0x20 -DPIScale" . (hasBorder ? " +Border" : "")
    PreviewGui := Gui(options)
    WinSetTransparent(100, PreviewGui.Hwnd)
    PreviewGui.BackColor := bgColor

    x := 0, y := 0, w := 0, h := 0
    loop {
        if !GetKeyState("LButton", "P")
            break
        Sleep(10)
        MouseGetPos(&sMXend, &sMYend)

        w := Abs(screenStartX - sMXend)
        h := Abs(screenStartY - sMYend)
        x := (screenStartX < sMXend) ? screenStartX : sMXend
        y := (screenStartY < sMYend) ? screenStartY : sMYend
        if (w > 0 && h > 0)
            PreviewGui.Show("x" x " y" y " w" w " h" h " NA")
    }
    PreviewGui.Destroy()
    return { x: x, y: y, w: w, h: h }
}

; Rubber-band preview that also preserves drag direction (start -> end) for arrows.
DrawVectorPreview(bgColor := "Red") {
    CoordMode("Mouse", "Screen")
    MouseGetPos(&sx, &sy)
    PreviewGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20 -DPIScale +Border")
    WinSetTransparent(120, PreviewGui.Hwnd)
    PreviewGui.BackColor := bgColor

    ex := sx, ey := sy
    loop {
        if !GetKeyState("LButton", "P")
            break
        Sleep(10)
        MouseGetPos(&ex, &ey)
        x := Min(sx, ex), y := Min(sy, ey)
        w := Abs(sx - ex), h := Abs(sy - ey)
        if (w > 0 && h > 0)
            PreviewGui.Show("x" x " y" y " w" w " h" h " NA")
    }
    PreviewGui.Destroy()
    return { x1: sx, y1: sy, x2: ex, y2: ey }
}

/**
 * 플로팅 캡처 창 GUI를 생성하고 화면에 표시하는 함수
 * Creates and displays the borderless floating clipping window GUI.
 * @param {Integer} pBitmap - GDI+ 비트맵 포인터 / GDI+ bitmap pointer
 * @param {Integer} x - 시작 X 좌표 / Start X screen coordinate
 * @param {Integer} y - 시작 Y 좌표 / Start Y screen coordinate
 * @returns {Integer} 생성된 GUI 윈도우의 HWND / The created window's HWND handle
 */
CreateClipWin(pBitmap, x, y) {
    ClipGui := Gui("-Caption +ToolWindow +AlwaysOnTop +OwnDialogs -DPIScale", "ScreenClippingWindow")
    ClipGui.MarginX := 0
    ClipGui.MarginY := 0
    ClipGui.BackColor := "000000" ; Thin black window border

    W := Gdip_GetImageWidth(pBitmap)
    H := Gdip_GetImageHeight(pBitmap)

    hBitmap := Gdip_CreateHBITMAPFromBitmap(pBitmap)
    Pic := ClipGui.Add("Picture", "x" WINDOW_BORDER_WIDTH " y" WINDOW_BORDER_WIDTH " w" W " h" H, "HBITMAP:*" hBitmap)
    DllCall("DeleteObject", "ptr", hBitmap)

    ; Add a tiny close button in the top right
    CloseBtnSize := 16
    CloseBtnX := W + (WINDOW_BORDER_WIDTH * 2) - CloseBtnSize - 1
    CloseBtnY := 1
    CloseBtn := ClipGui.Add("Text", "x" CloseBtnX " y" CloseBtnY " w" CloseBtnSize " h" CloseBtnSize " Center +BackgroundTrans cWhite +0x200",
        "×")
    CloseBtn.SetFont("s14 Bold")
    CloseBtn.OnEvent("Click", (*) => CloseClipWin(ClipGui))

    ; Find the lowest available number.
    assignedId := 1
    loop {
        inUse := false
        for h, info in ClipWins {
            if (info.HasProp("id") && info.id == assignedId) {
                inUse := true
                break
            }
        }
        if (!inUse)
            break
        assignedId++
    }

    ; Add a slightly smaller black layer behind the number for readability.
    NumBg := ClipGui.Add("Text", "x15 y15 w50 h50 Background222222 Hidden", "")

    ; Number shown while minimized.
    ; Keep the AHK Text control fully transparent and use GUI opacity for visibility.
    NumText := ClipGui.Add("Text", "x0 y0 w80 h80 Center 0x200 +BackgroundTrans cYellow Hidden", assignedId)
    NumText.SetFont("s24 Bold", "Verdana")

    ClipGui.Show("x" (x - WINDOW_BORDER_WIDTH) " y" (y - WINDOW_BORDER_WIDTH) " w" (W + WINDOW_BORDER_WIDTH * 2) " h" (H + WINDOW_BORDER_WIDTH * 2) " NA"
    )

    hwnd := ClipGui.Hwnd
    ClipWins[hwnd] := { pBitmap: pBitmap, w: W, h: H, gui: ClipGui, IsMinimized: false, id: assignedId, NumText: NumText,
        NumBg: NumBg,
        picCtrl: Pic, UndoStack: [], AnnotSeq: 1, orgX: x - WINDOW_BORDER_WIDTH, orgY: y - WINDOW_BORDER_WIDTH }

    ; Mouse message handlers (WM_LBUTTONDOWN/DBLCLK/RBUTTONDOWN) are registered once at startup.

    ClipGui.OnEvent("Close", (*) => CloseClipWin(ClipGui))

    UpdateTrayTip()
    return hwnd
}

CloseClipWin(guiObj) {
    try hwnd := guiObj.Hwnd
    catch
        return

    if ClipWins.Has(hwnd) {
        winInfo := ClipWins[hwnd]
        try {
            for _, bmp in winInfo.UndoStack
                try Gdip_DisposeImage(bmp)
            try Gdip_DisposeImage(winInfo.pBitmap)
            ClipWins.Delete(hwnd)
        }
    }
    try guiObj.Destroy()
    UpdateTrayTip()
}

UpdateTrayTip() {
    global APP_NAME
    cnt := ClipWins.Count
    A_IconTip := APP_NAME . (cnt > 0 ? " (" cnt " clip" (cnt > 1 ? "s" : "") ")" : "")
}

WM_LBUTTONDOWN(wParam, lParam, msg, hwnd) {
    global ANNOTATION_MODE, ANNOTATION_TARGET_HWND
    if !ClipWins.Has(hwnd)
        return

    static LastClickTime := 0
    static LastClickHwnd := 0

    winInfo := ClipWins[hwnd]

    if (ANNOTATION_MODE != "" && hwnd == ANNOTATION_TARGET_HWND) {
        mode := ANNOTATION_MODE
        ANNOTATION_MODE := ""
        ANNOTATION_TARGET_HWND := 0
        SetTimer(ClearAnnotationMode, 0)
        ToolTip()
        SCW_ApplyAnnotation(hwnd, mode)
        return
    }

    ; --- Drawing modes (Shift: red box, Ctrl: yellow highlight, Alt: green highlight, Shift+Ctrl: text markup) ---
    if GetKeyState("Shift", "P") || GetKeyState("Ctrl", "P") || GetKeyState("Alt", "P") {
        if GetKeyState("Shift", "P") && GetKeyState("Ctrl", "P")
            SCW_ApplyAnnotation(hwnd, "Text")
        else if GetKeyState("Shift", "P")
            SCW_ApplyAnnotation(hwnd, "Red")
        else if GetKeyState("Ctrl", "P") {
            SCW_ApplyAnnotation(hwnd, "Yellow")
        } else if GetKeyState("Alt", "P")
            SCW_ApplyAnnotation(hwnd, "Green")
        return
    }
    isDoubleClick := (msg == 0x0203) || (hwnd == LastClickHwnd && A_TickCount - LastClickTime < DllCall(
        "GetDoubleClickTime"))

    ; Detect double-click.
    if isDoubleClick {
        LastClickTime := 0 ; Reset

        if winInfo.IsMinimized {
            ; Restore original size.
            WinMove(winInfo.orgX, winInfo.orgY, winInfo.w + WINDOW_BORDER_WIDTH * 2, winInfo.h + WINDOW_BORDER_WIDTH * 2, hwnd)
            WinSetTransparent("Off", hwnd)
            winInfo.NumText.Visible := false
            winInfo.NumBg.Visible := false
            winInfo.IsMinimized := false
        } else {
            WinGetPos(&oX, &oY, , , "ahk_id " hwnd)
            winInfo.orgX := oX
            winInfo.orgY := oY
            WinMove(, , MINI_SIZE, MINI_SIZE, hwnd)
            WinSetTransparent(MINI_OPACITY, hwnd) ; Set 50% opacity.
            winInfo.NumBg.Visible := true ; Show the black background slightly.
            winInfo.NumText.Visible := true
            winInfo.NumText.Redraw()
            winInfo.IsMinimized := true
        }
        return
    }

    LastClickTime := A_TickCount
    LastClickHwnd := hwnd

    ; Move window when clicking anywhere
    PostMessage 0xA1, 2, , , "ahk_id " hwnd
}

SCW_ApplyAnnotation(hwnd, mode) {
    if !ClipWins.Has(hwnd)
        return

    winInfo := ClipWins[hwnd]
    try WinGetPos(&winX, &winY, , , "ahk_id " hwnd)
    catch
        return

    if (mode == "Text") {
        ; Capture mouse position before opening InputBox
        CoordMode("Mouse", "Screen")
        MouseGetPos(&clickX, &clickY)

        ; Prevent dialog from opening behind the always-on-top window
        winInfo.gui.Opt("+OwnDialogs")

        ; Calculate position near the mouse
        pos := GetPopupPositionNearMouse(320, 130)

        ; Prompt for text annotation
        ib := InputBox("Enter the text to display on the image:`n(The text will be printed in red at the clicked location)", "Add Text Annotation", "X" pos.x " Y" pos.y " w320 h130")
        if (ib.Result != "OK" || ib.Value == "")
            return
        textVal := ib.Value
    }
    else if (mode == "Number") {
        ; Click-based like Text, but stamps an auto-incrementing numbered pin.
        CoordMode("Mouse", "Screen")
        MouseGetPos(&clickX, &clickY)
    }
    else if (mode == "Red")
        rect := DrawRectPreview("Red")
    else if (mode == "Yellow")
        rect := DrawRectPreview("Yellow", false)
    else if (mode == "Green")
        rect := DrawRectPreview("Lime", false)
    else if (mode == "Mosaic")
        rect := DrawRectPreview("Gray")
    else if (mode == "Arrow")
        vec := DrawVectorPreview("Red")
    else
        return

    isRectMode := (mode == "Red" || mode == "Yellow" || mode == "Green" || mode == "Mosaic")
    if (isRectMode && (rect.w <= 0 || rect.h <= 0))
        return
    if (mode == "Arrow") {
        vdx := vec.x2 - vec.x1, vdy := vec.y2 - vec.y1
        if (Sqrt(vdx * vdx + vdy * vdy) < 6)
            return
    }

    clone := 0, pGraphics := 0, pPen := 0, pBrush := 0, hBitmap := 0
    try {
        clone := Gdip_CloneBitmapArea(winInfo.pBitmap, 0, 0, winInfo.w, winInfo.h)
        if !clone
            throw Error("Could not create undo image")

        if (mode == "Text" || mode == "Number") {
            rectX := clickX - (winX + WINDOW_BORDER_WIDTH)
            rectY := clickY - (winY + WINDOW_BORDER_WIDTH)
        } else if (isRectMode) {
            rectX := rect.x - (winX + WINDOW_BORDER_WIDTH)
            rectY := rect.y - (winY + WINDOW_BORDER_WIDTH)
        }
        ; Arrow computes its own endpoint coordinates in the drawing branch below.

        pGraphics := Gdip_GraphicsFromImage(winInfo.pBitmap)
        if !pGraphics
            throw Error("Could not prepare drawing surface")

        if (mode == "Text") {
            status := Gdip_TextToGraphics(pGraphics, textVal, "x" rectX " y" rectY " cFFFF0000 s14 Bold", "Arial", winInfo.w - rectX, winInfo.h - rectY)
            if (status < 0)
                throw Error("Gdip_TextToGraphics failed with status " status)
        } else if (mode == "Red") {
            pPen := Gdip_CreatePen("0xFFFF0000", ANNOTATION_BORDER_WIDTH)
            if !pPen
                throw Error("Could not create pen")
            Gdip_DrawRectangle(pGraphics, pPen, rectX, rectY, rect.w, rect.h)
        } else if (mode == "Yellow") {
            pBrush := Gdip_BrushCreateSolid("0x77FFFF00")
            if !pBrush
                throw Error("Could not create brush")
            Gdip_FillRectangle(pGraphics, pBrush, rectX, rectY, rect.w, rect.h)
        } else if (mode == "Green") {
            pBrush := Gdip_BrushCreateSolid("0x7700FF00")
            if !pBrush
                throw Error("Could not create brush")
            Gdip_FillRectangle(pGraphics, pBrush, rectX, rectY, rect.w, rect.h)
        } else if (mode == "Number") {
            radius := 15
            fontSize := 13
            pBrush := Gdip_BrushCreateSolid("0xFFFF0000")
            if !pBrush
                throw Error("Could not create brush")
            Gdip_FillEllipse(pGraphics, pBrush, rectX - radius, rectY - radius, radius * 2, radius * 2)
            seq := winInfo.AnnotSeq
            status := Gdip_TextToGraphics(pGraphics, String(seq), "x" (rectX - radius) " y" (rectY - radius) " cFFFFFFFF s" fontSize " Bold Center vCenter", "Arial", radius * 2, radius * 2)
            if (status < 0)
                throw Error("Gdip_TextToGraphics failed with status " status)
            winInfo.AnnotSeq := seq + 1
        } else if (mode == "Mosaic") {
            ; Clamp the region to the image bounds before pixelating.
            rx := Max(0, rectX)
            ry := Max(0, rectY)
            rRight := Min(winInfo.w, rectX + rect.w)
            rBottom := Min(winInfo.h, rectY + rect.h)
            rw := rRight - rx
            rh := rBottom - ry
            if (rw >= 1 && rh >= 1) {
                region := Gdip_CloneBitmapArea(winInfo.pBitmap, rx, ry, rw, rh)
                if region {
                    blockSize := 10
                    smallW := Max(1, rw // blockSize)
                    smallH := Max(1, rh // blockSize)
                    small := Gdip_CreateBitmap(smallW, smallH)
                    if small {
                        gSmall := Gdip_GraphicsFromImage(small)
                        Gdip_SetInterpolationMode(gSmall, 7) ; average colors while downscaling
                        Gdip_DrawImage(gSmall, region, 0, 0, smallW, smallH, 0, 0, rw, rh)
                        Gdip_DeleteGraphics(gSmall)
                        Gdip_SetInterpolationMode(pGraphics, 5) ; NearestNeighbor -> blocky mosaic
                        Gdip_SetCompositingMode(pGraphics, 1)   ; SourceCopy -> replace pixels
                        Gdip_DrawImage(pGraphics, small, rx, ry, rw, rh, 0, 0, smallW, smallH)
                        Gdip_DisposeImage(small)
                    }
                    Gdip_DisposeImage(region)
                }
            }
        } else if (mode == "Arrow") {
            pPen := Gdip_CreatePen("0xFFFF0000", ANNOTATION_BORDER_WIDTH)
            if !pPen
                throw Error("Could not create pen")
            ax1 := vec.x1 - (winX + WINDOW_BORDER_WIDTH)
            ay1 := vec.y1 - (winY + WINDOW_BORDER_WIDTH)
            ax2 := vec.x2 - (winX + WINDOW_BORDER_WIDTH)
            ay2 := vec.y2 - (winY + WINDOW_BORDER_WIDTH)
            Gdip_DrawLine(pGraphics, pPen, ax1, ay1, ax2, ay2)
            ; Arrowhead: two short lines drawn back from the tip.
            adx := ax2 - ax1, ady := ay2 - ay1
            alen := Sqrt(adx * adx + ady * ady)
            if (alen > 0) {
                ux := adx / alen, uy := ady / alen
                headLen := Max(12, ANNOTATION_BORDER_WIDTH * 5)
                headW := headLen * 0.6
                bx := ax2 - ux * headLen, by := ay2 - uy * headLen
                perpX := -uy, perpY := ux
                Gdip_DrawLine(pGraphics, pPen, ax2, ay2, bx + perpX * headW, by + perpY * headW)
                Gdip_DrawLine(pGraphics, pPen, ax2, ay2, bx - perpX * headW, by - perpY * headW)
            }
        }

        hBitmap := Gdip_CreateHBITMAPFromBitmap(winInfo.pBitmap)
        if !hBitmap
            throw Error("Could not refresh image")
        winInfo.picCtrl.Value := "HBITMAP:*" hBitmap

        winInfo.UndoStack.Push(clone)
        clone := 0
        if (winInfo.UndoStack.Length > UNDO_MAX) {
            oldest := winInfo.UndoStack.RemoveAt(1)
            try Gdip_DisposeImage(oldest)
        }
    } catch as e {
        ToolTip("⚠️ 주석 그리기 실패: " ShortErrorMessage(e.Message) "`r`n⚠️ Annotation failed.")
        SetTimer(() => ToolTip(), -2500)
    } finally {
        if pPen
            Gdip_DeletePen(pPen)
        if pBrush
            Gdip_DeleteBrush(pBrush)
        if pGraphics
            Gdip_DeleteGraphics(pGraphics)
        if hBitmap
            DllCall("DeleteObject", "ptr", hBitmap)
        if clone
            Gdip_DisposeImage(clone)
    }
}

StartAnnotationMode(mode) {
    global ANNOTATION_MODE, ANNOTATION_TARGET_HWND, RightClickedHwnd
    if !ClipWins.Has(RightClickedHwnd)
        return

    ANNOTATION_MODE := mode
    ANNOTATION_TARGET_HWND := RightClickedHwnd
    WinActivate("ahk_id " ANNOTATION_TARGET_HWND)
    if (mode == "Text" || mode == "Number")
        ToolTip("✍️ 주석을 추가할 위치를 마우스로 클릭하세요.`r`n✍️ Click on the clip to place it.")
    else
        ToolTip("📝 마우스로 영역을 드래그하세요.`r`n📝 Drag an area on the clip.")
    SetTimer(ClearAnnotationMode, 0)
    SetTimer(ClearAnnotationMode, -10000)
}

ClearAnnotationMode() {
    global ANNOTATION_MODE, ANNOTATION_TARGET_HWND
    ANNOTATION_MODE := ""
    ANNOTATION_TARGET_HWND := 0
    ToolTip()
}

SCW_Win2Clipboard() {
    hwnd := WinExist("A")
    if !ClipWins.Has(hwnd)
        return

    CopyBitmapToClipboard(ClipWins[hwnd].pBitmap)
}

SCW_SetWidthAndCopy(width) {
    hwnd := WinExist("A")
    if !ClipWins.Has(hwnd)
        return

    settingsSaved := SetClipWidth(width)
    CopyBitmapToClipboard(ClipWins[hwnd].pBitmap, settingsSaved)
}

SCW_Win2File() {
    hwnd := WinExist("A")
    if !ClipWins.Has(hwnd)
        return

    SaveBitmapToDesktop(ClipWins[hwnd].pBitmap)
}

CopyBitmapToClipboard(pBitmap, settingsSaved := true) {
    global CLIP_WIDTH, COPY_OUTLINE_ENABLED, SAVE_IMAGE_FORMAT, JPG_QUALITY
    pOutput := 0
    try {
        if !pBitmap
            throw Error("Invalid bitmap")

        pOutput := CreateOutputBitmap(pBitmap, CLIP_WIDTH, COPY_OUTLINE_ENABLED)
        if !pOutput
            throw Error("Could not prepare image")

        Gdip_SetBitmapToClipboard(pOutput)
        finalW := Gdip_GetImageWidth(pOutput)
        finalH := Gdip_GetImageHeight(pOutput)
        estimatedBytes := GetEstimatedImageSize(pOutput, SAVE_IMAGE_FORMAT, JPG_QUALITY)
        sizeText := estimatedBytes >= 0 ? Format("{:.2f} MB", estimatedBytes / 1048576) : UIText("size_unknown")
        formatText := StrUpper(SAVE_IMAGE_FORMAT)
        qualityText := SAVE_IMAGE_FORMAT == "jpg" ? JPG_QUALITY "%" : UIText("lossless")
        outlineText := COPY_OUTLINE_ENABLED ? "ON" : "OFF"
        saveWarning := settingsSaved ? "" : UIText("copy_savewarn")
        ToolTip(UIText("copy_ok", Map("w", finalW, "h", finalH, "format", formatText, "size", sizeText,
            "quality", qualityText, "outline", outlineText)) saveWarning)
        SetTimer(() => ToolTip(), -3000)
    } catch as e {
        ToolTip(UIText("copy_failed", Map("error", ShortErrorMessage(e.Message))))
        SetTimer(() => ToolTip(), -3500)
    } finally {
        if pOutput
            Gdip_DisposeImage(pOutput)
    }
}

SaveBitmapToDesktop(pBitmap) {
    global CLIP_WIDTH, COPY_OUTLINE_ENABLED, SAVE_IMAGE_FORMAT, JPG_QUALITY
    pOutput := 0
    try {
        if !pBitmap
            throw Error("Invalid bitmap")
        pOutput := CreateOutputBitmap(pBitmap, CLIP_WIDTH, COPY_OUTLINE_ENABLED)
        if !pOutput
            throw Error("Could not prepare image")
        TodayDate := FormatTime(, "yyyy-MM-dd_HHmmss")
        FileOut := GetUniqueFilePath(GetSaveFolder(), TodayDate, SAVE_IMAGE_FORMAT)
        if !SafeSaveBitmapToFile(pOutput, FileOut, JPG_QUALITY)
            throw Error("Could not save image file")
        finalW := Gdip_GetImageWidth(pOutput)
        finalH := Gdip_GetImageHeight(pOutput)
        fileBytes := FileGetSize(FileOut)
        ToolTip(UIText("save_ok", Map("format", StrUpper(SAVE_IMAGE_FORMAT), "w", finalW, "h", finalH,
            "size", Format("{:.2f} MB", fileBytes / 1048576), "path", FileOut)))
        SetTimer(() => ToolTip(), -3000)
    } catch as e {
        ToolTip(UIText("save_failed", Map("error", ShortErrorMessage(e.Message))))
        SetTimer(() => ToolTip(), -3500)
    } finally {
        if pOutput
            Gdip_DisposeImage(pOutput)
    }
}

CopyBitmapToPaint(pBitmap) {
    global TEMP_FILES
    try {
        if !pBitmap
            throw Error("Invalid bitmap")
        tempFile := A_Temp "\clipocr_pro_paint_" A_Now "_" A_TickCount ".png"
        if !SafeSaveBitmapToFile(pBitmap, tempFile)
            throw Error("Could not save temporary image")
        TEMP_FILES.Push(tempFile)
        Run("mspaint.exe `"" tempFile "`"")
    } catch as e {
        if IsSet(tempFile)
            try FileDelete(tempFile)
        ToolTip("⚠️ Paint 실행 실패: " ShortErrorMessage(e.Message) "`r`n⚠️ Could not open Paint.")
        SetTimer(() => ToolTip(), -3500)
    }
}

SCW_Undo(targetHwnd := 0) {
    hwnd := targetHwnd ? targetHwnd : WinExist("A")
    if !ClipWins.Has(hwnd)
        return
    winInfo := ClipWins[hwnd]
    if (winInfo.UndoStack.Length > 0) {
        popped := winInfo.UndoStack.Pop()
        Gdip_DisposeImage(winInfo.pBitmap)
        winInfo.pBitmap := popped

        hBitmap := Gdip_CreateHBITMAPFromBitmap(winInfo.pBitmap)
        winInfo.picCtrl.Value := "HBITMAP:*" hBitmap
        DllCall("DeleteObject", "ptr", hBitmap)
    } else {
        ToolTip("⚠️ 되돌릴 작업이 없습니다.`r`n⚠️ Nothing to undo.")
        SetTimer(() => ToolTip(), -2000)
    }
}

SCW_CloseWin() {
    hwnd := WinExist("A")
    if ClipWins.Has(hwnd) {
        CloseClipWin(ClipWins[hwnd].gui)
    }
}

WM_RBUTTONDOWN(wParam, lParam, msg, hwnd) {
    if !ClipWins.Has(hwnd)
        return
    global RightClickedHwnd := hwnd

    if (ClipWins[hwnd].UndoStack.Length > 0)
        ClipMenu.Enable("↩️ 9. Undo Draw (Ctrl+Z)")
    else
        ClipMenu.Disable("↩️ 9. Undo Draw (Ctrl+Z)")

    ClipMenu.Show()
}

MenuHandler(ItemName, ItemPos, MyMenu) {
    global RightClickedHwnd
    if !ClipWins.Has(RightClickedHwnd)
        return

    pBitmap := ClipWins[RightClickedHwnd].pBitmap

    if InStr(ItemName, "Red Box") {
        StartAnnotationMode("Red")
    }
    else if InStr(ItemName, "Yellow Highlight") {
        StartAnnotationMode("Yellow")
    }
    else if InStr(ItemName, "Green Highlight") {
        StartAnnotationMode("Green")
    }
    else if InStr(ItemName, "Arrow") {
        StartAnnotationMode("Arrow")
    }
    else if InStr(ItemName, "Number Pin") {
        StartAnnotationMode("Number")
    }
    else if InStr(ItemName, "Mosaic") {
        StartAnnotationMode("Mosaic")
    }
    else if InStr(ItemName, "Text Markup") {
        StartAnnotationMode("Text")
    }
    else if InStr(ItemName, "Copy To Paint") {
        CopyBitmapToPaint(pBitmap)
    }
    else if InStr(ItemName, "Save to File") {
        SaveBitmapToDesktop(pBitmap)
    }
    else if InStr(ItemName, "Copy to Clipboard") {
        CopyBitmapToClipboard(pBitmap)
    }
    else if InStr(ItemName, "Undo Draw") {
        SCW_Undo(RightClickedHwnd)
    }
}

; ── Shared resize and optional-outline pipeline for clipboard/save output ──
CreateOutputBitmap(pBitmap, targetWidth, addOutline) {
    if !pBitmap
        return 0
    w := Gdip_GetImageWidth(pBitmap)
    h := Gdip_GetImageHeight(pBitmap)
    if (w <= 0 || h <= 0)
        return 0

    targetWidth := NormalizeClipWidth(targetWidth)
    outputW := targetWidth == 0 ? w : targetWidth
    outputH := Max(1, Round(h * outputW / w))
    pNew := Gdip_CreateBitmap(outputW, outputH)
    if !pNew
        return 0
    pGraphics := Gdip_GraphicsFromImage(pNew)
    if !pGraphics {
        Gdip_DisposeImage(pNew)
        return 0
    }

    Gdip_SetInterpolationMode(pGraphics, 7) ; 7 = HighQualityBicubic
    Gdip_SetCompositingMode(pGraphics, 1) ; 1 = SourceCopy
    if DrawResizedImageWithEdgeWrap(pGraphics, pBitmap, outputW, outputH, w, h) != 0 {
        Gdip_DeleteGraphics(pGraphics)
        Gdip_DisposeImage(pNew)
        return 0
    }

    if addOutline {
        pPen := Gdip_CreatePen("0xFF000000", 1)
        if !pPen {
            Gdip_DeleteGraphics(pGraphics)
            Gdip_DisposeImage(pNew)
            return 0
        }
        Gdip_DrawRectangle(pGraphics, pPen, 0, 0, outputW - 1, outputH - 1)
        Gdip_DeletePen(pPen)
    }
    Gdip_DeleteGraphics(pGraphics)
    return pNew
}

DrawResizedImageWithEdgeWrap(pGraphics, pBitmap, destW, destH, sourceW, sourceH) {
    imageAttr := 0
    status := DllCall("gdiplus\GdipCreateImageAttributes", "UPtr*", &imageAttr)
    if (status != 0 || !imageAttr)
        return Gdip_DrawImage(pGraphics, pBitmap, 0, 0, destW, destH, 0, 0, sourceW, sourceH)

    try {
        ; TileFlipXY extends edge pixels for high-quality resizing without transparent seams.
        status := DllCall("gdiplus\GdipSetImageAttributesWrapMode", "UPtr", imageAttr, "Int", 3, "UInt", 0, "Int", 0)
        if (status != 0)
            return status
        return DllCall("gdiplus\GdipDrawImageRectRect", "UPtr", pGraphics, "UPtr", pBitmap,
            "Float", 0, "Float", 0, "Float", destW, "Float", destH,
            "Float", 0, "Float", 0, "Float", sourceW, "Float", sourceH,
            "Int", 2, "UPtr", imageAttr, "UPtr", 0, "UPtr", 0)
    } finally {
        Gdip_DisposeImageAttributes(imageAttr)
    }
}

GetEstimatedImageSize(pBitmap, format, quality) {
    if !pBitmap
        return -1

    format := NormalizeSaveImageFormat(format)
    estimateDir := A_Temp "\ClipOCR-Pro"
    estimateFile := estimateDir "\image_estimate_" DllCall("GetCurrentProcessId") "_" A_TickCount "." format
    try {
        if !DirExist(estimateDir)
            DirCreate(estimateDir)
        if !SafeSaveBitmapToFile(pBitmap, estimateFile, quality)
            return -1
        return FileGetSize(estimateFile)
    } catch {
        return -1
    } finally {
        try {
            if FileExist(estimateFile)
                FileDelete(estimateFile)
        }
    }
}

UriEncode(Uri) {
    buf := Buffer(StrPut(Uri, "UTF-8"), 0)
    StrPut(Uri, buf, "UTF-8")
    Res := ""
    loop buf.Size - 1 {
        Code := NumGet(buf, A_Index - 1, "UChar")
        if (Code >= 0x30 && Code <= 0x39 || Code >= 0x41 && Code <= 0x5A || Code >= 0x61 && Code <= 0x7A || InStr(
            "-._~", Chr(Code)))
            Res .= Chr(Code)
        else
            Res .= Format("%{:02X}", Code)
    }
    return Res
}

; ── Clipboard-width menu update and persistence ──
SetClipWidth(width) {
    global CLIP_WIDTH, REG_PATH
    width := NormalizeClipWidth(width)
    CLIP_WIDTH := width
    saved := SafeRegWriteString(width, REG_PATH, "ClipboardWidth")
    UpdateWidthMenu()
    return saved
}

SetCopyOutline(enabled) {
    global COPY_OUTLINE_ENABLED, REG_PATH
    COPY_OUTLINE_ENABLED := enabled ? true : false
    return SafeRegWriteString(COPY_OUTLINE_ENABLED ? 1 : 0, REG_PATH, "CopyOutline")
}

SetJpegQuality(quality) {
    global JPG_QUALITY, REG_PATH
    JPG_QUALITY := NormalizeJpegQuality(quality)
    return SafeRegWriteString(JPG_QUALITY, REG_PATH, "JpegQuality")
}

SetSaveImageFormat(format) {
    global SAVE_IMAGE_FORMAT, REG_PATH
    SAVE_IMAGE_FORMAT := NormalizeSaveImageFormat(format)
    return SafeRegWriteString(SAVE_IMAGE_FORMAT, REG_PATH, "SaveImageFormat")
}

BindImageSavePreset(presetIndex) {
    return (*) => ApplyImageSavePreset(presetIndex)
}

ApplyImageSavePreset(presetIndex, showFeedback := true) {
    presets := GetImageSavePresetOptions()
    if (presetIndex < 1 || presetIndex > presets.Length)
        presetIndex := 1
    preset := presets[presetIndex]
    formatSaved := SetSaveImageFormat(preset.format)
    qualitySaved := SetJpegQuality(preset.quality)
    UpdateImageSavePresetMenu()

    if showFeedback {
        saveWarning := (formatSaved && qualitySaved) ? "" : "`r`n⚠️ Could not save this preset to the Registry."
        ToolTip("✅ Image preset: " preset.label saveWarning)
        SetTimer(() => ToolTip(), -3000)
    }
    return formatSaved && qualitySaved
}

UpdateImageSavePresetMenu() {
    global ImagePresetMenu, SAVE_IMAGE_FORMAT, JPG_QUALITY
    if !IsObject(ImagePresetMenu)
        return
    presets := GetImageSavePresetOptions()
    for _, preset in presets
        try ImagePresetMenu.Uncheck(preset.label)
    selectedIndex := GetImageSavePresetIndex(SAVE_IMAGE_FORMAT, JPG_QUALITY)
    try ImagePresetMenu.Check(presets[selectedIndex].label)
}

UpdateWidthMenu() {
    global CLIP_WIDTH
    for _, width in GetClipWidths()
        WidthMenu.Uncheck(GetClipWidthMenuLabel(width))
    WidthMenu.Check(GetClipWidthMenuLabel(CLIP_WIDTH))
}

GetClipWidths() {
    return [0, 400, 600, 800, 1000, 1200, 1400, 1600]
}

GetClipWidthShortcutNumber(width) {
    if (width == 0)
        return 0
    return width // 200 - 1
}

GetClipWidthMenuLabel(width) {
    if (width == 0)
        return "Original Size (Ctrl+0)"
    return width " px (Ctrl+" GetClipWidthShortcutNumber(width) ")"
}

GetClipWidthLabels() {
    labels := []
    for _, width in GetClipWidths()
        labels.Push(GetClipWidthMenuLabel(width))
    return labels
}

GetClipWidthIndex(width) {
    width := NormalizeClipWidth(width)
    for index, value in GetClipWidths() {
        if (width == value)
            return index
    }
    return 5
}

GetClipWidthFromLabel(label) {
    if InStr(label, "Original Size")
        return 0
    if RegExMatch(label, "^(\d+)", &match)
        return NormalizeClipWidth(match[1])
    return 1000
}

GetImageSavePresetOptions() {
    ; Ratios are quick planning estimates. The real tooltip estimate remains authoritative.
    return [{ label: "PNG Lossless — Size Doc 100% · Pic 100%", format: "png", quality: 90 },
        { label: "JPG 90% High — Size Doc 83% · Pic 70%", format: "jpg", quality: 90 },
        { label: "JPG 80% Medium — Size Doc 65% · Pic 50%", format: "jpg", quality: 80 },
        { label: "JPG 70% Low — Size Doc 50% · Pic 35%", format: "jpg", quality: 70 }]
}

GetImageSavePresetLabels() {
    labels := []
    for _, option in GetImageSavePresetOptions()
        labels.Push(option.label)
    return labels
}

GetImageSavePresetIndex(format, quality) {
    format := NormalizeSaveImageFormat(format)
    quality := NormalizeJpegQuality(quality)
    for index, option in GetImageSavePresetOptions() {
        if (option.format == format && (format == "png" || option.quality == quality))
            return index
    }
    return 1
}

GetImageSavePresetFromLabel(label) {
    for _, option in GetImageSavePresetOptions() {
        if (option.label == label)
            return option
    }
    return GetImageSavePresetOptions()[1]
}

GetTextTranslateLangOptions() {
    static options := 0
    if !options {
        options := [{ label: "Korean (ko)", code: "ko" }, { label: "English (en)", code: "en" }, { label: "Polish (pl)", code: "pl" }, { label: "Albanian (sq)", code: "sq" }, { label: "Armenian (hy)", code: "hy" }, { label: "Azerbaijani (az)", code: "az" }, { label: "Basque (eu)", code: "eu" }, { label: "Belarusian (be)", code: "be" }, { label: "Bosnian (bs)", code: "bs" }, { label: "Bulgarian (bg)", code: "bg" }, { label: "Catalan (ca)", code: "ca" }, { label: "Corsican (co)", code: "co" }, { label: "Croatian (hr)", code: "hr" }, { label: "Czech (cs)", code: "cs" }, { label: "Danish (da)", code: "da" }, { label: "Dutch (nl)", code: "nl" }, { label: "Esperanto (eo)", code: "eo" }, { label: "Estonian (et)", code: "et" }, { label: "Finnish (fi)", code: "fi" }, { label: "French (fr)", code: "fr" }, { label: "Frisian (fy)", code: "fy" }, { label: "Galician (gl)", code: "gl" }, { label: "Georgian (ka)", code: "ka" }, { label: "German (de)", code: "de" }, { label: "Greek (el)", code: "el" }, { label: "Hungarian (hu)", code: "hu" }, { label: "Icelandic (is)", code: "is" }, { label: "Irish (ga)", code: "ga" }, { label: "Italian (it)", code: "it" }, { label: "Latin (la)", code: "la" }, { label: "Latvian (lv)", code: "lv" }, { label: "Lithuanian (lt)", code: "lt" }, { label: "Luxembourgish (lb)", code: "lb" }, { label: "Macedonian (mk)", code: "mk" }, { label: "Maltese (mt)", code: "mt" }, { label: "Norwegian (no)", code: "no" }, { label: "Portuguese (pt)", code: "pt" }, { label: "Romanian (ro)", code: "ro" }, { label: "Russian (ru)", code: "ru" }, { label: "Scots Gaelic (gd)", code: "gd" }, { label: "Serbian (sr)", code: "sr" }, { label: "Slovak (sk)", code: "sk" }, { label: "Slovenian (sl)", code: "sl" }, { label: "Spanish (es)", code: "es" }, { label: "Swedish (sv)", code: "sv" }, { label: "Turkish (tr)", code: "tr" }, { label: "Ukrainian (uk)", code: "uk" }, { label: "Welsh (cy)", code: "cy" }, { label: "Yiddish (yi)", code: "yi" }
        ]
    }
    return options.Clone()
}

GetTextTranslateLangLabels() {
    labels := []
    for _, option in GetTextTranslateLangOptions()
        labels.Push(option.label)
    return labels
}

IsTextTranslateLangSupported(lang) {
    for _, option in GetTextTranslateLangOptions() {
        if (option.code == lang)
            return true
    }
    return false
}

GetTextTranslateLangIndex(lang) {
    for index, option in GetTextTranslateLangOptions() {
        if (option.code == lang)
            return index
    }
    return 1
}

GetTextTranslateLangCodeByLabel(label) {
    for _, option in GetTextTranslateLangOptions() {
        if (option.label == label)
            return option.code
    }
    return "ko"
}

SetTextTranslateLang(lang) {
    global TEXT_TRANSLATE_LANG, REG_PATH
    if !IsTextTranslateLangSupported(lang)
        lang := "ko"
    TEXT_TRANSLATE_LANG := lang
    return SafeRegWriteString(lang, REG_PATH, "TranslateLang")
}

SetTextTranslateFontSize(fontSize) {
    global TEXT_TRANSLATE_FONT_SIZE, REG_PATH
    fontSize := NormalizeTextTranslateFontSize(fontSize)
    TEXT_TRANSLATE_FONT_SIZE := fontSize
    return SafeRegWriteString(fontSize, REG_PATH, "TextTranslateFontSize")
}

GetTextTranslateHotkeyOptions() {
    return [{ label: "Win + CapsLock", hotkey: "#CapsLock" }, { label: "Win + Shift + CapsLock", hotkey: "#+CapsLock" }, { label: "Win + Alt + CapsLock", hotkey: "#!CapsLock" }, { label: "Ctrl + Alt + CapsLock", hotkey: "^!CapsLock" }, { label: "Ctrl + Shift + CapsLock", hotkey: "^+CapsLock" }
    ]
}

GetTextTranslateHotkeyLabels() {
    labels := []
    for _, option in GetTextTranslateHotkeyOptions()
        labels.Push(option.label)
    return labels
}

IsTextTranslateHotkeySupported(hotkey) {
    for _, option in GetTextTranslateHotkeyOptions() {
        if (option.hotkey == hotkey)
            return true
    }
    return false
}

GetTextTranslateHotkeyIndex(hotkey) {
    for index, option in GetTextTranslateHotkeyOptions() {
        if (option.hotkey == hotkey)
            return index
    }
    return 1
}

GetTextTranslateHotkeyLabel(hotkey) {
    for _, option in GetTextTranslateHotkeyOptions() {
        if (option.hotkey == hotkey)
            return option.label
    }
    return "Win + CapsLock"
}

GetTextTranslateHotkeyByLabel(label) {
    for _, option in GetTextTranslateHotkeyOptions() {
        if (option.label == label)
            return option.hotkey
    }
    return "#CapsLock"
}

RunTextTranslateHotkey(*) {
    TranslateSelectedText(false)
}

ApplyTextTranslateHotkey() {
    global TEXT_TRANSLATE_HOTKEY
    try {
        Hotkey(TEXT_TRANSLATE_HOTKEY, RunTextTranslateHotkey, "On")
        return true
    } catch as e {
        ToolTip("⚠️ 번역 단축키 설정 실패: " e.Message)
        SetTimer(() => ToolTip(), -3000)
        return false
    }
}

SetTextTranslateHotkey(hotkey) {
    global TEXT_TRANSLATE_HOTKEY, REG_PATH
    if !IsTextTranslateHotkeySupported(hotkey)
        hotkey := "#CapsLock"

    oldHotkey := TEXT_TRANSLATE_HOTKEY
    if (oldHotkey != hotkey) {
        try Hotkey(oldHotkey, "Off")
        TEXT_TRANSLATE_HOTKEY := hotkey
        if !ApplyTextTranslateHotkey() {
            TEXT_TRANSLATE_HOTKEY := oldHotkey
            try Hotkey(oldHotkey, RunTextTranslateHotkey, "On")
            return false
        }
    }

    saved := SafeRegWriteString(hotkey, REG_PATH, "TranslateHotkey")
    UpdateTrayTextTranslateMenuLabel()
    return saved
}

UpdateTrayTextTranslateMenuLabel() {
    global Tray, TRAY_TEXT_TRANSLATE_ITEM, TEXT_TRANSLATE_HOTKEY
    newItem := "🌐 Translate Selected Text (" GetTextTranslateHotkeyLabel(TEXT_TRANSLATE_HOTKEY) ")"
    try Tray.Rename(TRAY_TEXT_TRANSLATE_ITEM, newItem)
    TRAY_TEXT_TRANSLATE_ITEM := newItem
}

AttachGithubUpdateControls(statusCtrl, detailCtrl, updateBtn, dashboardHwnd) {
    global UPDATE_CHECK_STATE
    UPDATE_CHECK_STATE.statusCtrl := statusCtrl
    UPDATE_CHECK_STATE.detailCtrl := detailCtrl
    UPDATE_CHECK_STATE.updateBtn := updateBtn
    UPDATE_CHECK_STATE.dashboardHwnd := dashboardHwnd
    RenderGithubUpdateState()
}

DetachGithubUpdateControls(dashboardHwnd) {
    global UPDATE_CHECK_STATE
    if (UPDATE_CHECK_STATE.dashboardHwnd != dashboardHwnd)
        return
    UPDATE_CHECK_STATE.statusCtrl := 0
    UPDATE_CHECK_STATE.detailCtrl := 0
    UPDATE_CHECK_STATE.updateBtn := 0
    UPDATE_CHECK_STATE.dashboardHwnd := 0
}

StartGithubUpdateCheck(force := false) {
    global UPDATE_CHECK_STATE, GITHUB_LATEST_RELEASE_API, GITHUB_RELEASES_URL, APP_NAME, APP_VERSION

    if (UPDATE_CHECK_STATE.status == "checking" && !force) {
        RenderGithubUpdateState()
        return
    }
    if (!force && UPDATE_CHECK_STATE.status != "idle") {
        RenderGithubUpdateState()
        return
    }

    if (UPDATE_CHECK_STATE.status == "checking" && IsObject(UPDATE_CHECK_STATE.request))
        try UPDATE_CHECK_STATE.request.Abort()

    UPDATE_CHECK_STATE.status := "checking"
    UPDATE_CHECK_STATE.latestVersion := ""
    UPDATE_CHECK_STATE.releaseUrl := GITHUB_RELEASES_URL
    UPDATE_CHECK_STATE.downloadUrl := ""
    UPDATE_CHECK_STATE.assetName := ""
    UPDATE_CHECK_STATE.assetSize := 0
    UPDATE_CHECK_STATE.sha256 := ""
    UPDATE_CHECK_STATE.lastError := ""
    UPDATE_CHECK_STATE.startedTick := A_TickCount
    RenderGithubUpdateState()

    try {
        request := ComObject("WinHttp.WinHttpRequest.5.1")
        request.SetTimeouts(3000, 3000, 5000, 5000)
        request.Open("GET", GITHUB_LATEST_RELEASE_API, true)
        request.SetRequestHeader("User-Agent", APP_NAME "/" APP_VERSION)
        request.SetRequestHeader("Accept", "application/vnd.github+json")
        request.Send()
        UPDATE_CHECK_STATE.request := request
        SetTimer(PollGithubUpdateCheck, 200)
    } catch {
        FinishGithubUpdateCheckError()
    }
}

PollGithubUpdateCheck() {
    global UPDATE_CHECK_STATE, APP_VERSION
    if (UPDATE_CHECK_STATE.status != "checking") {
        SetTimer(PollGithubUpdateCheck, 0)
        return
    }

    if (A_TickCount - UPDATE_CHECK_STATE.startedTick > 15000) {
        if IsObject(UPDATE_CHECK_STATE.request)
            try UPDATE_CHECK_STATE.request.Abort()
        FinishGithubUpdateCheckError()
        return
    }

    try {
        if !UPDATE_CHECK_STATE.request.WaitForResponse(0)
            return
        if (UPDATE_CHECK_STATE.request.Status != 200) {
            FinishGithubUpdateCheckError()
            return
        }

        releaseInfo := ParseGithubLatestRelease(UPDATE_CHECK_STATE.request.ResponseText)
        if !IsObject(releaseInfo) {
            FinishGithubUpdateCheckError()
            return
        }

        UPDATE_CHECK_STATE.latestVersion := releaseInfo.version
        UPDATE_CHECK_STATE.releaseUrl := releaseInfo.releaseUrl
        UPDATE_CHECK_STATE.downloadUrl := releaseInfo.downloadUrl
        UPDATE_CHECK_STATE.assetName := releaseInfo.assetName
        UPDATE_CHECK_STATE.assetSize := releaseInfo.assetSize
        UPDATE_CHECK_STATE.sha256 := releaseInfo.sha256
        if (CompareSemanticVersions(releaseInfo.version, APP_VERSION) > 0)
            UPDATE_CHECK_STATE.status := releaseInfo.downloadUrl != "" ? "update" : "manual_update"
        else
            UPDATE_CHECK_STATE.status := "current"
        UPDATE_CHECK_STATE.request := 0
        SetTimer(PollGithubUpdateCheck, 0)
        RenderGithubUpdateState()
    } catch {
        ; Async requests can report a temporary timeout until the response is ready.
    }
}

FinishGithubUpdateCheckError(message := "") {
    global UPDATE_CHECK_STATE
    SetTimer(PollGithubUpdateCheck, 0)
    UPDATE_CHECK_STATE.status := "error"
    UPDATE_CHECK_STATE.lastError := ShortErrorMessage(message)
    UPDATE_CHECK_STATE.request := 0
    RenderGithubUpdateState()
}

RenderGithubUpdateState() {
    global UPDATE_CHECK_STATE, APP_VERSION
    if (!IsObject(UPDATE_CHECK_STATE.statusCtrl) || !IsObject(UPDATE_CHECK_STATE.detailCtrl)
        || !IsObject(UPDATE_CHECK_STATE.updateBtn))
        return

    try {
        if (UPDATE_CHECK_STATE.status == "checking") {
            UPDATE_CHECK_STATE.statusCtrl.Value := "Checking for updates..."
            UPDATE_CHECK_STATE.detailCtrl.Value := "Current version: v" APP_VERSION
        } else if (UPDATE_CHECK_STATE.status == "update") {
            UPDATE_CHECK_STATE.statusCtrl.Value := "Update available: v" UPDATE_CHECK_STATE.latestVersion
            UPDATE_CHECK_STATE.detailCtrl.Value := "Download is verified with GitHub's SHA-256 digest."
        } else if (UPDATE_CHECK_STATE.status == "manual_update") {
            UPDATE_CHECK_STATE.statusCtrl.Value := "Update available: v" UPDATE_CHECK_STATE.latestVersion
            UPDATE_CHECK_STATE.detailCtrl.Value := "No verified EXE asset was found. Open the release page."
        } else if (UPDATE_CHECK_STATE.status == "downloading") {
            UPDATE_CHECK_STATE.statusCtrl.Value := "Downloading v" UPDATE_CHECK_STATE.latestVersion "..."
            UPDATE_CHECK_STATE.detailCtrl.Value := "The app will restart after verification."
        } else if (UPDATE_CHECK_STATE.status == "current") {
            UPDATE_CHECK_STATE.statusCtrl.Value := "You're up to date"
            UPDATE_CHECK_STATE.detailCtrl.Value := "Current v" APP_VERSION "  •  Latest v" UPDATE_CHECK_STATE.latestVersion
        } else if (UPDATE_CHECK_STATE.status == "error") {
            UPDATE_CHECK_STATE.statusCtrl.Value := "Update check unavailable"
            UPDATE_CHECK_STATE.detailCtrl.Value := UPDATE_CHECK_STATE.lastError != "" ? UPDATE_CHECK_STATE.lastError : "Check your network connection and try again."
        } else {
            UPDATE_CHECK_STATE.statusCtrl.Value := "Update status: Not checked"
            UPDATE_CHECK_STATE.detailCtrl.Value := "Current version: v" APP_VERSION
        }
        UPDATE_CHECK_STATE.updateBtn.Enabled := (UPDATE_CHECK_STATE.status == "update" || UPDATE_CHECK_STATE.status == "manual_update")
    }
}

DownloadAndInstallGithubUpdate(*) {
    global UPDATE_CHECK_STATE, APP_NAME, APP_TEMP_DIR
    if (UPDATE_CHECK_STATE.status == "manual_update") {
        if IsTrustedGithubReleaseUrl(UPDATE_CHECK_STATE.releaseUrl)
            try Run(UPDATE_CHECK_STATE.releaseUrl)
        return
    }
    if (UPDATE_CHECK_STATE.status != "update")
        return

    if !A_IsCompiled {
        MsgBox("Automatic replacement is available in the compiled app.`r`nThe GitHub release page will open instead.",
            APP_NAME, "Iconi")
        if IsTrustedGithubReleaseUrl(UPDATE_CHECK_STATE.releaseUrl)
            try Run(UPDATE_CHECK_STATE.releaseUrl)
        return
    }

    answer := MsgBox("The update will close all floating capture windows.`r`nSave or copy anything you still need before continuing.`r`n`r`nDownload, verify, and install v"
        UPDATE_CHECK_STATE.latestVersion " now?", APP_NAME " Update", "YesNo Icon! Default2")
    if (answer != "Yes")
        return

    UPDATE_CHECK_STATE.status := "downloading"
    UPDATE_CHECK_STATE.lastError := ""
    RenderGithubUpdateState()
    Sleep(50)

    updateDir := APP_TEMP_DIR "\updates"
    stagedPath := updateDir "\" UPDATE_CHECK_STATE.assetName
    try {
        if !DirExist(updateDir)
            DirCreate(updateDir)
        if FileExist(stagedPath)
            FileDelete(stagedPath)
        Download(UPDATE_CHECK_STATE.downloadUrl, stagedPath)
        validationError := ValidateDownloadedUpdate(stagedPath, UPDATE_CHECK_STATE)
        if (validationError != "")
            throw Error(validationError)
        if !LaunchUpdateHelper(stagedPath, A_ScriptFullPath, UPDATE_CHECK_STATE.sha256)
            throw Error("Could not start the update helper.")
        ExitApp
    } catch as e {
        try {
            if FileExist(stagedPath)
                FileDelete(stagedPath)
        }
        UPDATE_CHECK_STATE.status := "error"
        UPDATE_CHECK_STATE.lastError := "Update failed: " ShortErrorMessage(e.Message, 90)
        RenderGithubUpdateState()
        MsgBox(UPDATE_CHECK_STATE.lastError "`r`n`r`nYou can still download the release manually from GitHub.",
            APP_NAME " Update", "Iconx")
    }
}

ParseGithubLatestRelease(jsonText) {
    global GITHUB_RELEASES_URL
    tagName := ""
    releaseName := ""
    releaseUrl := GITHUB_RELEASES_URL
    tagPattern := '"tag_name"\s*:\s*"([^"]+)"'
    namePattern := '"name"\s*:\s*"([^"]+)"'
    urlPattern := '"html_url"\s*:\s*"([^"]+)"'

    if RegExMatch(jsonText, tagPattern, &tagMatch)
        tagName := DecodeGithubJsonString(tagMatch[1])
    if RegExMatch(jsonText, namePattern, &nameMatch)
        releaseName := DecodeGithubJsonString(nameMatch[1])
    if RegExMatch(jsonText, urlPattern, &urlMatch) {
        candidateUrl := DecodeGithubJsonString(urlMatch[1])
        if IsTrustedGithubReleaseUrl(candidateUrl)
            releaseUrl := candidateUrl
    }

    version := ExtractSemanticVersion(tagName)
    if (version == "")
        version := ExtractSemanticVersion(releaseName)
    if (version == "" && RegExMatch(jsonText, "i)ClipOCR-Pro_v(\d+\.\d+\.\d+)\.(?:exe|zip)", &assetMatch))
        version := assetMatch[1]
    if (version == "")
        return 0
    asset := FindGithubReleaseAsset(jsonText, version)
    if IsObject(asset) {
        return { version: version, releaseUrl: releaseUrl, downloadUrl: asset.downloadUrl,
            assetName: asset.name, assetSize: asset.size, sha256: asset.sha256 }
    }
    return { version: version, releaseUrl: releaseUrl, downloadUrl: "", assetName: "", assetSize: 0, sha256: "" }
}

FindGithubReleaseAsset(jsonText, version) {
    expectedName := "ClipOCR-Pro.v" version ".exe"
    escapedVersion := StrReplace(version, ".", "\.")
    assetPattern := '"name"\s*:\s*"ClipOCR-Pro\.v' escapedVersion '\.exe"'
    assetPos := RegExMatch(jsonText, assetPattern)
    if !assetPos
        return 0

    ; All remaining release-asset fields follow name in GitHub's asset object.
    assetJson := SubStr(jsonText, assetPos, 8000)
    if !RegExMatch(assetJson, '"size"\s*:\s*(\d+)', &sizeMatch)
        return 0
    if !RegExMatch(assetJson, '"digest"\s*:\s*"sha256:([0-9a-fA-F]{64})"', &digestMatch)
        return 0
    if !RegExMatch(assetJson, '"browser_download_url"\s*:\s*"([^"]+)"', &downloadMatch)
        return 0

    downloadUrl := DecodeGithubJsonString(downloadMatch[1])
    assetSize := Integer(sizeMatch[1])
    if (!IsTrustedGithubAssetUrl(downloadUrl, version) || assetSize < 100000 || assetSize > 100 * 1024 * 1024)
        return 0
    return { name: expectedName, size: assetSize, sha256: StrLower(digestMatch[1]), downloadUrl: downloadUrl }
}

DecodeGithubJsonString(value) {
    value := StrReplace(value, "\/", "/")
    return StrReplace(value, "\u0026", "&")
}

ExtractSemanticVersion(value) {
    if RegExMatch(value, "i)(?:^|[^\d])v?(\d+)\.(\d+)\.(\d+)(?:[^\d]|$)", &match)
        return Integer(match[1]) "." Integer(match[2]) "." Integer(match[3])
    return ""
}

CompareSemanticVersions(leftVersion, rightVersion) {
    leftParts := StrSplit(leftVersion, ".")
    rightParts := StrSplit(rightVersion, ".")
    loop 3 {
        leftValue := Integer(leftParts[A_Index])
        rightValue := Integer(rightParts[A_Index])
        if (leftValue > rightValue)
            return 1
        if (leftValue < rightValue)
            return -1
    }
    return 0
}

IsTrustedGithubReleaseUrl(url) {
    return RegExMatch(url, "i)^https://github\.com/KwangBeomPark/(?:01_)?ClipOCR-Pro/releases(?:/|$)") > 0
}

IsTrustedGithubAssetUrl(url, version) {
    expectedUrl := "https://github.com/KwangBeomPark/01_ClipOCR-Pro/releases/download/v" version "/ClipOCR-Pro.v" version ".exe"
    return StrLower(url) == StrLower(expectedUrl)
}

ValidateDownloadedUpdate(filePath, releaseInfo) {
    if !FileExist(filePath)
        return "The downloaded file is missing."
    try {
        if (FileGetSize(filePath) != releaseInfo.assetSize)
            return "The downloaded file size does not match GitHub."
    } catch {
        return "The downloaded file size could not be verified."
    }

    file := 0
    try {
        file := FileOpen(filePath, "r")
        header := Buffer(2, 0)
        if (!IsObject(file) || file.RawRead(header, 2) != 2 || NumGet(header, 0, "UShort") != 0x5A4D)
            return "The downloaded file is not a valid Windows executable."
    } catch {
        return "The downloaded executable could not be inspected."
    } finally {
        if IsObject(file)
            try file.Close()
    }

    try downloadedVersion := ExtractSemanticVersion(FileGetVersion(filePath))
    catch
        return "The downloaded executable has no readable version."
    if (downloadedVersion != releaseInfo.latestVersion)
        return "The downloaded executable version does not match the release."

    actualHash := GetFileSha256(filePath)
    if (actualHash == "" || StrLower(actualHash) != StrLower(releaseInfo.sha256))
        return "SHA-256 verification failed. The file was not installed."
    return ""
}

GetFileSha256(filePath) {
    hProvider := 0
    hHash := 0
    file := 0
    if !DllCall("advapi32\CryptAcquireContextW", "Ptr*", &hProvider, "Ptr", 0, "Ptr", 0, "UInt", 24,
        "UInt", 0xF0000000)
        return ""

    try {
        if !DllCall("advapi32\CryptCreateHash", "Ptr", hProvider, "UInt", 0x800C, "Ptr", 0, "UInt", 0, "Ptr*", &hHash)
            return ""
        file := FileOpen(filePath, "r")
        if !IsObject(file)
            return ""
        chunk := Buffer(1024 * 1024, 0)
        Loop {
            bytesRead := file.RawRead(chunk, chunk.Size)
            if !bytesRead
                break
            if !DllCall("advapi32\CryptHashData", "Ptr", hHash, "Ptr", chunk.Ptr, "UInt", bytesRead, "UInt", 0)
                return ""
        }

        hashLength := 32
        hashBytes := Buffer(hashLength, 0)
        if !DllCall("advapi32\CryptGetHashParam", "Ptr", hHash, "UInt", 2, "Ptr", hashBytes.Ptr, "UInt*", &hashLength,
            "UInt", 0)
            return ""
        result := ""
        Loop hashLength
            result .= Format("{:02x}", NumGet(hashBytes, A_Index - 1, "UChar"))
        return result
    } catch {
        return ""
    } finally {
        if IsObject(file)
            try file.Close()
        if hHash
            DllCall("advapi32\CryptDestroyHash", "Ptr", hHash)
        if hProvider
            DllCall("advapi32\CryptReleaseContext", "Ptr", hProvider, "UInt", 0)
    }
}

CanWriteToFolder(folder) {
    probePath := folder "\.clipocr_update_probe_" DllCall("GetCurrentProcessId") "_" A_TickCount ".tmp"
    try {
        FileAppend("probe", probePath, "UTF-8")
        FileDelete(probePath)
        return true
    } catch {
        try {
            if FileExist(probePath)
                FileDelete(probePath)
        }
        return false
    }
}

LaunchUpdateHelper(sourcePath, targetPath, expectedHash) {
    global APP_TEMP_DIR
    SplitPath(targetPath, , &targetDir)
    helperPath := APP_TEMP_DIR "\update_clipocr.ps1"
    logPath := APP_TEMP_DIR "\update.log"
    helperLines := [
        "param(",
        "    [Parameter(Mandatory=$true)][int]$ParentProcessId,",
        "    [Parameter(Mandatory=$true)][string]$Source,",
        "    [Parameter(Mandatory=$true)][string]$Target,",
        "    [Parameter(Mandatory=$true)][string]$ExpectedHash,",
        "    [Parameter(Mandatory=$true)][string]$LogPath",
        ")",
        "$ErrorActionPreference = 'Stop'",
        "$replacement = $null",
        "$backup = $Target + '.previous'",
        "try {",
        "    Wait-Process -Id $ParentProcessId -Timeout 30 -ErrorAction SilentlyContinue",
        "    if (Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue) {",
        "        throw 'The running app did not close in time.'",
        "    }",
        "    $actualHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash.ToLowerInvariant()",
        "    if ($actualHash -ne $ExpectedHash.ToLowerInvariant()) {",
        "        throw 'The staged update hash changed before installation.'",
        "    }",
        "    $targetDirectory = [IO.Path]::GetDirectoryName($Target)",
        "    $replacement = Join-Path $targetDirectory ('.clipocr_' + [guid]::NewGuid().ToString('N') + '.exe')",
        "    Copy-Item -LiteralPath $Source -Destination $replacement -Force",
        "    if (Test-Path -LiteralPath $Target) {",
        "        Copy-Item -LiteralPath $Target -Destination $backup -Force",
        "    }",
        "    try {",
        "        Copy-Item -LiteralPath $replacement -Destination $Target -Force",
        "    } catch {",
        "        if (Test-Path -LiteralPath $backup) {",
        "            Copy-Item -LiteralPath $backup -Destination $Target -Force",
        "        }",
        "        throw",
        "    }",
        "    Start-Process -FilePath $Target",
        "    Remove-Item -LiteralPath $Source -Force -ErrorAction SilentlyContinue",
        "    Set-Content -LiteralPath $LogPath -Value ('Updated successfully at ' + (Get-Date).ToString('s')) -Encoding UTF8",
        "} catch {",
        "    Add-Content -LiteralPath $LogPath -Value ((Get-Date).ToString('s') + ' Update failed: ' + $_.Exception.Message) -Encoding UTF8",
        "    Add-Type -AssemblyName PresentationFramework",
        "    [System.Windows.MessageBox]::Show('ClipOCR-Pro could not finish the update. The previous app file was preserved. See: ' + $LogPath, 'ClipOCR-Pro Update') | Out-Null",
        "    exit 1",
        "} finally {",
        "    if ($replacement -and (Test-Path -LiteralPath $replacement)) {",
        "        Remove-Item -LiteralPath $replacement -Force -ErrorAction SilentlyContinue",
        "    }",
        "}",
        "Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue"
    ]
    helperScript := ""
    for index, line in helperLines
        helperScript .= (index == 1 ? "" : "`r`n") line

    try {
        if !DirExist(APP_TEMP_DIR)
            DirCreate(APP_TEMP_DIR)
        if FileExist(helperPath)
            FileDelete(helperPath)
        FileAppend(helperScript, helperPath, "UTF-8")
        command := 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' helperPath '" -ParentProcessId '
            DllCall("GetCurrentProcessId") ' -Source "' sourcePath '" -Target "' targetPath '" -ExpectedHash "'
            expectedHash '" -LogPath "' logPath '"'
        if CanWriteToFolder(targetDir)
            Run(command, , "Hide")
        else
            Run("*RunAs " command)
        return true
    } catch {
        return false
    }
}

RunInternalHealthCheck() {
    errors := []
    healthDir := A_Temp "\ClipOCR-Pro"
    healthLog := healthDir "\health-check.log"
    Check(condition, message) {
        if !condition
            errors.Push(message)
    }

    Check(CompareSemanticVersions("1.10.0", "1.9.9") == 1, "semantic version comparison")
    Check(ExtractSemanticVersion("Release v2.3.4") == "2.3.4", "semantic version extraction")
    Check(NormalizeJpegQuality(80) == 80 && NormalizeJpegQuality(85) == 90, "JPG quality normalization")
    Check(NormalizeSaveImageFormat("JPG") == "jpg" && NormalizeSaveImageFormat("gif") == "png",
        "save image format normalization")
    presetFixture := GetImageSavePresetOptions()
    Check(presetFixture.Length == 4 && GetImageSavePresetIndex("png", 90) == 1
        && GetImageSavePresetIndex("jpg", 80) == 3, "image save presets")
    Check(NormalizeSuiteBoolean("True", false) && !NormalizeSuiteBoolean("0", true)
        && NormalizeSuiteBoolean("invalid", true), "Suite boolean normalization")
    Check(!ResolveBooleanSetting(true, "0", true, "True", true)
        && !ResolveBooleanSetting(false, "", true, "False", true)
        && ResolveBooleanSetting(false, "", false, "", true), "local and Suite boolean precedence")
    Check(IsCaptureHotkeySupported("Win+Drag") && IsCaptureHotkeySupported("#LButton")
        && !IsCaptureHotkeySupported("Alt+F4") && NormalizeCaptureHotkey("Alt+F4") == "#LButton",
        "capture hotkey validation")
    Check(IsTextTranslateHotkeySupported("#CapsLock") && IsTextTranslateHotkeySupported("^!CapsLock"),
        "translation hotkey validation")

    saveFixtureRoot := A_Temp "\clipocr_settings_" DllCall("GetCurrentProcessId")
    localSaveFixture := saveFixtureRoot "\local"
    suiteSaveFixture := saveFixtureRoot "\suite"
    try {
        DirCreate(localSaveFixture)
        DirCreate(suiteSaveFixture)
        saveResolution := ResolveSaveFolderSetting(true, localSaveFixture, true, suiteSaveFixture)
        Check(saveResolution.folder == localSaveFixture && saveResolution.source == "local",
            "explicit save folder precedence")
        saveResolution := ResolveSaveFolderSetting(false, "", true, suiteSaveFixture)
        Check(saveResolution.folder == suiteSaveFixture && saveResolution.source == "suite",
            "Suite save folder fallback")
        saveResolution := ResolveSaveFolderSetting(true, "", true, suiteSaveFixture)
        Check(saveResolution.folder == "" && saveResolution.source == "local",
            "explicit Desktop save preference")
        saveResolution := ResolveSaveFolderSetting(false, "", false, "")
        Check(saveResolution.folder == "" && saveResolution.source == "desktop",
            "Desktop save fallback")
    } catch as e {
        errors.Push("save folder fixtures: " ShortErrorMessage(e.Message))
    } finally {
        try {
            if DirExist(saveFixtureRoot)
                DirDelete(saveFixtureRoot, true)
        }
    }

    fixtureHash := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    fixtureJson := '{"tag_name":"v9.8.7","name":"Release v9.8.7","html_url":"https://github.com/KwangBeomPark/01_ClipOCR-Pro/releases/tag/v9.8.7","assets":[{"name":"ClipOCR-Pro.v9.8.7.exe","size":1569280,"digest":"sha256:'
    fixtureJson .= fixtureHash
    fixtureJson .= '","browser_download_url":"https://github.com/KwangBeomPark/01_ClipOCR-Pro/releases/download/v9.8.7/ClipOCR-Pro.v9.8.7.exe"}]}'
    releaseInfo := ParseGithubLatestRelease(fixtureJson)
    Check(IsObject(releaseInfo), "GitHub release parsing")
    if IsObject(releaseInfo) {
        Check(releaseInfo.version == "9.8.7", "GitHub release version")
        Check(releaseInfo.assetName == "ClipOCR-Pro.v9.8.7.exe", "GitHub asset selection")
        Check(releaseInfo.assetSize == 1569280, "GitHub asset size")
        Check(releaseInfo.sha256 == fixtureHash, "GitHub asset digest")
    }

    hashFixture := A_Temp "\clipocr_health_" DllCall("GetCurrentProcessId") ".txt"
    try {
        FileAppend("abc", hashFixture, "UTF-8-RAW")
        Check(GetFileSha256(hashFixture) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            "SHA-256 calculation")
    } catch as e {
        errors.Push("SHA-256 fixture: " ShortErrorMessage(e.Message))
    } finally {
        try {
            if FileExist(hashFixture)
                FileDelete(hashFixture)
        }
    }

    formatToken := 0
    formatBitmap := 0
    formatGraphics := 0
    pngFixture := A_Temp "\clipocr_health_" DllCall("GetCurrentProcessId") ".png"
    jpgFixture := A_Temp "\clipocr_health_" DllCall("GetCurrentProcessId") ".jpg"
    try {
        formatToken := Gdip_Startup()
        formatBitmap := Gdip_CreateBitmap(64, 64)
        formatGraphics := Gdip_GraphicsFromImage(formatBitmap)
        Gdip_GraphicsClear(formatGraphics, 0xFFF4F4F4)
        Check(SafeSaveBitmapToFile(formatBitmap, pngFixture, 100) && FileGetSize(pngFixture) > 0,
            "PNG lossless save")
        Check(SafeSaveBitmapToFile(formatBitmap, jpgFixture, 90) && FileGetSize(jpgFixture) > 0,
            "JPG quality save")
    } catch as e {
        errors.Push("image format fixture: " ShortErrorMessage(e.Message))
    } finally {
        if formatGraphics
            try Gdip_DeleteGraphics(formatGraphics)
        if formatBitmap
            try Gdip_DisposeImage(formatBitmap)
        if formatToken
            try Gdip_Shutdown(formatToken)
        try {
            if FileExist(pngFixture)
                FileDelete(pngFixture)
            if FileExist(jpgFixture)
                FileDelete(jpgFixture)
        }
    }

    try {
        if !DirExist(healthDir)
            DirCreate(healthDir)
        if FileExist(healthLog)
            FileDelete(healthLog)
        if (errors.Length == 0) {
            FileAppend("ClipOCR-Pro health check: PASS`r`n", healthLog, "UTF-8")
            return 0
        }
        for _, message in errors
            FileAppend("FAIL: " message "`r`n", healthLog, "UTF-8")
    }
    return 1
}

SwitchDashboardPanel(tabIndex, TabGenBtn, TabTrnBtn, TabAbtBtn, GenPanel, TrnPanel, AbtPanel) {
    TabGenBtn.Opt("cGray +BackgroundTrans")
    TabGenBtn.Redraw()
    TabTrnBtn.Opt("cGray +BackgroundTrans")
    TabTrnBtn.Redraw()
    TabAbtBtn.Opt("cGray +BackgroundTrans")
    TabAbtBtn.Redraw()

    for ctrl in GenPanel
        ctrl.Visible := false
    for ctrl in TrnPanel
        ctrl.Visible := false
    for ctrl in AbtPanel
        ctrl.Visible := false

    if (tabIndex == 1) {
        TabGenBtn.Opt("cWhite -BackgroundTrans Background3F3F46")
        TabGenBtn.Redraw()
        for ctrl in GenPanel
            ctrl.Visible := true
    } else if (tabIndex == 2) {
        TabTrnBtn.Opt("cWhite -BackgroundTrans Background3F3F46")
        TabTrnBtn.Redraw()
        for ctrl in TrnPanel
            ctrl.Visible := true
    } else if (tabIndex == 3) {
        TabAbtBtn.Opt("cWhite -BackgroundTrans Background3F3F46")
        TabAbtBtn.Redraw()
        for ctrl in AbtPanel
            ctrl.Visible := true
    }
}

SaveDashboardSettings(StartupChk, WidthCombo, PresetCombo, OutlineChk, AutoClipboardChk, FontSizeEdit, HotkeyCombo,
    LangCombo, LV_ImageLangs, SaveFolderEdit, initialSaveFolder) {
    global IMAGE_TRANSLATE_LANGS, REG_PATH
    settingsSaved := true

    if (StrLower(Trim(SaveFolderEdit.Value)) != StrLower(Trim(initialSaveFolder))) {
        if !SetSaveFolder(SaveFolderEdit.Value)
            settingsSaved := false
    }

    if !SetAutoClipboard(AutoClipboardChk.Value)
        settingsSaved := false

    if StartupChk.Value {
        if !EnableStartup()
            settingsSaved := false
    } else {
        if !DisableStartup()
            settingsSaved := false
    }

    if !SetClipWidth(GetClipWidthFromLabel(WidthCombo.Text))
        settingsSaved := false
    selectedPreset := GetImageSavePresetFromLabel(PresetCombo.Text)
    if !SetSaveImageFormat(selectedPreset.format)
        settingsSaved := false
    if !SetJpegQuality(selectedPreset.quality)
        settingsSaved := false
    UpdateImageSavePresetMenu()
    if !SetCopyOutline(OutlineChk.Value)
        settingsSaved := false
    if !SetTextTranslateFontSize(FontSizeEdit.Value)
        settingsSaved := false
    if !SetTextTranslateHotkey(GetTextTranslateHotkeyByLabel(HotkeyCombo.Text))
        settingsSaved := false
    if !SetTextTranslateLang(GetTextTranslateLangCodeByLabel(LangCombo.Text))
        settingsSaved := false

    selectedCodes := []
    row := 0
    Loop {
        row := LV_ImageLangs.GetNext(row, "Checked")
        if not row
            break
        label := LV_ImageLangs.GetText(row)
        selectedCodes.Push(GetTextTranslateLangCodeByLabel(label))
    }

    newImageLangs := ""
    for i, code in selectedCodes
        newImageLangs .= (i == 1 ? "" : ",") code
    IMAGE_TRANSLATE_LANGS := NormalizeLangCodeList(newImageLangs)
    if !SafeRegWriteString(IMAGE_TRANSLATE_LANGS, REG_PATH, "ImageTranslateLangs")
        settingsSaved := false
    UpdateImageTranslateMenu()

    return settingsSaved
}

ShowDashboardDialog() {
    global APP_NAME, APP_VERSION, DashboardHwnd, CLIP_WIDTH, COPY_OUTLINE_ENABLED, AUTO_CLIPBOARD, SAVE_IMAGE_FORMAT, JPG_QUALITY, TEXT_TRANSLATE_LANG, TEXT_TRANSLATE_HOTKEY, TEXT_TRANSLATE_FONT_SIZE, IMAGE_TRANSLATE_LANGS, bmcBtnPath, ENABLE_BMC_AUTO_DOWNLOAD

    if (DashboardHwnd && WinExist("ahk_id " DashboardHwnd)) {
        WinActivate("ahk_id " DashboardHwnd)
        return
    }

    DashGui := Gui("-Caption +AlwaysOnTop +ToolWindow +Border -DPIScale", APP_NAME " Settings")
    DashGui.BackColor := "1E1E24"
    DashGui.SetFont("s9", "Segoe UI")

    ; --- Title bar ---
    DashGui.Add("Text", "x0 y0 w780 h45 Background141416", "")
    TitleTxt := DashGui.Add("Text", "x15 y12 w350 h25 +BackgroundTrans cWhite", "⚙️ " APP_NAME " Settings")
    TitleTxt.SetFont("s11 Bold", "Segoe UI")
    CloseBtn := DashGui.Add("Text", "x745 y10 w25 h25 Center +0x200 +BackgroundTrans cGray", "×")
    CloseBtn.SetFont("s16 Bold")

    DestroyDash(*) {
        global DashboardHwnd
        try DetachGithubUpdateControls(DashGui.Hwnd)
        DashboardHwnd := 0
        DashGui.Destroy()
    }
    CloseBtn.OnEvent("Click", DestroyDash)

    ; --- Left sidebar ---
    DashGui.Add("Text", "x0 y45 w160 h525 Background27272A", "") ; Sidebar background

    ; Tab buttons
    TabGenBtn := DashGui.Add("Text", "x10 y60 w140 h40 +0x200 Center +BackgroundTrans cWhite Background3F3F46", "⚙️ General")
    TabGenBtn.SetFont("s10 Bold", "Segoe UI")

    TabTrnBtn := DashGui.Add("Text", "x10 y110 w140 h40 +0x200 Center +BackgroundTrans cGray", "🌐 Translation")
    TabTrnBtn.SetFont("s10 Bold", "Segoe UI")

    TabAbtBtn := DashGui.Add("Text", "x10 y160 w140 h40 +0x200 Center +BackgroundTrans cGray", "ℹ️ About")
    TabAbtBtn.SetFont("s10 Bold", "Segoe UI")

    ManualBtn := DashGui.Add("Text", "x10 y520 w140 h32 BackgroundFFDD00 c1E1E24 Center +0x200", "📖 Manual")
    ManualBtn.SetFont("s10 Bold", "Segoe UI")
    ManualBtn.OnEvent("Click", (*) => ShowManualDialog())

    ; --- Right content container ---

    ; 1. General Panel
    GenPanel := []
    lbl1 := DashGui.Add("Text", "x180 y60 w580 h22 +BackgroundTrans cFFFFFF", "Image Output Defaults")
    lbl1.SetFont("s10 Bold")
    GenPanel.Push(lbl1)

    GenPanel.Push(DashGui.Add("Text", "x180 y94 w180 h22 +BackgroundTrans cCCCCCC", "Clipboard Image Width"))
    WidthCombo := DashGui.Add("DropDownList", "x380 y90 w210 Choose" GetClipWidthIndex(CLIP_WIDTH), GetClipWidthLabels())
    GenPanel.Push(WidthCombo)

    GenPanel.Push(DashGui.Add("Text", "x180 y130 w190 h22 +BackgroundTrans cCCCCCC", "Image Quality && Size"))
    PresetCombo := DashGui.Add("DropDownList", "x380 y126 w380 Choose" GetImageSavePresetIndex(SAVE_IMAGE_FORMAT,
        JPG_QUALITY), GetImageSavePresetLabels())
    GenPanel.Push(PresetCombo)

    OutlineChk := DashGui.Add("CheckBox", "x180 y162 w285 h28 Background1E1E24 cCCCCCC" (COPY_OUTLINE_ENABLED ? " Checked" : ""),
        " Add 1px black outline")
    GenPanel.Push(OutlineChk)
    AutoClipboardChk := DashGui.Add("CheckBox", "x470 y162 w290 h28 Background1E1E24 cCCCCCC" (AUTO_CLIPBOARD ? " Checked" : ""),
        " Auto-copy new captures")
    GenPanel.Push(AutoClipboardChk)

    GenPanel.Push(DashGui.Add("Text", "x180 y200 w580 h1 Background3F3F46", ""))

    lblTextSize := DashGui.Add("Text", "x180 y215 w580 h22 +BackgroundTrans cFFFFFF", "Selected Text Translation")
    lblTextSize.SetFont("s10 Bold")
    GenPanel.Push(lblTextSize)

    GenPanel.Push(DashGui.Add("Text", "x180 y248 w180 h22 +BackgroundTrans cCCCCCC", "Translate Font Size"))
    FontSizeEdit := DashGui.Add("Edit", "x380 y244 w80 h24 Number", TEXT_TRANSLATE_FONT_SIZE)
    GenPanel.Push(FontSizeEdit)

    GenPanel.Push(DashGui.Add("Text", "x180 y282 w580 h1 Background3F3F46", ""))

    lbl2 := DashGui.Add("Text", "x180 y298 w580 h22 +BackgroundTrans cFFFFFF", "System Settings")
    lbl2.SetFont("s10 Bold")
    GenPanel.Push(lbl2)
    GenPanel.Push(DashGui.Add("Text", "x180 y328 w580 h58 Background2A2D3C", ""))
    isStartup := IsStartupEnabled()
    StartupChk := DashGui.Add("CheckBox", "x195 y336 w550 h24 Background2A2D3C cWhite" (isStartup ? " Checked" : ""), "  Run app when Windows starts")
    StartupChk.SetFont("s10 Bold", "Segoe UI")
    GenPanel.Push(StartupChk)
    GenPanel.Push(DashGui.Add("Text", "x198 y362 w540 h18 Background2A2D3C cA0A0A0", "Creates a Startup folder shortcut after Save and Close."))

    ; Save location (Ctrl+S destination)
    GenPanel.Push(DashGui.Add("Text", "x180 y398 w580 h1 Background3F3F46", ""))
    lblSave := DashGui.Add("Text", "x180 y410 w580 h22 +BackgroundTrans cFFFFFF", "Save to File (Ctrl+S)")
    lblSave.SetFont("s10 Bold")
    GenPanel.Push(lblSave)
    GenPanel.Push(DashGui.Add("Text", "x180 y442 w110 h22 +BackgroundTrans cCCCCCC", "Save Folder"))
    initialSaveFolder := GetSaveFolder()
    SaveFolderEdit := DashGui.Add("Edit", "x295 y438 w305 h24 ReadOnly", initialSaveFolder)
    GenPanel.Push(SaveFolderEdit)
    BrowseSaveBtn := DashGui.Add("Button", "x610 y437 w150 h26", "📁 Browse…")
    GenPanel.Push(BrowseSaveBtn)

    BrowseSaveFolder(*) {
        selected := DirSelect("*" GetSaveFolder(), 3, "Choose a folder to save captured images")
        if (selected != "")
            SaveFolderEdit.Value := selected
    }
    BrowseSaveBtn.OnEvent("Click", BrowseSaveFolder)

    ; 2. Translation Panel
    TrnPanel := []
    lbl3 := DashGui.Add("Text", "x180 y60 w580 h22 +BackgroundTrans cFFFFFF", "Text Translation Default")
    lbl3.SetFont("s10 Bold")
    TrnPanel.Push(lbl3)

    TrnPanel.Push(DashGui.Add("Text", "x180 y90 w180 h22 +BackgroundTrans cCCCCCC", "Translation Hotkey"))
    HotkeyCombo := DashGui.Add("DropDownList", "x360 y86 w390 Choose" GetTextTranslateHotkeyIndex(TEXT_TRANSLATE_HOTKEY), GetTextTranslateHotkeyLabels())
    TrnPanel.Push(HotkeyCombo)

    TrnPanel.Push(DashGui.Add("Text", "x180 y132 w180 h22 +BackgroundTrans cCCCCCC", "Target Language"))
    LangCombo := DashGui.Add("DropDownList", "x360 y128 w390 Choose" GetTextTranslateLangIndex(TEXT_TRANSLATE_LANG), GetTextTranslateLangLabels())
    TrnPanel.Push(LangCombo)

    TrnPanel.Push(DashGui.Add("Text", "x180 y180 w580 h1 Background3F3F46", ""))

    lbl4 := DashGui.Add("Text", "x180 y195 w580 h22 +BackgroundTrans cFFFFFF", "Image Translate Menu Languages (Multi-select)")
    lbl4.SetFont("s10 Bold")
    TrnPanel.Push(lbl4)
    LV_ImageLangs := DashGui.Add("ListView", "x180 y225 w470 h180 +Checked -Hdr Background2D2D35 cE0E0E0", ["Language"])
    LV_ImageLangs.SetFont("s9", "Segoe UI")
    TrnPanel.Push(LV_ImageLangs)

    UpBtn := DashGui.Add("Button", "x660 y225 w100 h30", "▲ Up")
    DownBtn := DashGui.Add("Button", "x660 y265 w100 h30", "▼ Down")
    TrnPanel.Push(UpBtn)
    TrnPanel.Push(DownBtn)

    langArray := StrSplit(IMAGE_TRANSLATE_LANGS, ",")
    options := GetTextTranslateLangOptions()

    ; 1. Add saved languages first, preserving checked order.
    for _, code in langArray {
        code := Trim(code)
        if (code == "")
            continue
        for idx, opt in options {
            if (opt.code == code) {
                LV_ImageLangs.Add("Check", opt.label)
                options.RemoveAt(idx)
                break
            }
        }
    }

    ; 2. Append remaining languages unchecked.
    for _, opt in options {
        LV_ImageLangs.Add("", opt.label)
    }

    ; --- List item up/down movement helpers ---
    IsRowChecked(r) {
        curr := 0
        Loop {
            curr := LV_ImageLangs.GetNext(curr, "Checked")
            if (!curr)
                return false
            if (curr == r)
                return true
        }
        return false
    }

    MoveItemUp(*) {
        row := LV_ImageLangs.GetNext(0, "Focused")
        if (row > 1) {
            txt1 := LV_ImageLangs.GetText(row)
            chk1 := IsRowChecked(row)

            txt2 := LV_ImageLangs.GetText(row - 1)
            chk2 := IsRowChecked(row - 1)

            LV_ImageLangs.Modify(row, (chk2 ? "Check" : "-Check") " -Select", txt2)
            LV_ImageLangs.Modify(row - 1, (chk1 ? "Check" : "-Check") " Select Focus", txt1)
        }
    }

    MoveItemDown(*) {
        row := LV_ImageLangs.GetNext(0, "Focused")
        if (row > 0 && row < LV_ImageLangs.GetCount()) {
            txt1 := LV_ImageLangs.GetText(row)
            chk1 := IsRowChecked(row)

            txt2 := LV_ImageLangs.GetText(row + 1)
            chk2 := IsRowChecked(row + 1)

            LV_ImageLangs.Modify(row, (chk2 ? "Check" : "-Check") " -Select", txt2)
            LV_ImageLangs.Modify(row + 1, (chk1 ? "Check" : "-Check") " Select Focus", txt1)
        }
    }

    UpBtn.OnEvent("Click", MoveItemUp)
    DownBtn.OnEvent("Click", MoveItemDown)

    ; 3. About Panel
    AbtPanel := []
    lbl5 := DashGui.Add("Text", "x180 y60 w430 h25 +BackgroundTrans cWhite", APP_NAME)
    lbl5.SetFont("s10 Bold")
    AbtPanel.Push(lbl5)

    AbtPanel.Push(DashGui.Add("Text", "x180 y90 w580 h20 +BackgroundTrans cGray", "Version " APP_VERSION " • Screen Capture, Annotation & Translation Tool"))

    AbtPanel.Push(DashGui.Add("Text", "x180 y120 w580 h78 Background27272A", ""))
    UpdateStatusText := DashGui.Add("Text", "x195 y133 w300 h22 +BackgroundTrans cFFFFFF", "Update status: Not checked")
    UpdateStatusText.SetFont("s10 Bold", "Segoe UI")
    UpdateDetailText := DashGui.Add("Text", "x195 y160 w300 h20 +BackgroundTrans cA0A0A0", "Current version: v" APP_VERSION)
    CheckUpdateBtn := DashGui.Add("Button", "x505 y137 w105 h32", "Check Again")
    ViewUpdateBtn := DashGui.Add("Button", "x610 y137 w135 h32 Disabled", "Download && Update")
    AbtPanel.Push(UpdateStatusText)
    AbtPanel.Push(UpdateDetailText)
    AbtPanel.Push(CheckUpdateBtn)
    AbtPanel.Push(ViewUpdateBtn)

    AbtPanel.Push(DashGui.Add("Text", "x180 y210 w580 h1 Background3F3F46", ""))

    AbtPanel.Push(DashGui.Add("Text", "x180 y222 w580 h82 Background27272A", ""))

    lbl6 := DashGui.Add("Text", "x195 y230 w550 h20 +BackgroundTrans cWhite", "👤 Developer Info")
    lbl6.SetFont("s10 Bold")
    AbtPanel.Push(lbl6)
    AbtPanel.Push(DashGui.Add("Text", "x195 y255 w430 h20 +BackgroundTrans cCCCCCC", "Kwang Beom Park (Bob)"))
    AbtPanel.Push(DashGui.Add("Text", "x195 y278 w430 h20 +BackgroundTrans cA0A0A0", "A finance professional passionate about office automation and daily productivity."))

    githubLoaded := false
    if FileExist(githubIconPath) {
        try {
            GithubPic := DashGui.Add("Picture", "x680 y238 w48 h48 +BackgroundTrans", githubIconPath)
            GithubPic.OnEvent("Click", (*) => Run("https://github.com/KwangBeomPark"))
            AbtPanel.Push(GithubPic)
            githubLoaded := true
        }
    }

    if !githubLoaded {
        GithubLink := DashGui.Add("Link", "x665 y255 w80 h30 Center Background27272A", '<a href="https://github.com/KwangBeomPark" id="github">GitHub</a>')
        AbtPanel.Push(GithubLink)
    }

    AbtPanel.Push(DashGui.Add("Text", "x180 y316 w580 h104 Background2D2D35", ""))
    AbtPanel.Push(DashGui.Add("Text", "x195 y326 w550 h20 +BackgroundTrans cFFDD00", "☕ Support This Project"))
    AbtPanel.Push(DashGui.Add("Text", "x195 y350 w550 h28 +BackgroundTrans cE0E0E0", "If this tool helps reduce repetitive work, your support will encourage me to continue building more tools."))

    if (ENABLE_BMC_AUTO_DOWNLOAD && FileExist(bmcBtnPath)) {
        BmcPic := DashGui.Add("Picture", "x382 y378 w176 h36 +BackgroundTrans", bmcBtnPath)
        BmcPic.OnEvent("Click", (*) => Run("https://www.buymeacoffee.com/KBPark_Bob"))
        AbtPanel.Push(BmcPic)
    } else {
        BmcLink := DashGui.Add("Link", "x195 y382 w550 h28 Center Background2D2D35 cYellow", '<a href="https://www.buymeacoffee.com/KBPark_Bob">☕ Click here to Support</a>')
        AbtPanel.Push(BmcLink)
    }

    AttachGithubUpdateControls(UpdateStatusText, UpdateDetailText, ViewUpdateBtn, DashGui.Hwnd)
    CheckUpdateBtn.OnEvent("Click", (*) => StartGithubUpdateCheck(true))
    ViewUpdateBtn.OnEvent("Click", DownloadAndInstallGithubUpdate)

    ShowAboutPanel(*) {
        SwitchDashboardPanel(3, TabGenBtn, TabTrnBtn, TabAbtBtn, GenPanel, TrnPanel, AbtPanel)
        StartGithubUpdateCheck()
    }

    TabGenBtn.OnEvent("Click", (*) => SwitchDashboardPanel(1, TabGenBtn, TabTrnBtn, TabAbtBtn, GenPanel, TrnPanel,
        AbtPanel))
    TabTrnBtn.OnEvent("Click", (*) => SwitchDashboardPanel(2, TabGenBtn, TabTrnBtn, TabAbtBtn, GenPanel, TrnPanel,
        AbtPanel))
    TabAbtBtn.OnEvent("Click", ShowAboutPanel)

    ; --- Shared bottom buttons ---
    DashGui.Add("Text", "x160 y510 w620 h1 Background3F3F46", "") ; Top border divider
    SaveBtn := DashGui.Add("Button", "x550 y525 w100 h32", "Save && Close")
    CancelBtn := DashGui.Add("Button", "x660 y525 w100 h32", "Cancel")

    SaveAllSettings(*) {
        settingsSaved := SaveDashboardSettings(StartupChk, WidthCombo, PresetCombo, OutlineChk, AutoClipboardChk,
            FontSizeEdit, HotkeyCombo, LangCombo, LV_ImageLangs, SaveFolderEdit, initialSaveFolder)
        if settingsSaved
            ToolTip("✅ All settings saved.")
        else
            ToolTip("⚠️ Some settings could not be saved.`r`n⚠️ 일부 설정을 저장하지 못했습니다.")
        SetTimer(() => ToolTip(), -1500)
        DestroyDash()
    }

    SaveBtn.OnEvent("Click", SaveAllSettings)
    CancelBtn.OnEvent("Click", DestroyDash)

    DashGui.OnEvent("Close", DestroyDash)
    DashGui.OnEvent("Escape", DestroyDash)

    ; Initial tab setup
    SwitchDashboardPanel(1, TabGenBtn, TabTrnBtn, TabAbtBtn, GenPanel, TrnPanel, AbtPanel)

    settingsPos := GetCenteredPositionOnMouseMonitor(780, 570)
    DashGui.Show("x" settingsPos.x " y" settingsPos.y " w780 h570")
    DashboardHwnd := DashGui.Hwnd
}

SCW_MinimizeAll() {
    for hwnd, winInfo in ClipWins {
        if !winInfo.IsMinimized {
            WinGetPos(&oX, &oY, , , "ahk_id " hwnd)
            winInfo.orgX := oX
            winInfo.orgY := oY
            WinMove(, , MINI_SIZE, MINI_SIZE, hwnd)
            WinSetTransparent(MINI_OPACITY, hwnd)
            winInfo.NumBg.Visible := true
            winInfo.NumText.Visible := true
            winInfo.NumText.Redraw()
            winInfo.IsMinimized := true
        }
    }
}

SCW_RestoreAll() {
    for hwnd, winInfo in ClipWins {
        if winInfo.IsMinimized {
            WinMove(winInfo.orgX, winInfo.orgY, winInfo.w + WINDOW_BORDER_WIDTH * 2, winInfo.h + WINDOW_BORDER_WIDTH * 2, hwnd)
            WinSetTransparent("Off", hwnd)
            winInfo.NumText.Visible := false
            winInfo.NumBg.Visible := false
            winInfo.IsMinimized := false
        }
    }
}

SCW_CloseAll() {
    ; Iterate the map and close all windows.
    targetHwnds := []
    for hwnd, info in ClipWins
        targetHwnds.Push(info.gui)

    for guiObj in targetHwnds
        CloseClipWin(guiObj)

    ToolTip("✅ 모든 캡처 창 닫기 완료`r`n✅ All clips closed.")
    SetTimer(() => ToolTip(), -2000)
}

/**
 * 활성화된 모든 플로팅 캡처 창을 모니터상에 순차 정렬(계단식 캐스케이드) 배치하는 알고리즘 함수
 * Cascade-sorts all active floating capture windows neatly across connected monitors.
 * @returns {None}
 */
SCW_SortCascade() {
    static currentMonitor := 0  ; Monitor toggle state

    arr := []
    for hwnd, winInfo in ClipWins {
        arr.Push(winInfo)
    }

    n := arr.Length
    if (n == 0)
        return

    ; Check monitor count and cycle the target monitor.
    monCount := MonitorGetCount()
    currentMonitor := Mod(currentMonitor, monCount) + 1  ; 1 → 2 → ... → 1

    ; Get the top-left coordinates of the selected monitor.
    MonitorGet(currentMonitor, &monLeft, &monTop)

    ; Sort by ID using bubble sort.
    loop n {
        i := 1
        while (i < n) {
            if (arr[i].id > arr[i + 1].id) {
                temp := arr[i]
                arr[i] := arr[i + 1]
                arr[i + 1] := temp
            }
            i++
        }
    }

    ; Cascade windows from the selected monitor's top-left corner.
    for index, winInfo in arr {
        x := monLeft + (n - index) * MINI_SIZE
        y := monTop + (index - 1) * MINI_SIZE
        WinMove(x, y, , , winInfo.gui.Hwnd)
        WinMoveTop("ahk_id " winInfo.gui.Hwnd)
    }

    ToolTip("📐 모니터 " currentMonitor "/" monCount " 정렬`r`n📐 Sorted to Monitor " currentMonitor "/" monCount)
    SetTimer(() => ToolTip(), -1500)
}

; ── Windows startup auto-run helpers ──
GetStartupShortcutPath() {
    return A_Startup "\ClipOCR-Pro.lnk"
}

HasLegacyStartupRegistry() {
    static regKey := "HKCU\Software\Microsoft\Windows\CurrentVersion\Run"
    try {
        val := RegRead(regKey, "ScreenClipTool")
        return (val != "")
    } catch {
        return false
    }
}

DeleteLegacyStartupRegistry() {
    static regKey := "HKCU\Software\Microsoft\Windows\CurrentVersion\Run"
    try RegDelete(regKey, "ScreenClipTool")
}

IsStartupEnabled() {
    return (FileExist(GetStartupShortcutPath()) != "" || HasLegacyStartupRegistry())
}

EnableStartup() {
    global APP_NAME, APP_ICON_PATH, APP_SOURCE_ICON_PATH

    linkPath := GetStartupShortcutPath()
    targetPath := A_IsCompiled ? A_ScriptFullPath : A_AhkPath
    shortcutArgs := A_IsCompiled ? "" : ('"' A_ScriptFullPath '"')

    if (targetPath == "")
        return false

    iconPath := ""
    if FileExist(APP_ICON_PATH)
        iconPath := APP_ICON_PATH
    else if FileExist(APP_SOURCE_ICON_PATH)
        iconPath := APP_SOURCE_ICON_PATH

    try {
        DirCreate(A_Startup)
        if FileExist(linkPath)
            FileDelete(linkPath)
        FileCreateShortcut(targetPath, linkPath, A_ScriptDir, shortcutArgs, APP_NAME, iconPath)
        DeleteLegacyStartupRegistry()
        return (FileExist(linkPath) != "")
    } catch {
        return false
    }
}

DisableStartup() {
    linkPath := GetStartupShortcutPath()
    try {
        if FileExist(linkPath)
            FileDelete(linkPath)
    }
    DeleteLegacyStartupRegistry()
    return !IsStartupEnabled()
}

; ── Manual dialog ──
global ManualHwnd := 0

ShowManualDialog() {
    global ManualHwnd, MANUAL_LANG, REG_PATH

    if (ManualHwnd && WinExist("ahk_id " ManualHwnd)) {
        WinGetPos(, , &manualW, &manualH, "ahk_id " ManualHwnd)
        manualPos := GetCenteredPositionOnMouseMonitor(manualW, manualH)
        WinMove(manualPos.x, manualPos.y, , , "ahk_id " ManualHwnd)
        WinActivate("ahk_id " ManualHwnd)
        return
    }

    ManGui := Gui("+AlwaysOnTop +ToolWindow +Border +Resize -DPIScale +MinSize480x800", "📖 App Manual")
    ManGui.BackColor := "FFFFFF"
    ManGui.SetFont("s9", "Segoe UI")

    ; ── Language dropdown ──
    ManGui.Add("Text", "x14 y12 w70 h22 cBlack", "Language:")
    ManGui.SetFont("s9", "Segoe UI")
    langList := ["KR 한국어", "US English", "PL Polski", "DE Deutsch", "FR Français", "ES Español"]

    defaultIndex := 2 ; Default to English (Choose2)
    if (MANUAL_LANG == "ko")
        defaultIndex := 1
    else if (MANUAL_LANG == "pl")
        defaultIndex := 3
    else if (MANUAL_LANG == "de")
        defaultIndex := 4
    else if (MANUAL_LANG == "fr")
        defaultIndex := 5
    else if (MANUAL_LANG == "es")
        defaultIndex := 6

    LangDDL := ManGui.Add("DropDownList", "x90 y9 w140 Choose" defaultIndex, langList)

    ; ── Manual text area ──
    ManEdit := ManGui.Add("Edit", "x14 y42 w552 h800 ReadOnly +Multi +VScroll", GetManualText(MANUAL_LANG))

    ; ── Bottom Close button ──
    CloseMBtn := ManGui.Add("Button", "x240 y852 w100 h32", "Close")
    CloseMBtn.SetFont("s9", "Segoe UI")

    ; Language-change event
    OnManualLangChange(*) {
        global MANUAL_LANG
        selected := LangDDL.Text
        if InStr(selected, "한국어")
            lang := "ko"
        else if InStr(selected, "Polski")
            lang := "pl"
        else if InStr(selected, "Deutsch")
            lang := "de"
        else if InStr(selected, "Français")
            lang := "fr"
        else if InStr(selected, "Español")
            lang := "es"
        else
            lang := "en"

        MANUAL_LANG := lang
        try SafeRegWriteString(lang, REG_PATH, "ManualLang")
        ManEdit.Value := GetManualText(lang)
    }
    LangDDL.OnEvent("Change", OnManualLangChange)

    DestroyManual(*) {
        global ManualHwnd := 0
        ManGui.Destroy()
    }

    CloseMBtn.OnEvent("Click", DestroyManual)
    ManGui.OnEvent("Close", DestroyManual)
    ManGui.OnEvent("Escape", DestroyManual)

    ; Resize handler
    OnManualResize(thisGui, MinMax, Width, Height) {
        if (MinMax == -1)
            return
        m := 14
        LangDDL.Move(90, 9, 140)
        ManEdit.Move(m, 42, Width - m * 2, Height - 42 - 50)
        CloseMBtn.Move((Width - 100) // 2, Height - 42, 100, 32)
    }
    ManGui.OnEvent("Size", OnManualResize)

    manualPos := GetCenteredPositionOnMouseMonitor(580, 894)
    ManGui.Show("x" manualPos.x " y" manualPos.y " w580 h894")
    ManualHwnd := ManGui.Hwnd
}

GetManualText(lang) {
    if (lang == "ko") {
        return "
        (
            📖 ScreenClip Tool 사용 설명서
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            
            🚀 빠른 시작
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            
            1. 📸 화면 캡처  (Win + 마우스 드래그)
               - Win 키를 누른 채 마우스 왼쪽 버튼으로 영역을 드래그합니다.
               - 선택한 영역이 항상-위 플로팅 창으로 표시되고 자동으로 클립보드에 복사됩니다.
            
            2. 🌐 선택 텍스트 번역  (Win + CapsLock)
               - 번역할 텍스트를 선택한 후 Win + CapsLock을 누릅니다.
               - 번역 결과 창에서 언어 콤보박스로 EN, KO, PL 등 원하는 언어로 전환 가능합니다.
               - Settings에서 단축키와 기본 번역 언어를 변경할 수 있습니다.
               - 최초 사용 시 외부 서비스(Google 번역) 전송에 대한 동의 안내가 1회 표시됩니다.
            
            3. 📧 Outlook 웹메일 용량 추정  (Ctrl + Win + 0)
               - 작성 중인 메일 본문 안을 클릭한 상태에서 실행합니다.
               - 첨부파일을 제외한 본문+제목/헤더의 보수적 예상 크기를 MB로 표시합니다.
            
            
            📸 캡처 창 기능
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            
            • 더블클릭: 축소/복원 (미니 사이즈 ↔ 원래 크기)
            • 드래그: 창 이동
            • 우클릭: 컨텍스트 메뉴
            
              🟥 Shift + 드래그: 빨간 테두리 박스 그리기
              🟨 Ctrl + 드래그: 노란 형광펜 하이라이트
              🟩 Alt + 드래그: 초록 형광펜 하이라이트
              ➡️ 우클릭 메뉴 → Arrow: 드래그 방향으로 화살표 그리기
              🔢 우클릭 메뉴 → Number Pin: 클릭 위치에 번호 핀 표시 (1, 2, 3… 자동 증가)
              🌫️ 우클릭 메뉴 → Mosaic: 드래그 영역을 모자이크 처리 (민감정보 가리기)
              ↩️ Ctrl + Z: 그리기 실행 취소

              📋 Ctrl + C: 클립보드에 이미지 복사
              📐 Ctrl + 0: Original Size로 설정 후 원본 크기 복사
              📐 Ctrl + 1~7: 가로 400~1600px로 설정 후 즉시 복사
              💾 Ctrl + S: 현재 출력 설정으로 저장 폴더에 JPG/PNG 저장 (기본: 바탕화면)
              Esc: 현재 캡처 창 닫기
              Ctrl + Esc: 모든 캡처 창 닫기
            
            
            🪟 창 관리
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            
            • Ctrl + ←: 모든 캡처 창 모니터별 정렬
            • Ctrl + ↑: 모든 캡처 창 축소
            • Ctrl + ↓: 모든 캡처 창 복원
            
            
            ⚙️ 설정 (Settings)
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            
            • 클립보드 이미지 크기: Original Size 또는 400~1600px
            • 파일 저장 프리셋: PNG(Doc/Pic 100%), JPG 90%(Doc 83%·Pic 70%), JPG 80%(65%·50%), JPG 70%(50%·35%)
            • 복사/저장 이미지 검정 아웃라인: 켜기/끄기
            • 저장 폴더(Ctrl+S): General 탭에서 이미지 저장 위치 선택 (기본: 바탕화면)
            • About 탭: GitHub 최신 버전 확인, 검증된 EXE 다운로드 및 자동 재시작
            • 번역 단축키: Win+CapsLock 등 5가지 옵션
            • 번역 결과 언어: 한국어, 영어, 폴란드어 등 유럽 언어 49개 지원
        )"
    }

    if (lang == "pl") {
        return "
        (
            📖 ScreenClip Tool — Instrukcja obsługi
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            
            🚀 Szybki start
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            
            1. 📸 Przechwytywanie ekranu  (Win + przeciągnij myszą)
               - Przytrzymaj klawisz Win i przeciągnij lewym przyciskiem myszy.
               - Zaznaczony obszar pojawi się jako okno pływające i zostanie skopiowany do schowka.
            
            2. 🌐 Tłumaczenie zaznaczonego tekstu  (Win + CapsLock)
               - Zaznacz tekst, a następnie naciśnij Win + CapsLock.
               - W oknie tłumaczenia możesz zmienić język docelowy (EN, KO, PL itp.).
               - Skrót klawiszowy i domyślny język można zmienić w Ustawieniach.
            
            3. 📧 Szacowanie rozmiaru poczty Outlook  (Ctrl + Win + 0)
               - Kliknij treść tworzonej wiadomości przed użyciem skrótu.
               - Pokazuje ostrożny szacunek MB bez załączników.
            
            
            📸 Funkcje okna przechwytywania
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            
            • Podwójne kliknięcie: minimalizuj/przywróć
            • Przeciąganie: przesuń okno
            • Prawy przycisk myszy: menu kontekstowe
            
              🟥 Shift + przeciągnij: czerwona ramka
              🟨 Ctrl + przeciągnij: żółte podświetlenie
              🟩 Alt + przeciągnij: zielone podświetlenie
              ↩️ Ctrl + Z: cofnij rysowanie
            
              📋 Ctrl + C: kopiuj do schowka
              📐 Ctrl + 0: ustaw oryginalny rozmiar i skopiuj
              📐 Ctrl + 1~7: ustaw szerokość 400~1600 px i skopiuj
              💾 Ctrl + S: zapisz JPG/PNG w ustawionym folderze
              Esc: zamknij bieżące okno
              Ctrl + Esc: zamknij wszystkie okna
            
            
            🪟 Zarządzanie oknami
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            
            • Ctrl + ←: sortuj okna kaskadowo
            • Ctrl + ↑: minimalizuj wszystkie
            • Ctrl + ↓: przywróć wszystkie
            
            
            ⚙️ Ustawienia
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            
            • Rozmiar obrazu: oryginalny lub szerokość 400~1600 px
            • Ustawienie zapisu: PNG 100% lub JPG 90/80/70% z szacunkami Doc/Pic
            • Czarny kontur kopiowanego/zapisanego obrazu: wł./wył.
            • Karta About: sprawdzanie, pobieranie i instalacja aktualizacji GitHub
            • Skrót do tłumaczenia: 5 opcji
            • Język tłumaczenia: 49 języków europejskich
        )"
    }

    if (lang == "de") {
        return "
        (
            📖 ScreenClip Tool — Benutzerhandbuch
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            
            🚀 Schnellstart
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            
            1. 📸 Bildschirmaufnahme  (Win + Maus ziehen)
               - Halten Sie Win gedrückt und ziehen Sie mit der linken Maustaste.
               - Der ausgewählte Bereich wird als schwebendes Fenster angezeigt und in die Zwischenablage kopiert.
            
            2. 🌐 Markierten Text übersetzen  (Win + CapsLock)
               - Wählen Sie Text aus und drücken Sie Win + CapsLock.
               - Im Übersetzungsfenster können Sie die Zielsprache wechseln (EN, KO, PL usw.).
               - Tastenkürzel und Standardsprache können in den Einstellungen geändert werden.
            
            3. 📧 Outlook-Mailgröße schätzen  (Strg + Win + 0)
               - Klicken Sie vor dem Start in den Nachrichtentext.
               - Zeigt eine konservative MB-Schätzung ohne Anhänge.
            
            
            📸 Funktionen des Aufnahmefensters
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            
            • Doppelklick: Minimieren/Wiederherstellen
            • Ziehen: Fenster verschieben
            • Rechtsklick: Kontextmenü
            
              🟥 Shift + Ziehen: Roten Rahmen zeichnen
              🟨 Strg + Ziehen: Gelbe Hervorhebung
              🟩 Alt + Ziehen: Grüne Hervorhebung
              ↩️ Strg + Z: Zeichnung rückgängig machen
            
              📋 Strg + C: In Zwischenablage kopieren
              📐 Strg + 0: Originalgröße einstellen und kopieren
              📐 Strg + 1~7: 400~1600 px einstellen und kopieren
              💾 Strg + S: JPG/PNG im ausgewählten Ordner speichern
              Esc: Aktuelles Fenster schließen
              Strg + Esc: Alle Fenster schließen
            
            
            🪟 Fensterverwaltung
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            
            • Strg + ←: Kaskadiert sortieren
            • Strg + ↑: Alle minimieren
            • Strg + ↓: Alle wiederherstellen
            
            
            ⚙️ Einstellungen
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            
            • Bildgröße: Originalgröße oder 400~1600 px Breite
            • Speicherprofil: PNG 100% oder JPG 90/80/70% mit Doc/Pic-Schätzwerten
            • Schwarze Bildkontur beim Kopieren/Speichern: Ein/Aus
            • About-Tab: GitHub-Updates prüfen, herunterladen und installieren
            • Übersetzungs-Tastenkürzel: 5 Optionen
            • Übersetzungssprache: 49 europäische Sprachen
        )"
    }

    if (lang == "fr") {
        return "
        (
            📖 ScreenClip Tool — Manuel d'utilisation
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            
            🚀 Démarrage rapide
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            
            1. 📸 Capture d'écran  (Win + glisser la souris)
               - Maintenez Win et glissez avec le bouton gauche de la souris.
               - La zone sélectionnée s'affiche en fenêtre flottante et est copiée dans le presse-papiers.
            
            2. 🌐 Traduire le texte sélectionné  (Win + CapsLock)
               - Sélectionnez du texte, puis appuyez sur Win + CapsLock.
               - Dans la fenêtre de traduction, changez la langue cible (EN, KO, PL, etc.).
               - Le raccourci et la langue par défaut sont modifiables dans les Paramètres.
            
            3. 📧 Estimer la taille du mail Outlook  (Ctrl + Win + 0)
               - Cliquez dans le corps du message avant d'utiliser le raccourci.
               - Affiche une estimation prudente en Mo, pièces jointes exclues.
            
            
            📸 Fonctions de la fenêtre de capture
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            
            • Double-clic : minimiser/restaurer
            • Glisser : déplacer la fenêtre
            • Clic droit : menu contextuel
            
              🟥 Shift + glisser : cadre rouge
              🟨 Ctrl + glisser : surlignage jaune
              🟩 Alt + glisser : surlignage vert
              ↩️ Ctrl + Z : annuler le dessin
            
              📋 Ctrl + C : copier dans le presse-papiers
              📐 Ctrl + 0 : taille originale et copie
              📐 Ctrl + 1~7 : régler 400~1600 px et copier
              💾 Ctrl + S : enregistrer en JPG/PNG dans le dossier choisi
              Esc : fermer la fenêtre actuelle
              Ctrl + Esc : fermer toutes les fenêtres
            
            
            🪟 Gestion des fenêtres
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            
            • Ctrl + ← : trier en cascade
            • Ctrl + ↑ : tout minimiser
            • Ctrl + ↓ : tout restaurer
            
            
            ⚙️ Paramètres
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            
            • Taille de l'image : originale ou largeur 400~1600 px
            • Profil : PNG 100 % ou JPG 90/80/70 % avec estimations Doc/Pic
            • Contour noir à la copie/enregistrement : activé/désactivé
            • Onglet About : vérifier, télécharger et installer les mises à jour GitHub
            • Raccourci de traduction : 5 options
            • Langue de traduction : 49 langues européennes
        )"
    }

    if (lang == "es") {
        return "
        (
            📖 ScreenClip Tool — Manual de usuario
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            
            🚀 Inicio rápido
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            
            1. 📸 Captura de pantalla  (Win + arrastrar ratón)
               - Mantenga Win pulsado y arrastre con el botón izquierdo del ratón.
               - El área seleccionada aparece como ventana flotante y se copia al portapapeles.
            
            2. 🌐 Traducir texto seleccionado  (Win + CapsLock)
               - Seleccione el texto y pulse Win + CapsLock.
               - En la ventana de traducción, cambie el idioma de destino (EN, KO, PL, etc.).
               - El atajo y el idioma predeterminado se pueden cambiar en Configuración.
            
            3. 📧 Estimar el tamaño del correo de Outlook  (Ctrl + Win + 0)
               - Haga clic en el cuerpo del mensaje antes de usar el atajo.
               - Muestra una estimación prudente en MB sin archivos adjuntos.
            
            
            📸 Funciones de la ventana de captura
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            
            • Doble clic: minimizar/restaurar
            • Arrastrar: mover la ventana
            • Clic derecho: menú contextual
            
              🟥 Shift + arrastrar: marco rojo
              🟨 Ctrl + arrastrar: resaltado amarillo
              🟩 Alt + arrastrar: resaltado verde
              ↩️ Ctrl + Z: deshacer dibujo
            
              📋 Ctrl + C: copiar al portapapeles
              📐 Ctrl + 0: tamaño original y copiar
              📐 Ctrl + 1~7: ajustar 400~1600 px y copiar
              💾 Ctrl + S: guardar JPG/PNG en la carpeta elegida
              Esc: cerrar ventana actual
              Ctrl + Esc: cerrar todas las ventanas
            
            
            🪟 Gestión de ventanas
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            
            • Ctrl + ←: ordenar en cascada
            • Ctrl + ↑: minimizar todas
            • Ctrl + ↓: restaurar todas
            
            
            ⚙️ Configuración
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            
            • Tamaño de imagen: original o ancho 400~1600 px
            • Perfil: PNG 100% o JPG 90/80/70% con estimaciones Doc/Pic
            • Contorno negro al copiar/guardar: activado/desactivado
            • Pestaña About: buscar, descargar e instalar actualizaciones de GitHub
            • Atajo de traducción: 5 opciones
            • Idioma de traducción: 49 idiomas europeos
        )"
    }

    ; Default: English
    return "
    (
        📖 ScreenClip Tool — User Manual
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        
        🚀 Quick Start
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        
        1. 📸 Screen Capture  (Win + Mouse Drag)
           - Hold Win and drag with the left mouse button.
           - The selected area appears as an always-on-top floating window and is auto-copied to clipboard.
        
        2. 🌐 Translate Selected Text  (Win + CapsLock)
           - Select text, then press Win + CapsLock.
           - In the translation window, switch target language (EN, KO, PL, etc.) via the combo box.
           - The hotkey and default language can be changed in Settings.
           - On first use, a one-time consent notice about sending data to an external service (Google Translate) is shown.
        
        3. 📧 Estimate Outlook Web Mail Size  (Ctrl + Win + 0)
           - Click inside the message body before using the hotkey.
           - Shows a conservative MB estimate excluding attachments.
        
        
        📸 Capture Window Features
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        
        • Double-click: Minimize/Restore (mini size ↔ original)
        • Drag: Move window
        • Right-click: Context menu
        
          🟥 Shift + Drag: Draw a red border box
          🟨 Ctrl + Drag: Yellow highlight
          🟩 Alt + Drag: Green highlight
          ➡️ Right-click menu → Arrow: Draw an arrow in the drag direction
          🔢 Right-click menu → Number Pin: Stamp a numbered pin where you click (1, 2, 3… auto-increment)
          🌫️ Right-click menu → Mosaic: Pixelate the dragged area (mask sensitive info)
          ↩️ Ctrl + Z: Undo drawing

          📋 Ctrl + C: Copy image to clipboard
          📐 Ctrl + 0: Set Original Size and copy at original dimensions
          📐 Ctrl + 1~7: Set width to 400~1600 px and copy immediately
          💾 Ctrl + S: Save a JPG/PNG to the selected folder with current output settings (default: Desktop)
          Esc: Close current capture window
          Ctrl + Esc: Close all capture windows
        
        
        🪟 Window Management
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        
        • Ctrl + ←: Cascade-sort all clips across monitors
        • Ctrl + ↑: Minimize all clips
        • Ctrl + ↓: Restore all clips
        
        
        ⚙️ Settings
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        
        • Clipboard image size: Original Size or 400~1600 px width
        • File-save preset: PNG (Doc/Pic 100%), JPG 90% (Doc 83%·Pic 70%), JPG 80% (65%·50%), JPG 70% (50%·35%)
        • Black outline for copied/saved images: On/Off
        • Save folder (Ctrl+S): Choose the image save location on the General tab (default: Desktop)
        • About tab: Check GitHub, download a verified EXE, install, and restart
        • Translation hotkey: 5 options available
        • Translation language: 49 European languages supported
    )"
}
