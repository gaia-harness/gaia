#!/usr/bin/env bash
# audit-quick-classify-awk-main-lib.sh: the last fragment of the quick
# classifier's awk line program: story lines, language files, BEGIN and
# END. Sourced by audit-quick-classify-lib.sh; holds only awk text, and the
# lines stage joins the fragments, in order, into the one program.
# shellcheck disable=SC2034
IFS= read -r -d '' _QUICK_AWK_MAIN <<'AWK' || true
# ---- story lines -----------------------------------------------------------
function eval_story(i,   s, o, L, t, c, cat, r, key) {
  s = chs[i]; L = chl[i]; o = (s == "pre") ? "post" : "pre"
  t = raw[s, L]
  cat = category(s, L)
  if (cat == "blank") return ""
  r = lexical_reason(s, L, t); if (r != "") return r
  c = (cat == "err") ? t : cv[s, L]
  r = generic_reason(c); if (r != "") return r
  if (c ~ PLAYWORDS || index(c, "within(") > 0 || playany[s, L]) return "quick-story-play"
  if (cat == "err") return "quick-story-shape"
  if (argsdirect0[s, L] && d1[s, L] == d0[s, L] && t ~ ARGLINE) {
    key = t; sub(/^[ \t]*/, "", key); sub(/[ \t]*:.*$/, "", key)
    if ((o, story0[s, L], key) in argskey) return ""
    return "quick-story-shape"
  }
  if (storytop0[s, L] && d1[s, L] == d0[s, L] && t ~ ARGINLINE) {
    if (((o, story0[s, L]) in argsinline) && argsinline[o, story0[s, L]] == argsinline[s, story0[s, L]]) return ""
    return "quick-story-shape"
  }
  return "quick-story-shape"
}

