# Как это работает

Документ для того, кто будет поддерживать инструмент, а не для владельца проблемного ПК.

## Поток данных

```
START-HERE.bat
  └─ powershell -ExecutionPolicy Bypass -File GPU-Diag.ps1 -Mode Menu
       ├─ UAC: самоперезапуск с -Verb RunAs (кроме -Mode Watch)
       └─ меню 1..6
            ├─ Build-Report        → report.txt
            ├─ Invoke-Fix          → powercfg + registry, бэкап в fix-backup.json
            ├─ Invoke-InstallWatch → задача GPU-Diag-Watch (-Mode Watch)
            └─ New-DiagPackage     → ZIP на рабочем столе
```

Пути:

| Что | Где |
|---|---|
| логи и бэкап | `%LOCALAPPDATA%\GPU-Diag` |
| рабочая папка сборки отчёта | `%USERPROFILE%\Desktop\GPU-DIAG\run-<таймстамп>` |
| готовый архив | `%USERPROFILE%\Desktop\GPU-DIAG-<COMPUTERNAME>-<таймстамп>.zip` |
| задача планировщика | `GPU-Diag-Watch` |

## Источники данных отчёта

| Раздел | Источник |
|---|---|
| OS / машина / BIOS / RAM | `Win32_OperatingSystem`, `Win32_ComputerSystem`, `Win32_BaseBoard`, `Win32_BIOS`, `Win32_PhysicalMemory` |
| GPU | `Win32_VideoController` (`PNPDeviceID` → VEN_10DE/1002/8086) |
| Драйверы | `Win32_PnPSignedDriver` (DeviceClass = DISPLAY), `%SystemRoot%\System32\DriverStore\FileRepository`, `Get-ScheduledTask`-независимо: ключи `WindowsUpdate\Auto Update\RebootRequired`, `PendingFileRenameOperations` |
| Обновления драйверов | `Microsoft.Update.Session` в отдельном процессе, таймаут 60 с, `IsInstalled=0 AND Type='Driver'` |
| Мониторы | `root\wmi`: `WmiMonitorID`, `WmiMonitorConnectionParams` (`VideoOutputTechnology`) |
| Нагрузка GPU | `Get-Counter '\GPU Engine(*)\Utilization Percentage'`, агрегация по `pid_*` |
| NVIDIA | `nvidia-smi -i 0 --query-gpu=... --format=csv,noheader,nounits`, `--list-gpus` |
| CPU | `Win32_Processor`, `Win32_PerfFormattedData_Counters_ProcessorInformation`, `MSAcpi_ThermalZoneTemperature` |
| Питание | `powercfg /query SCHEME_CURRENT <sub> <setting>`; значения берутся как **последние два hex-числа** в выводе (AC, DC) — это не зависит от языка Windows |
| Реестр графики | `HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers` (`TdrDelay`, `TdrDdiDelay`, `TdrLevel`, `HwSchMode`), `HKLM\SOFTWARE\Microsoft\Windows\Dwm` (`OverlayTestMode` = MPO) |
| События | `Get-WinEvent -FilterHashtable` по списку провайдеров + id 4101/4102/4103 |
| Дампы | `C:\Windows\Minidump`, `C:\Windows\LiveKernelReports` (рекурсивно) |
| WER | Application log, `Windows Error Reporting` id 1001, фильтр `LiveKernelEvent|BlueScreen`, группировка по `P1` |

### Релевантные провайдеры и ID

- `Display`, `nvlddmkm`, `amdkmdag`, `amdkmdap`, `igfx` — сбои драйвера экрана.
- `Microsoft-Windows-Kernel-Power` 41 — потеря питания; 42 — переход в сон.
- `Microsoft-Windows-WHEA-Logger` 17/18/19 — аппаратные ошибки шины/памяти.
- `BugCheck` 1001, `EventLog` 6008 — BSOD и неожиданное выключение.
- `Microsoft-Windows-Kernel-PnP` 219/411/442 — устройство не стартовало/сброшено.
- `Microsoft-Windows-Kernel-Processor-Power` 37 — прошивка ограничивает частоту CPU.
- WER `P1=141` — VIDEO_ENGINE_TIMEOUT_DETECTED, `P1=117` — VIDEO_TDR_TIMEOUT_DETECTED.

## Правки и их GUID

