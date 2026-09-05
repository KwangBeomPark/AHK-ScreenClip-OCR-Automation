# Local OCR deployment

ClipOCR-Pro keeps text extraction local. The Light executable uses `Windows.Media.Ocr`; the optional Full ZIP places a company-approved portable Tesseract runtime beside the app.

## Runtime selection

- `Auto`: try the first requested Windows OCR language, then portable Tesseract with every available requested language, then the remaining Windows OCR languages.
- `Windows OCR only`: use only OCR languages installed in Windows.
- `Portable Tesseract only`: use only the adjacent portable runtime.

Language tags use BCP 47, for example `ko-KR,en-US`. Windows may expose a neutral tag such as `ko`; ClipOCR-Pro matches the base language. Tesseract maps those defaults to `kor+eng`.

## English Windows without a Korean language pack

No Windows UI-language change is required. Deploy the Full ZIP with this structure:

```text
ClipOCR-Pro.exe
ocr\
  tesseract.exe
  tessdata\
    kor.traineddata
    eng.traineddata
  ...runtime DLLs and configuration supplied by the approved distribution...
```

The build does not fetch OCR binaries. Obtain and approve a portable Windows Tesseract distribution according to company software and security policy, then run:

```powershell
.\scripts\build.ps1 -TesseractDirectory C:\Approved\Tesseract
```

The build rejects a Full package unless `tesseract.exe`, Korean data, and English data are present. It copies the complete approved runtime so its required DLLs are preserved. The resulting `App03_ClipOCR-Pro_vX.Y.Z-Full.zip` is checksummed in `SHA256SUMS.txt` and listed in the build manifest.

## Privacy boundary

Local OCR never calls the Google translation path and never asks for translation consent. Choosing Google image or selected-text translation remains an explicit separate action governed by the existing consent notice.
