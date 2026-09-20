# step NAME COMMAND... : runs a step, records PASS/FAIL and seconds.
RESULTS="$(dirname "${BASH_SOURCE[0]}")/results.tsv"
step() {
  local name=$1; shift
  local start=$EPOCHREALTIME out st
  if out=$("$@" 2>&1); then st=PASS; else st=FAIL; fi
  local ms=$(( (${EPOCHREALTIME/./} - ${start/./}) / 1000 ))
  printf '%s\t%s\t%d.%01ds\t%s\n' "$st" "$name" $((ms/1000)) $(((ms%1000)/100)) "$(echo "$out" | tail -1 | cut -c1-160)" | tee -a "$RESULTS"
  [ $st = PASS ]
}
