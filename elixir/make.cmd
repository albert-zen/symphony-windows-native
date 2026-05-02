@echo off
setlocal

set "MIX_CMD=%MIX%"
if "%MIX_CMD%"=="" for %%I in (mix.bat) do set "MIX_CMD=%%~$PATH:I"
if "%MIX_CMD%"=="" set "MIX_CMD=mix.bat"

if "%~1"=="" goto help

set "TARGET=%~1"
shift /1

if "%TARGET%"=="help" goto help
if "%TARGET%"=="setup" goto setup
if "%TARGET%"=="deps" goto deps
if "%TARGET%"=="build" goto build
if "%TARGET%"=="fmt" goto fmt
if "%TARGET%"=="fmt-check" goto fmt_check
if "%TARGET%"=="diff-check" goto diff_check
if "%TARGET%"=="lint" goto lint
if "%TARGET%"=="test" goto test
if "%TARGET%"=="windows-native-test" goto windows_native_test
if "%TARGET%"=="coverage" goto coverage
if "%TARGET%"=="dialyzer" goto dialyzer
if "%TARGET%"=="e2e" goto e2e
if "%TARGET%"=="ci" goto ci
if "%TARGET%"=="all" goto ci

echo Unknown target: %TARGET% 1>&2
goto help_error

:help
echo Targets: setup, deps, fmt, fmt-check, diff-check, lint, test, windows-native-test, coverage, dialyzer, e2e, ci
exit /b 0

:help_error
echo Targets: setup, deps, fmt, fmt-check, diff-check, lint, test, windows-native-test, coverage, dialyzer, e2e, ci 1>&2
exit /b 2

:setup
"%MIX_CMD%" setup
exit /b %ERRORLEVEL%

:deps
"%MIX_CMD%" deps.get
exit /b %ERRORLEVEL%

:build
"%MIX_CMD%" build
exit /b %ERRORLEVEL%

:fmt
"%MIX_CMD%" format
exit /b %ERRORLEVEL%

:fmt_check
"%MIX_CMD%" format.check_normalized
exit /b %ERRORLEVEL%

:diff_check
if "%DIFF_RANGE%"=="" (
  git diff --check
) else (
  git diff --check %DIFF_RANGE%
)
exit /b %ERRORLEVEL%

:lint
"%MIX_CMD%" lint
exit /b %ERRORLEVEL%

:test
"%MIX_CMD%" test
exit /b %ERRORLEVEL%

:windows_native_test
"%MIX_CMD%" test --include windows_native test/symphony_elixir/local_shell_test.exs test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/windows_preflight_test.exs test/symphony_elixir/windows_lifecycle_scripts_test.exs test/symphony_elixir/repository_line_endings_test.exs test/symphony_elixir/ssh_test.exs test/mix/tasks/workspace_before_remove_test.exs test/mix/tasks/pr_body_check_test.exs test/mix/tasks/format_check_normalized_test.exs test/symphony_elixir/specs_check_test.exs
exit /b %ERRORLEVEL%

:coverage
"%MIX_CMD%" test --cover
exit /b %ERRORLEVEL%

:dialyzer
"%MIX_CMD%" deps.get
if errorlevel 1 exit /b %ERRORLEVEL%
"%MIX_CMD%" dialyzer --format short
exit /b %ERRORLEVEL%

:e2e
set "SYMPHONY_RUN_LIVE_E2E=1"
"%MIX_CMD%" test test/symphony_elixir/live_e2e_test.exs
exit /b %ERRORLEVEL%

:ci
call "%~f0" setup
if errorlevel 1 exit /b %ERRORLEVEL%
call "%~f0" build
if errorlevel 1 exit /b %ERRORLEVEL%
call "%~f0" fmt-check
if errorlevel 1 exit /b %ERRORLEVEL%
call "%~f0" diff-check
if errorlevel 1 exit /b %ERRORLEVEL%
call "%~f0" lint
if errorlevel 1 exit /b %ERRORLEVEL%
call "%~f0" coverage
if errorlevel 1 exit /b %ERRORLEVEL%
call "%~f0" dialyzer
exit /b %ERRORLEVEL%
