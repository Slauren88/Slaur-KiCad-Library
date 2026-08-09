# Slaur KiCad Library

Personal KiCad symbols, footprints, and 3D models, kept separately from the official KiCad libraries.

## Contents

```text
symbols/
  SlaurLib.kicad_sym
footprints/
  SlaurLib.pretty/
3dmodels/
  SlaurLib.3dshapes/
  Connector_Molex.3dshapes/
legacy/
  SlaurLib.lib
  SlaurLib.dcm
scripts/
  Install-KiCad-Libraries.ps1
  Download-KiCad-Libraries.ps1
  Publish-Slaur-Library.ps1
Configure-KiCad-Libraries.cmd
Download-Library-Updates.cmd
Publish-My-Library.cmd
```

The main `SlaurLib.kicad_sym` includes eight symbols converted from the archived legacy library with KiCad 10:

- ESP8266-07
- GPS-RTK2
- LMR23630ADDA
- MCP4561
- Nixie_Z570M_B13D
- RaspberryPi_CM3L
- TSS721
- TUSB8020B

The original `.lib` and `.dcm` files are retained in `legacy/` for traceability but are not loaded by KiCad. New work should use `SlaurLib.kicad_sym`.

## Install on Windows

Install KiCad and Git, clone this repository to `C:\KiCad-Libraries`, close KiCad, and double-click:

```text
Configure-KiCad-Libraries.cmd
```

The equivalent PowerShell command is:

```powershell
cd C:\KiCad-Libraries\Slaur-KiCad-Library
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-KiCad-Libraries.ps1
```

The installer automatically selects the newest KiCad release installed under `C:\Program Files\KiCad`. It then:

1. Clones or updates the official symbol, footprint, and 3D-model repositories.
2. Configures the matching versioned variables, such as `KICAD10_SYMBOL_DIR`, plus the stable custom variables `SLAURLIB_DIR` and `KICAD_OFFICIAL_3DMODEL_DIR`.
3. Registers the official and Slaur nested library tables.
4. Creates timestamped backups before changing existing KiCad configuration files.

Restart KiCad after installation.

To use a different library root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-KiCad-Libraries.ps1 -LibraryRoot 'D:\KiCad-Libraries'
```

If several KiCad releases are installed, a specific one can be selected explicitly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-KiCad-Libraries.ps1 -KiCadVersion '10.0'
```

After installing a new major KiCad release, close KiCad and double-click `Configure-KiCad-Libraries.cmd` again. It configures the new version's separate settings directory automatically. Official libraries use the matching `v<major>` maintenance branch when one exists; otherwise they use `master`, which is how the current KiCad release is maintained.

## Everyday workflow

Two double-click scripts at the repository root handle normal synchronization.

### 1. Download before editing

Close KiCad and double-click:

```text
Download-Library-Updates.cmd
```

This downloads changes for the official KiCad symbols, footprints, and 3D models as well as this personal library. A repository with uncommitted changes is skipped rather than overwritten.

### 2. Publish after editing

Save your work, close the KiCad editors, and double-click:

```text
Publish-My-Library.cmd
```

The publisher:

1. Detects the newest installed KiCad release and validates the symbols and footprints with it.
2. Checks that every referenced 3D model exists.
3. Refuses to publish if GitHub contains changes that have not been downloaded.
4. Shows the files being committed and asks for a short description.
5. Commits and pushes the changes to GitHub.

Git author details must be configured once before the first publication:

```powershell
git config --global user.name "Your Name"
git config --global user.email "YOUR_GITHUB_EMAIL_OR_NOREPLY"
```

The underlying PowerShell scripts can also be run directly when command-line options such as validation-only or commit-without-push are useful.

## Path conventions

The symbol and footprint tables use the `SLAURLIB_DIR` KiCad path variable. Custom footprint 3D-model references use paths such as:

```text
${SLAURLIB_DIR}/3dmodels/SlaurLib.3dshapes/ESP32-C6-WROOM-1.STEP
```

References into the official KiCad 3D-model checkout use `KICAD_OFFICIAL_3DMODEL_DIR`, which intentionally does not contain a KiCad major version.

The 1.3-inch OLED footprint intentionally has no 3D-model reference because the referenced `1.3in_OLED_voron.step` file was unavailable.

Do not edit personal components inside the official KiCad repositories.

## Licensing

No repository-wide license has been declared. Confirm the origin and redistribution terms of third-party symbols, footprints, and models before publishing or reusing them.
