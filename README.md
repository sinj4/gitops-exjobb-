# GitOps-exjobb: upptäcker Argo CD ändringar som görs förbi Git?

Testmiljö och mätskript till examensarbetet. k3s + Argo CD, en app, fem manuella ändringar.

## Innehåll

| Fil | Vad den gör |
|---|---|
| `manifests/` | Appen som Argo CD hanterar: Deployment, Service, NetworkPolicy |
| `argocd/application.yaml` | Application-objektet, automatisk synk med `prune` och `selfHeal` |
| `01-setup.sh` | Installerar k3s och Argo CD och skapar appen |
| `02-kor-tester.sh` | Kör testerna och loggar till `resultat/resultat.csv` |
| `03-sammanstall.py` | Räknar ihop rådata till tabeller |

## Krav

Linux med sudo, minst 2 kärnor och 4 GB ledigt minne. På Windows: WSL2 (Ubuntu) med systemd påslaget, eller en virtuell maskin. Internetåtkomst.

## Så kör du

1. Skapa ett **publikt** repo på GitHub, t.ex. `gitops-exjobb`, och pusha hela den här mappen dit.
2. Sätt upp miljön (cirka 10 minuter):

   ```bash
   REPO_URL=https://github.com/<användare>/gitops-exjobb.git ./01-setup.sh
   ```

3. Kör testerna. Låt datorn stå, stäng inte locket:

   ```bash
   ./02-kor-tester.sh            # 10 körningar per test, räkna med 2 till 3 timmar
   RUNS=5 ./02-kor-tester.sh     # snabbare, cirka 1 till 1,5 timme
   ```

4. Sammanställ:

   ```bash
   ./03-sammanstall.py
   ```

Resultatet hamnar i `resultat/`: `resultat.csv` (rådata), `versioner.txt` (versioner och inställningar) och `sammanstallning.txt` (tabeller).

## Testerna

| Test | Ändring | Kommando |
|---|---|---|
| T1 | Byta image i Deployment | `kubectl set image` |
| T2 | Ta bort NetworkPolicy | `kubectl delete networkpolicy` |
| T3 | Lägga till extra container | `kubectl patch` |
| T4 | Skapa pod som inte finns i Git | `kubectl run` |
| T5 | Ändra fil i körande container | `kubectl exec` |

Serie A kör varje test `RUNS` gånger och återskapar Application-objektet före varje körning.
Serie B upprepar T1 sex gånger i rad utan att återskapa, för att se hur återställningstiden utvecklas.

## Om något strular

- **Appen blir inte Synced:** kontrollera att repot är publikt och att `REPO_URL` slutar på `.git`.
- **Börja om från början:** `/usr/local/bin/k3s-uninstall.sh` tar bort k3s och allt i klustret.
- **Avbruten körning:** starta om `02-kor-tester.sh`. Den gamla CSV-filen sparas med tidsstämpel.
