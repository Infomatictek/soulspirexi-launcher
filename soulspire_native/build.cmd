@echo off
setlocal enabledelayedexpansion
set "SN_DIR=%~dp0"
cd /d "%SN_DIR%"

set "EXTRA_FLAGS=%SOULSPIRE_NATIVE_EXTRA_CXXFLAGS%"
if "%EXTRA_FLAGS%"=="" set "EXTRA_FLAGS=%CRYSTALJOBS_EXTRA_CXXFLAGS%"

set "VCVARS="
if exist "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars32.bat" (
    set "VCVARS=C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars32.bat"
) else if exist "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars32.bat" (
    set "VCVARS=C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars32.bat"
) else if exist "%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" (
    for /f "usebackq delims=" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -property installationPath`) do (
        if exist "%%i\VC\Auxiliary\Build\vcvars32.bat" set "VCVARS=%%i\VC\Auxiliary\Build\vcvars32.bat"
    )
)

if not "%VCVARS%"=="" (
    call "%VCVARS%" >nul
    if errorlevel 1 exit /b 1
    cd /d "%SN_DIR%"

    cl /nologo /std:c++17 /W4 /WX /EHsc /O2 /MT /LD %EXTRA_FLAGS% soulspire_native.cpp /link /DEF:soulspire_native.def /OUT:soulspire_native.dll
    if errorlevel 1 exit /b 1

    cl /nologo /std:c++17 /W4 /WX /EHsc /O2 /MT %EXTRA_FLAGS% tests\selftest.cpp /Fe:selftest.exe
    if errorlevel 1 exit /b 1
) else (
    where i686-w64-mingw32-clang++ >nul 2>&1
    if errorlevel 1 (
        echo ERROR: Could not locate vcvars32.bat or i686-w64-mingw32-clang++
        exit /b 1
    )

    (
        echo LIBRARY soulspire_native
        echo EXPORTS
        echo     SoulspireNativeInitialize=SoulspireNativeInitialize@0
        echo     SoulspireNativeShutdown=SoulspireNativeShutdown@0
        echo     SoulspireNativeGetStatus=SoulspireNativeGetStatus@8
        echo     SoulspireNativeSetState=SoulspireNativeSetState@8
        echo     SoulspireNativeReloadConfig=SoulspireNativeReloadConfig@0
        echo     SoulspireNativeReplaceCatalog=SoulspireNativeReplaceCatalog@8
        echo     SoulspireNativeUpsertAction=SoulspireNativeUpsertAction@4
        echo     SoulspireNativeClearCatalog=SoulspireNativeClearCatalog@0
        echo     SoulspireNativeSetActiveSoul=SoulspireNativeSetActiveSoul@12
        echo     SoulspireNativeClearActiveSoul=SoulspireNativeClearActiveSoul@0
        echo     SoulspireNativeGetActionStatus=SoulspireNativeGetActionStatus@8
        echo     SoulspireNativeSetActionRowLimit=SoulspireNativeSetActionRowLimit@4
        echo     SoulspireNativeReplaceVisibility=SoulspireNativeReplaceVisibility@8
        echo     SoulspireNativeClearVisibility=SoulspireNativeClearVisibility@0
        echo     SoulspireNativeGetVisibilityStatus=SoulspireNativeGetVisibilityStatus@8
        echo     SoulspireNativeReplaceWeaponRules=SoulspireNativeReplaceWeaponRules@8
        echo     SoulspireNativeClearWeaponRules=SoulspireNativeClearWeaponRules@0
        echo     SoulspireNativeGetWeaponStatus=SoulspireNativeGetWeaponStatus@8
        echo     SoulspireNativeSetLocalEquippedWeapons=SoulspireNativeSetLocalEquippedWeapons@16
        echo     SoulspireNativeUpsertPeerSoul=SoulspireNativeUpsertPeerSoul@16
        echo     SoulspireNativeGetHookDiagnostics=SoulspireNativeGetHookDiagnostics@8
        echo     SoulspireNativeGetIdentityDiagnostics=SoulspireNativeGetIdentityDiagnostics@8
        echo     SoulspireNativeGetInterfaceInfo=SoulspireNativeGetInterfaceInfo@8
        echo     SoulspireNativeGetMainMenuStatus=SoulspireNativeGetMainMenuStatus@8
        echo     SoulspireNativeConsumeCoreOpenRequest=SoulspireNativeConsumeCoreOpenRequest@0
        echo     SoulspireNativeGetWeaponModelDiag=SoulspireNativeGetWeaponModelDiag@8
        echo     CrystalJobsInitialize=CrystalJobsInitialize@0
        echo     CrystalJobsShutdown=CrystalJobsShutdown@0
        echo     CrystalJobsGetStatus=CrystalJobsGetStatus@8
        echo     CrystalJobsSetState=CrystalJobsSetState@8
        echo     CrystalJobsReplaceCatalog=CrystalJobsReplaceCatalog@8
        echo     CrystalJobsUpsertAction=CrystalJobsUpsertAction@4
        echo     CrystalJobsClearCatalog=CrystalJobsClearCatalog@0
        echo     CrystalJobsSetActiveSoul=CrystalJobsSetActiveSoul@12
        echo     CrystalJobsClearActiveSoul=CrystalJobsClearActiveSoul@0
        echo     CrystalJobsGetActionStatus=CrystalJobsGetActionStatus@8
        echo     CrystalJobsSetActionRowLimit=CrystalJobsSetActionRowLimit@4
        echo     CrystalJobsReplaceVisibility=CrystalJobsReplaceVisibility@8
        echo     CrystalJobsClearVisibility=CrystalJobsClearVisibility@0
        echo     CrystalJobsGetVisibilityStatus=CrystalJobsGetVisibilityStatus@8
        echo     CrystalJobsReplaceWeaponRules=CrystalJobsReplaceWeaponRules@8
        echo     CrystalJobsClearWeaponRules=CrystalJobsClearWeaponRules@0
        echo     CrystalJobsGetWeaponStatus=CrystalJobsGetWeaponStatus@8
        echo     CrystalJobsGetHookDiagnostics=CrystalJobsGetHookDiagnostics@8
        echo     CrystalJobsGetIdentityDiagnostics=CrystalJobsGetIdentityDiagnostics@8
        echo     expCreatePlugin=expCreatePlugin@4
        echo     expDestroyPlugin=expDestroyPlugin@4
        echo     expGetInterfaceVersion=expGetInterfaceVersion@0
    ) > soulspire_native.mingw.def

    i686-w64-mingw32-clang++ -std=c++17 -O2 -Wall -Wextra -Werror -fms-extensions -fasm-blocks -static -shared soulspire_native.cpp soulspire_native.mingw.def -o soulspire_native.dll
    set "BUILD_RC=!ERRORLEVEL!"
    del /q soulspire_native.mingw.def 2>nul
    if not "!BUILD_RC!"=="0" exit /b !BUILD_RC!

    i686-w64-mingw32-clang++ -std=c++17 -O2 -Wall -Wextra -Werror -fms-extensions -fasm-blocks -static tests\selftest.cpp -o selftest.exe
    if errorlevel 1 exit /b 1
)

selftest.exe
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

if not exist "%SN_DIR%..\plugins\ashita4" mkdir "%SN_DIR%..\plugins\ashita4"
copy /y "%SN_DIR%soulspire_native.dll" "%SN_DIR%..\plugins\ashita4\soulspire_native.dll" >nul
if errorlevel 1 exit /b 1

del /q *.obj *.exp *.lib 2>nul
if not "%SOULSPIRE_NATIVE_KEEP_SELFTEST%"=="1" if not "%CRYSTALJOBS_KEEP_SELFTEST%"=="1" del /q selftest.exe 2>nul
echo Built and verified soulspire_native.dll to plugins\ashita4\soulspire_native.dll
