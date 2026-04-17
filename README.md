# VoltCast

VoltCast is a smart-grid demo for intelligent load shifting. It predicts hourly renewable availability from weather inputs, then schedules flexible high-power loads into cleaner and lower-stress grid windows.

## What Is Included

- A browser UI for entering site details, weather mode, and heavy-load appliances.
- A local API server with `GET /api/health`, `GET /api/forecast`, and `POST /api/optimize`.
- A scheduling engine that compares usual appliance timing against an optimized demand-response schedule.
- A demo forecast model plus optional Open-Meteo weather API support.

## Run

This project uses Windows PowerShell and does not require Python, Node, or package installation.

```powershell
powershell -ExecutionPolicy Bypass -File .\server.ps1
```

Open:

```text
http://localhost:8787
```

Use another port if needed:

```powershell
powershell -ExecutionPolicy Bypass -File .\server.ps1 -Port 8790
```

## Pitch Notes

Frame the project as a demand-response AI assistant for renewable-rich smart grids. The dashboard highlights grid-energy reduction, renewable utilization, peak-load reduction, and carbon savings, which maps cleanly to EEE topics such as the duck curve, smart metering, and microgrid optimization.