# ---- language files ----------------------------------------------------------
function key_text(k) { if (k ~ /^'/) return substr(k, 2, length(k) - 2); return k }
function key_path(n, last,   k, out) {
  out = ""
  for (k = 1; k <= n; k++) out = out lkeystack[k] "\036"
  return out last
}
function lang_record(s, L, kind, K, value) {
  lkind[s, L] = kind
  if (K == "") return
  lkey[s, L] = K
  if (kind == "value" || kind == "wrapvalue") {
    if ((s, K) in lhas) { lerr[s] = 1; return }
    lhas[s, K] = 1; lval[s, K] = value
  }
}
function langparse(s,   L, t, d, root, closed, wrap, wrapkey, k, v, K) {
  d = 0; root = 0; closed = 0; wrap = 0
  for (L = 1; L <= nlines[s]; L++) {
    t = raw[s, L]
    if (t ~ /^[ \t]*$/) { lkind[s, L] = "blank"; if (wrap) lerr[s] = 1; continue }
    if (wrap) {
      if (t ~ /^[ \t]*'[^'\\]*',[ \t]*$/) {
        v = t; sub(/^[ \t]*'/, "", v); sub(/',[ \t]*$/, "", v)
        lang_record(s, L, "wrapvalue", wrapkey, v); wrap = 0; continue
      }
      lerr[s] = 1; lkind[s, L] = "other"; wrap = 0; continue
    }
    if (closed) { lerr[s] = 1; lkind[s, L] = "other"; continue }
    if (t ~ /^[ \t]*\/\//) { lkind[s, L] = "comment"; continue }
    if (d == 0) {
      if (!root && t ~ /^export default \{[ \t]*$/) { root = 1; d = 1; lkind[s, L] = "root"; continue }
      lerr[s] = 1; lkind[s, L] = "other"; continue
    }
    if (t ~ ("^[ \t]*" LKEY ":[ \t]*'[^'\\\\]*',[ \t]*$")) {
      k = t; sub(/^[ \t]*/, "", k); match(k, "^" LKEY); k = key_text(substr(k, 1, RLENGTH))
      v = t; sub(/^[^']*'/, "", v); if (t ~ /^[ \t]*'/) { v = t; sub(/^[ \t]*'[^']*'[ \t]*:[ \t]*'/, "", v) }
      sub(/',[ \t]*$/, "", v)
      lang_record(s, L, "value", key_path(d - 1, k), v); continue
    }
    if (t ~ ("^[ \t]*" LKEY ":[ \t]*$")) {
      k = t; sub(/^[ \t]*/, "", k); match(k, "^" LKEY); k = key_text(substr(k, 1, RLENGTH))
      wrapkey = key_path(d - 1, k); wrap = 1; lang_record(s, L, "wrapkey", wrapkey, ""); continue
    }
    if (t ~ ("^[ \t]*" LKEY ":[ \t]*\\{[ \t]*$")) {
      k = t; sub(/^[ \t]*/, "", k); match(k, "^" LKEY); k = key_text(substr(k, 1, RLENGTH))
      lang_record(s, L, "open", key_path(d - 1, k), ""); lkeystack[d] = k; d++; continue
    }
    if (d > 1 && t ~ /^[ \t]*\},[ \t]*$/) { d--; lang_record(s, L, "close", key_path(d - 1, lkeystack[d]), ""); continue }
    if (d == 1 && t ~ /^\}( as const)?;[ \t]*$/) { d = 0; closed = 1; lkind[s, L] = "root"; continue }
    lerr[s] = 1; lkind[s, L] = "other"
  }
  if (d != 0 || !closed || wrap) lerr[s] = 1
}
function sorted_matches(v, re,   n, list, k, m, x, out) {
  n = 0
  while (match(v, re)) { list[++n] = substr(v, RSTART, RLENGTH); v = substr(v, RSTART + RLENGTH) }
  for (k = 2; k <= n; k++) { x = list[k]; m = k - 1; while (m >= 1 && list[m] > x) { list[m + 1] = list[m]; m-- } list[m + 1] = x }
  out = ""
  for (k = 1; k <= n; k++) out = out "\034" list[k]
  return out
}
function eval_lang(i,   s, o, L, t, c, r, kind, K, oldv, newv, loc) {
  s = chs[i]; L = chl[i]; o = (s == "pre") ? "post" : "pre"
  t = raw[s, L]
  kind = lkind[s, L]
  if (t ~ /^[ \t]*$/ && !lerr[s]) return ""
  r = lexical_reason(s, L, t); if (r != "") return r
  c = t; gsub(/'[^']*'/, "''", c)
  r = generic_reason(c); if (r != "") return r
  if (lerr[s] || lerr[o]) return "quick-language-shape"
  if (kind == "open" || kind == "close") return "quick-language-key"
  if (kind != "value" && kind != "wrapvalue" && kind != "wrapkey") return "quick-language-shape"
  K = lkey[s, L]
  if (!((o, K) in lhas)) return "quick-language-key"
  if (s == "pre" && (K in postchangedkey)) return ""
  oldv = lval["pre", K]; newv = lval["post", K]
  if (sorted_matches(oldv, "\\{\\{[^}]*\\}\\}") != sorted_matches(newv, "\\{\\{[^}]*\\}\\}")) return "quick-placeholder"
  if (sorted_matches(oldv, "\\$t\\([^)]*\\)") != sorted_matches(newv, "\\$t\\([^)]*\\)")) return "quick-nesting"
  if (index(oldv, "<") > 0 || index(newv, "<") > 0) return "quick-html"
  if (newv ~ /^[ \t]*$/) return "quick-empty-value"
  for (loc in sibloc) if (!((loc, K) in sibhas)) return "quick-locale-missing"
  return ""
}

BEGIN {
  LITERAL = "(\"[^\"\\\\`]*\"|'[^'\\\\`]*')"
  CNSTATIC = "^\\{[ \t]*cn\\([ \t]*" LITERAL "([ \t]*,[ \t]*" LITERAL ")*[ \t]*,?[ \t]*\\)[ \t]*\\}$"
  CNLITLINE = "^[ \t]*" LITERAL ",?[ \t]*$"
  STORYLIT = "('[^'\\\\`]*'|\"[^\"\\\\`]*\"|-?[0-9]+(\\.[0-9]+)?|true|false)"
  ARGLINE = "^[ \t]*[A-Za-z_$][A-Za-z0-9_$]*:[ \t]*" STORYLIT ",?[ \t]*$"
  ARGPAIR = "[A-Za-z_$][A-Za-z0-9_$]*:[ \t]*" STORYLIT
  ARGINLINE = "^[ \t]*args:[ \t]*\\{[ \t]*" ARGPAIR "([ \t]*,[ \t]*" ARGPAIR ")*[ \t]*,?[ \t]*\\},?[ \t]*$"
  PLAYWORDS = "(^|[^A-Za-z0-9_$])(play|expect|userEvent|waitFor|assert[A-Za-z0-9_$]*)([^A-Za-z0-9_$]|$)"
  PALETTE = "^(" paletteutilities ")(-[a-z]+)?-(" palettecolors ")(-[0-9]+)?(/.*)?$"
  LKEY = "([A-Za-z_$][A-Za-z0-9_$]*|'[^'\\\\]*')"
  if (mode == "keys") {
    load("pre", prefile)
    if (!failed) {
      langparse("pre")
      if (!lerr["pre"]) for (k in lhas) { split(k, kp, SUBSEP); print kp[2] }
    }
    exit
  }
  load("pre", prefile); load("post", postfile)
  if (class == "language") {
    langparse("pre"); langparse("post")
    while ((r = (getline sline < siblingfile)) > 0) {
      tab = index(sline, "\t")
      if (tab == 0) continue
      sloc = substr(sline, 1, tab - 1); skey = substr(sline, tab + 1)
      sibloc[sloc] = 1
      if (skey != "") sibhas[sloc, skey] = 1
    }
    if (r < 0) failed = 1
    close(siblingfile)
  } else {
    tokenize("pre"); tokenize("post")
    if (class != "story") {
      for (L = 1; L <= nlines["pre"]; L++) raw["npre", L] = raw["pre", L]
      for (L = 1; L <= nlines["post"]; L++) raw["npost", L] = raw["post", L]
      nlines["npre"] = nlines["pre"]; nlines["npost"] = nlines["post"]
      tokenize("npre"); tokenize("npost")
    }
  }
  started = 0; hunks = 0; nchg = 0
}
mode == "keys" { next }
/^@@ / {
  field = $2; sub(/^-/, "", field); split(field, parts, ","); prenext = parts[1] + 0
  field = $3; sub(/^\+/, "", field); split(field, parts, ","); postnext = parts[1] + 0
  hunks++; started = 1; next
}
/^Binary files / || /^GIT binary patch/ { binary = 1; next }
!started { next }
/^\\/ { next }
/^-/ { nchg++; chs[nchg] = "pre"; chl[nchg] = prenext++; chh[nchg] = hunks; next }
/^\+/ { nchg++; chs[nchg] = "post"; chl[nchg] = postnext++; chh[nchg] = hunks; next }
END {
  if (mode == "keys") exit
  if (failed) { print "ERROR"; exit }
  if (binary) { print "quick-unclassified\t-"; exit }
  for (i = 1; i <= nchg; i++) {
    if (chl[i] < 1 || chl[i] > nlines[chs[i]]) { print "ERROR"; exit }
    changed[chs[i], chl[i]] = 1
  }
  if (class == "language") {
    for (i = 1; i <= nchg; i++) if (chs[i] == "post" && (("post", chl[i]) in lkey)) postchangedkey[lkey["post", chl[i]]] = 1
    for (i = 1; i <= nchg; i++) { r = eval_lang(i); if (r != "") { print r "\t" chs[i] ":" chl[i]; exit } }
    print "ok"; exit
  }
  # Pairing runs once per pass: P is "" for the base pass and "n" for the nested
  # one, each pairing by its own categories.
  for (pass = 1; pass <= (class == "story" ? 1 : 2); pass++) {
    P = (pass == 1) ? "" : "n"
    for (i = 1; i <= nchg; i++) {
      s = P chs[i]; L = chl[i]
      if (hastext[s, L]) { if (chs[i] == "pre") hunkdeltext[P, chh[i]] = 1; else hunkaddtext[P, chh[i]] = 1 }
      cat = category(s, L)
      if (cat != "struct" && cat != "cnlit") continue
      key = P SUBSEP chh[i] SUBSEP cat
      if (chs[i] == "pre") { dn[key]++; position[P, i] = dn[key]; delq[key, dn[key]] = i }
      else { an[key]++; position[P, i] = an[key]; addq[key, an[key]] = i }
    }
    for (i = 1; i <= nchg; i++) {
      if (!((P, i) in position)) continue
      key = P SUBSEP chh[i] SUBSEP category(P chs[i], chl[i])
      if (chs[i] == "pre" && ((key, position[P, i]) in addq)) pairof[P, i] = addq[key, position[P, i]]
      if (chs[i] == "post" && ((key, position[P, i]) in delq)) pairof[P, i] = delq[key, position[P, i]]
    }
  }
  for (i = 1; i <= nchg; i++) {
    r = (class == "story") ? eval_story(i) : eval_tsx(i, nested_line(i) ? "n" : "")
    if (r != "") { print r "\t" chs[i] ":" chl[i]; exit }
  }
  print "ok"
}
AWK
