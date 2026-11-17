#!/usr/bin/env bash
# Połowa UTWARDZONA: schodki 10..80% (ten sam offered load co w trybie podatnym).
set -u
SP="/c/Users/kubal/AppData/Local/Temp/claude/5e5918a8413307bf/f6fdd80f-03f5-4b24-af5e-60f3345b4710/scratchpad"
R="$SP/runseg.sh"
DUR=30; G=8
bash "$R" hard_10 hard 10 4  $DUR; sleep $G
bash "$R" hard_20 hard 20 10 $DUR; sleep $G
bash "$R" hard_40 hard 40 25 $DUR; sleep $G
bash "$R" hard_55 hard 55 35 $DUR; sleep $G
bash "$R" hard_80 hard 80 50 $DUR
echo HALF2DONE > "$SP/half2.done"
