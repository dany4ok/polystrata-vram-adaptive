@echo off
title PolyStrata minicpmv-Q4_K_M (la cerere)
cd /d "C:\Users\x1p\Desktop\Poly-strata"

echo Pornesc PolyStrata (la cerere, fara browser)...
rem Modelul NU se incarca la pornire. Se incarca la prima cerere, la capacitate
rem GPU completa, si se descarca singur dupa 60 s de inactivitate.
rem Daca e joc deschis, serverul trece in mod RAM/SSD (0 experti in VRAM),
rem ca jocul sa aiba toata VRAM-ul; modelul ramanand apelabil.
rem Inchiderea acestei ferestre opreste si serverul.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Users\x1p\Desktop\Poly-strata\serve\vram-guard.ps1" -Port 8080