| Настройка | GUID подгруппы | GUID параметра |
|---|---|---|
| PCIe ASPM | `501a4d13-42af-4429-9fd1-a8218c268e20` | `ee12f906-d277-404b-b6da-e5fa1a576df5` |
| Отключение экрана | `7516b95f-f776-4464-8c53-06167f40cc99` | `3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e` |
| USB selective suspend | `2a737441-1930-4402-8d77-b2bebba308a3` | `48e6b7a6-50f5-4782-a5d4-53bb8f07e226` |
| Сон | `238c9fa8-0aad-41ed-83f4-97be242c8f20` | `29f6c1db-86da-48c5-9fdb-f2b67b1f44da` |

Алиасы (`SUB_USB`, `USBSELECTIVESUSPEND`) на части сборок Windows не поддерживаются —
поэтому используются GUID.

Реестр: `HiberbootEnabled` (Session Manager\Power), `TdrDelay`, `TdrDdiDelay`, `TdrLevel`
(GraphicsDrivers).

## Фоновая запись

`-Mode Watch` — бесконечный цикл с шагом 5 с:

1. `nvidia-smi` → строка в `gpu-watch.csv`: температура, загрузка, потребление,
   частоты, pstate, троттлинг, **режим линии PCIe (gen/width)**, число мониторов
   (раз в 30 с) и заголовок активного окна.
2. `Win32_PerfFormattedData_Counters_ProcessorInformation` + ACPI thermal → `thermal.csv`.
3. Раз в 30 с — `Get-WinEvent` по `RecordId > state.json:lastRecordId`; новые события
   пишутся в `events.log` с контекстом GPU/CPU/PCIe.
4. Остановка — по файлу `stop.flag`; задача планировщика снимается пунктом меню `4`/`6`.

Если набор колонок изменился (например, после обновления версии), старый
`gpu-watch.csv` не удаляется, а переименовывается в `gpu-watch-<таймстамп>.csv`
и попадает в финальный ZIP; в `events.log` остаётся отметка `log format changed`.

Задача запускает не распакованную папку, а постоянную копию
`%LOCALAPPDATA%\GPU-Diag\engine\GPU-Diag.ps1` (её делает `Install-Engine` при включении
записи). Поэтому перезагрузка, перенос и замена папки запись не ломают; копия с меньшей
версией поверх большей не ставится (`Get-ScriptVersion`).

## Русский вывод (`ACTION-RU.txt`)

`New-RuAdviceText` переводит те же `FINDINGS`, что попадают в `report.txt`, в текст для
владельца ПК: главная причина, находки по важности, пронумерованные шаги, что уже сделано
автоматически, состояние фоновой записи, чего не делать, что отправить обратно.

Соответствие «английская находка → русский текст и шаг» задаётся в `Get-RuFinding` по
устойчивым фрагментам англоязычных строк. **Если меняешь текст `Finding ...` в отчёте,
проверь `Get-RuFinding`** — иначе находка попадёт в русский файл как
«Техническая находка (см. report.txt)».

## Правила по сбоям экрана (с 1.5)

Если в журнале есть TDR (`Display`/`nvlddmkm`, 4101/4102/4103) или WER `P1=141/117`:

- первая дата сбоя сравнивается с датой самого свежего пакета GPU-драйвера в DriverStore:
  сбой после установки → находка «драйвер — главный подозреваемый»;
- `HwSchMode = 2` → подсказка выключить HAGS;
- `OverlayTestMode` не задан или не `5` → подсказка про MPO;
- активная герцовка выше 60 Гц → дешёвый тест кабеля/полосы.

Всё это только текст в `FINDINGS`/`ACTION-RU.txt`: инструмент сам HAGS, MPO и герцовку
не меняет. Если меняешь формулировки — синхронизируй `Get-RuFinding`.

## Самопроверка

`-Mode SelfTest` — единственный режим, который меняет систему и в том же прогоне
возвращает всё назад. Используется для регрессионной проверки после правок скрипта:

| Блок | Проверяет |
|---|---|
| правки | ASPM, экран, USB, Fast Startup, TdrDelay/TdrDdiDelay применились |
| откат | значения совпадают со снимком «до» |
| планировщик | регистрация и удаление тестовой задачи |
| журнал | `wevtutil epl System` отдаёт файл |
| упаковка | `Compress-Archive` создаёт архив |

Результат — `selftest.log` рядом со скриптом и строка `RESULT: PASS|FAIL`.
