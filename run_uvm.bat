@echo off
:: =============================================================================
:: run_uvm.bat — Run AES-128 UVM test suite under Vivado xsim
:: Run from the PROJECT ROOT:  C:\Users\mamed\Desktop\aes_core> run_uvm.bat
::
:: Requirements:
::   1. Vivado in PATH — open a "Vivado Tcl Shell" from the Start menu, or
::      run:  C:\Xilinx\Vivado\<ver>\settings64.bat  before this script.
::   2. gcc in PATH — install MinGW (https://winlibs.com/) and add its bin\ to
::      PATH, or use Git for Windows' bundled gcc.
::
:: Usage:
::   run_uvm.bat nist       <- directed NIST vectors  (Phase 1)
::   run_uvm.bat random     <- 100 random vectors      (Phase 2a)
::   run_uvm.bat back2back  <- 50 stress vectors       (Phase 2b)
::   run_uvm.bat all        <- all three suites
:: =============================================================================

set TEST=%1
if "%TEST%"=="" set TEST=nist

:: ---- Vivado install path (adjust if your version differs) ------------------
if not defined XILINX_VIVADO (
    set XILINX_VIVADO=C:\Xilinx\Vivado\2024.1
)
echo Using Vivado at: %XILINX_VIVADO%

:: ---- Step 1: Build DPI-C shared library ------------------------------------
echo.
echo [1/3] Compiling DPI-C golden model ...
gcc -O2 -shared -Wl,--export-all-symbols ^
    -I"%XILINX_VIVADO%\data\xsim\include" ^
    -o uvm\dpi\aes_dpi.dll ^
    uvm\dpi\aes_dpi.c
if errorlevel 1 (
    echo ERROR: DPI-C compilation failed.
    echo        Make sure gcc is in your PATH.
    echo        Install MinGW from https://winlibs.com/ or use Git for Windows.
    exit /b 1
)
echo        Done: uvm\dpi\aes_dpi.dll

:: ---- Step 2: Compile SystemVerilog with xvlog ------------------------------
echo.
echo [2/3] Compiling SystemVerilog (xvlog) ...
xvlog -sv -L uvm ^
    rtl/aes_sbox.v ^
    rtl/aes_key_expand.v ^
    rtl/aes_round.v ^
    rtl/aes_top.v ^
    uvm/top/aes_if.sv ^
    uvm/sva/aes_assertions.sv ^
    uvm/coverage/aes_coverage.sv ^
    uvm/env/aes_seq_item.sv ^
    uvm/env/aes_driver.sv ^
    uvm/env/aes_monitor.sv ^
    uvm/env/aes_scoreboard.sv ^
    uvm/env/aes_agent.sv ^
    uvm/env/aes_env.sv ^
    uvm/seq/aes_seq_base.sv ^
    uvm/seq/aes_seq_single.sv ^
    uvm/seq/aes_seq_back2back.sv ^
    uvm/test/aes_test_base.sv ^
    uvm/test/aes_test_nist.sv ^
    uvm/test/aes_test_random.sv ^
    uvm/test/aes_test_back2back.sv ^
    uvm/top/aes_tb_top.sv
if errorlevel 1 (
    echo ERROR: xvlog compilation failed. Check xvlog.log.
    exit /b 1
)

:: ---- Step 3: Elaborate (link DPI-C, build snapshot) -----------------------
echo.
echo [2/3] Elaborating (xelab) ...
xelab -sv -L uvm aes_tb_top ^
    -sv_lib uvm/dpi/aes_dpi ^
    -s aes_uvm_snap
if errorlevel 1 (
    echo ERROR: xelab elaboration failed. Check xelab.log.
    exit /b 1
)

:: ---- Step 4: Run simulation(s) --------------------------------------------
echo.
echo [3/3] Running simulation: TEST=%TEST%

if "%TEST%"=="all" (
    call :run_test aes_test_nist
    call :run_test aes_test_random
    call :run_test aes_test_back2back
) else (
    call :run_test aes_test_%TEST%
)

echo.
echo Done. Waveform saved to aes_uvm_snap.wdb
echo To open: vivado -source open_wave.tcl  (or open Vivado GUI)
exit /b 0

:run_test
echo.
echo --- Running %1 ---
xsim aes_uvm_snap -testplusarg UVM_TESTNAME=%1 -runall
if errorlevel 1 (
    echo WARNING: xsim returned non-zero for %1
)
goto :eof
