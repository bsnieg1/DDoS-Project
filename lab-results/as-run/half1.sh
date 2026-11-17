#!/usr/bin/env bash
# Połowa PODATNA: baseline + schodki 10..80% + autentyczny Rapid Reset (bot).
set -u
SP="/c/Users/kubal/AppData/Local/Temp/claude/5e5918a8413307bf/f6fdd80f-03f5-4b24-af5e-60f3345b4710/scratchpad"
R="$SP/runseg.sh"
DUR=30; G=8
bash "$R" baseline vuln idle idle 20; sleep $G
bash "$R" vuln_10 vuln 10 4  $DUR; sleep $G
bash "$R" vuln_20 vuln 20 10 $DUR; sleep $G
bash "$R" vuln_40 vuln 40 25 $DUR; sleep $G
bash "$R" vuln_55 vuln 55 35 $DUR; sleep $G
bash "$R" vuln_80 vuln 80 50 $DUR; sleep $G
bash "$R" vuln_rr vuln rr bot 40
echo HALF1DONE > "$SP/half1.done"
