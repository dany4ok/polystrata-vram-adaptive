# PolyStrata — adaptare VRAM „la cerere"

Scripturi + configuri pentru un server local PolyStrata/llama.cpp care:

- **nu ține modelul în VRAM când nu e folosit** (pornește gol, se descarcă singur după inactivitate);
- **la primul review folosește toată puterea GPU-ului** (încărcare completă, fără `--no-gpu-experts`);
- **când e deschis un joc, trece în RAM + SSD** (`--no-gpu-experts`), deci jocul păstrează VRAM-ul, iar modelul rămâne apelabil.

Nu e nevoie ca modelul să fie „tot timpul pornit". Clientul primește răspuns și după un cold-start de ~15 s.

## Stări

| Situație | Config folosit | Ce se întâmplă |
|---|---|---|
| Pornire, fără joc | `strata-minicpmv-q4_k_m-review.json` | Serverul e sus în ~5 s, **modelul nu e încărcat**, VRAM ~14,8 GB liber |
| Sosește o cerere | același | Modelul se încarcă în VRAM, răspunde, apoi se descarcă după 60 s de inactivitate |
| Joc detectat (~4 s) | `strata-minicpmv-q4_k_m-cpu.json` | Serverul se repornește cu **0 experți în VRAM**; jocul are ~13 GB rezervați; modelul răspunde în ~1–2 s din RAM/SSD |
| Joc închis | revine la configul de review | Repornire rapidă (modelul nu se încarcă până la prima cerere) |

## Fișiere

| Fișier | Rol |
|---|---|
| `run-minicpmv-q4_k_m-auto.bat` | Launcher. Pornește paznicul în consolă vizibilă; **nu deschide browserul**. Închiderea ferestrei oprește și serverul. |
| `serve/vram-guard.ps1` | Paznicul: detectează jocul prin `nvidia-smi`, comută configul, eliberează portul 8080, afișează statusul în consolă. |
| `strata-minicpmv-q4_k_m-review.json` | Config „rapid": GPU complet, `lazy_load`, `idle_unload_s=60`, `min_free_vram_mib=5000`. |
| `strata-minicpmv-q4_k_m-cpu.json` | Config „joc": `--no-gpu-experts`, `--vram-reserve-mib 13000`, `vision.gpu=false`, `lazy_load`, `idle_unload_s=60`. |

## Instalare pe o altă mașină

1. Copiază cele 4 fișiere în rădăcina instalării Poly-strata (păstrează `serve/vram-guard.ps1` în `serve\`).
2. Editează căile absolute din ambele `.json` (`exe`, `model`, `mmproj`, `expert-profile`, `tokenizer`, `log`, `lib_dirs`) și din `.bat` (calea către Python și `serve\server.py`).
3. Creează o scurtătură pe desktop către `.bat`.
4. Nu modifica scriptul original `run-minicpmv-q4_k_m.bat` și nici configul lui — adaptarea e separată.

## Setări care contează

| Setare | Valoare | De ce |
|---|---|---|
| `lazy_load: true` | ambele configuri | Serverul pornește fără model; VRAM-ul e liber imediat |
| `idle_unload_s: 60` | ambele configuri | După 60 s fără cereri, modelul iese din VRAM/RAM |
| `min_free_vram_mib: 5000` | config review | Dacă detectarea jocului eșuează, refuză încărcarea în loc să sufoce jocul |
| `--no-gpu-experts` | doar config joc | Toți experții rămân în RAM/SSD; 0 în VRAM |
| `--vram-reserve-mib 13000` | doar config joc | Lasă ~13 GB VRAM pentru joc |
| `PollSeconds=2`, `PersistPolls=2` | paznic | Detectare în ~4 s; filtrează procesele tranzitorii |
| `Wait-Idle 5` | paznic | Așteaptă maximum 5 s ca o cerere în curs să se termine înainte de comutare |
| `$NeverGame` | paznic | Procese GPU care nu sunt joc (Windows, Steam, Game Bar, browsere). Adaugă aici orice aplicație dă detectare falsă. |

## Cum se adaptează la alt model

1. Pornește de la configul care funcționează deja pentru modelul ăla (cel original din Poly-strata).
2. Copiază-l în `strata-<model>-review.json` și adaugă: `lazy_load: true`, `idle_unload_s: 60`, `min_free_vram_mib` (cu cât e mai mare jocul, cu atât mai mare valoarea).
3. Copiază-l în `strata-<model>-cpu.json`, adaugă `--no-gpu-experts`, `--vram-reserve-mib <aproape toată VRAM>`, `vision.gpu: false`, `lazy_load`, `idle_unload_s`.
4. În `vram-guard.ps1`, schimbă `$FastCfg` și `$GameCfg` cu noile fișiere.
5. Verifică că engine-ul acceptă flag-urile (`--no-gpu-experts` există în `strata-poly --help`); unele motoare vechi nu le au.
6. Reglează `$NeverGame` pentru procesele specifice mașinii.

> Observație: acest engine (**strata-poly**) nu are `-ngl`, `--vram-elastic` sau mod CPU pur. Nu se poate muta modelul „live" între VRAM și RAM; singura cale e repornirea serverului cu alt config. Paznicul face exact asta.

## Depanare

- **`port 8080 is already in use`** — paznicul eliberează automat portul la fiecare pornire (`Free-Port`); dacă tot persistă, verifică manual procesele Python rămase.
- **Jocul rămâne la 3 fps** — înseamnă că modelul e încă în VRAM. Verifică în log: trebuie să apară `trecere in modul joc` și în logul engine-ului `0 of 10240 routed experts in VRAM`.
- **Detectare falsă** (ex. se comută când deschizi un browser) — adaugă numele procesului în `$NeverGame`.
- **Răspuns gol la „salut"** — nu e o problemă a acestei adaptări. MiniCPM-V 4.7 e model reasoning: generează întâi un bloc `` și uneori emite tokenul de stop încă înăuntrul gândirii, fără răspuns final (issue #1053 în PolyStrata). Serverul are `reasoning_close_retry`, dar e opt-in. Un `max_tokens` mai mare sau `reasoning_effort: low` reduce problema. Nu am modificat nimic în această direcție.

## Ce nu a fost schimbat

`run-minicpmv-q4_k_m.bat` original și `strata-minicpmv-q4_k_m.json` original rămân intacte. Adaptarea e complet separată și poate fi ștearsă fără să afecteze instalarea.

## Verificare

Fluxul a fost testat live: pornire cu model neîncărcat (VRAM ~14,8 GB liber), cerere care încarcă modelul la ~15,5 GB și răspunde, descărcare automată după 70 s inactiv, config de joc cu 0 experți în VRAM, ciclu închidere→redeschidere fără servere orfane. Review independent: ✓ Verified.
