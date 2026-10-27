#!/usr/bin/env bash
# audit-quick-classify-awk-lexer-lib.sh: the first fragment of the quick
# classifier's awk line program: trim, load and the TSX lexer. Sourced by
# audit-quick-classify-lib.sh; holds only awk text, and the lines stage joins
# the fragments, in order, into the one program.
# shellcheck disable=SC2034
IFS= read -r -d '' _QUICK_AWK_LEXER <<'AWK' || true
function trim(x) { sub(/^[ \t]+/, "", x); sub(/[ \t]+$/, "", x); return x }
function load(s, file,   line, n, r) {
  n = 0
  while ((r = (getline line < file)) > 0) { n++; sub(/\r$/, "", line); raw[s, n] = line }
  if (r < 0) failed = 1
  close(file)
  nlines[s] = n
}

# ---- TSX lexer -------------------------------------------------------------
function emit(x) { if (capdepth > 0) capbuf = capbuf x; else kbuf = kbuf x }
function cvadd(x) { cvbuf = cvbuf x }
function addseg(type, name, value,   n) {
  if (type != "K") flushK()
  n = ++segn[CS, CL]; sgt[CS, CL, n] = type; sgn[CS, CL, n] = name; sgv[CS, CL, n] = value
}
function flushK() { if (kbuf ~ /[^ \t]/) { addseg("K", "", trim(kbuf)) } kbuf = "" }
# Text inside these elements is code or markup to the browser, not copy.
function flushT() {
  if (tbuf ~ /[^ \t]/) {
    addseg("T", "", trim(tbuf)); hastext[CS, CL] = 1
    if (depth > 0 && fname[depth] ~ /^(script|style|noscript|iframe|object|template)$/) textunsafe[CS, CL] = 1
  }
  tbuf = ""
}
function cnmark(x) { if (depth > 0 && ft[depth] == "paren" && fname[depth] == "cn") fbuf[depth] = fbuf[depth] x }
function pushf(type, name,   p) {
  p = depth
  if (p > 0 && ft[p] == "paren" && fname[p] == "cn") fbuf[p] = fbuf[p] "N"
  depth++; frameseq++
  ft[depth] = type; fname[depth] = name; fline[depth] = CL; fid[depth] = frameseq
  fprop[depth] = ""; fattr[depth] = ""; fbuf[depth] = ""; fstory[depth] = ""; fsusp[depth] = 0
  if (type == "attrexpr") fsig[CS, frameseq] = ""
  if (type == "paren" && name == "cva") { cvadepth++; cvaany[CS, CL] = 1 }
  if (type == "paren" && name == "cn") { cndepth++; cnopen[CS, CL]++ }
  if (type == "brace" && p == 0 && pendstory != "" && prev == "=") { fstory[depth] = "story:" pendstory; pendstory = ""; pendstate = 0 }
  if (type == "brace" && p > 0 && fstory[p] ~ /^story:/ && fprop[p] == "args") fstory[depth] = "args"
}
function popf(   b) {
  if (ft[depth] == "paren" && fname[depth] == "cva") cvadepth--
  if (ft[depth] == "paren" && fname[depth] == "cn") {
    cndepth--
    b = fbuf[depth]
    cnstatic[CS, fid[depth]] = (b ~ /^Q(,Q)*,?$/) ? 1 : 0
    cnargs[CS, fid[depth]] = gsub(/Q/, "Q", b)
  }
  if (ft[depth] == "attrexpr") admitted[CS, fid[depth]] = (fsig[CS, fid[depth]] ~ /^(<C|\(<C\))$/) ? 1 : 0
  depth--
}
AWK
