#!/usr/bin/env bash
# audit-quick-classify-awk-helpers-lib.sh: the third fragment of the quick
# classifier's awk line program: the TSX line helpers. Sourced by
# audit-quick-classify-lib.sh; holds only awk text, and the lines stage joins
# the fragments, in order, into the one program.
# shellcheck disable=SC2034
IFS= read -r -d '' _QUICK_AWK_HELPERS <<'AWK' || true
# ---- TSX line helpers ------------------------------------------------------
function intrinsic(nm) { return nm ~ /^[a-z][a-z0-9]*$/ }
function has_nonintrinsic(tl,   n, parts, k, nm) {
  n = split(tl, parts, " ")
  for (k = 1; k <= n; k++) { if (parts[k] == "") continue; nm = substr(parts[k], 3); if (!intrinsic(nm)) return 1 }
  return 0
}
function swappable(nm) { return nm == "div" || nm == "span" || nm == "p" }
function tags_compatible(a, b,   na, nb, pa, pb, k, x, y) {
  na = split(a, pa, " "); nb = split(b, pb, " ")
  if (na != nb) return 0
  for (k = 1; k <= na; k++) {
    if (substr(pa[k], 1, 2) != substr(pb[k], 1, 2)) return 0
    x = substr(pa[k], 3); y = substr(pb[k], 3)
    if (x != y && !(swappable(x) && swappable(y))) return 0
  }
  return 1
}
function is_classname(s, L, k) { return (sgt[s, L, k] == "A" || sgt[s, L, k] == "A~") && sgn[s, L, k] == "className" }
function class_kind(v) {
  if (v ~ /^("[^"\\`]*"|'[^'\\`]*')$/) return "s"
  if (v ~ CNSTATIC) return "cn" gsub(LITERAL, "&", v)
  return "x"
}
function other_attrs(s, L,   k, out) {
  out = ""
  for (k = 1; k <= segn[s, L]; k++)
    if ((sgt[s, L, k] == "A" || sgt[s, L, k] == "A~") && sgn[s, L, k] != "className") out = out "\034" sgn[s, L, k] "=" sgv[s, L, k]
  return out
}
function class_sig(s, L,   k, out, kind) {
  out = ""
  for (k = 1; k <= segn[s, L]; k++) if (is_classname(s, L, k)) {
    kind = (sgt[s, L, k] == "A~") ? "x" : class_kind(sgv[s, L, k])
    out = out "\034" (kind == "x" ? "x:" sgv[s, L, k] : kind)
  }
  return out
}
function static_cn_count(s, L,   k, n) {
  n = 0
  for (k = 1; k <= segn[s, L]; k++) if (is_classname(s, L, k) && sgt[s, L, k] == "A" && sgv[s, L, k] ~ CNSTATIC) n++
  return n
}
function skeleton(s, L,   k, out, t, nm) {
  out = ""
  for (k = 1; k <= segn[s, L]; k++) {
    t = sgt[s, L, k]; nm = sgn[s, L, k]
    if (t == "T") continue
    if (is_classname(s, L, k)) continue
    if ((t == "O" || t == "C") && swappable(nm)) nm = "~"
    out = out "\034" t "\035" nm "\035" sgv[s, L, k]
  }
  return out
}
function add_tokens(str, set,   n, parts, k) {
  n = split(str, parts, /[ \t]+/)
  for (k = 1; k <= n; k++) if (parts[k] != "") set[parts[k]] = 1
}
function literal_tokens(v, set,   x) {
  while (match(v, LITERAL)) { x = substr(v, RSTART + 1, RLENGTH - 2); add_tokens(x, set); v = substr(v, RSTART + RLENGTH) }
}
function line_tokens(s, L, set, cat,   k) {
  if (cat == "cnlit") { literal_tokens(raw[s, L], set); return }
  for (k = 1; k <= segn[s, L]; k++) if (is_classname(s, L, k) && sgt[s, L, k] == "A") literal_tokens(sgv[s, L, k], set)
}
function class_nonascii(s, L, cat,   k) {
  if (cat == "cnlit") return raw[s, L] ~ nonascii
  for (k = 1; k <= segn[s, L]; k++) if (is_classname(s, L, k) && sgv[s, L, k] ~ nonascii) return 1
  return 0
}
function token_split(tok,   i, ch, d, last) {
  d = 0; last = 0
  for (i = 1; i <= length(tok); i++) {
    ch = substr(tok, i, 1)
    if (ch == "[") d++
    else if (ch == "]") d--
    else if (ch == ":" && d == 0) last = i
  }
  tokprefix = substr(tok, 1, last); tokbase = substr(tok, last + 1)
  sub(/^!/, "", tokbase); sub(/!$/, "", tokbase); sub(/^-/, "", tokbase)
}
function is_hiding(tok) { token_split(tok); if (tokprefix ~ /focus/) return 1; return index(" " hidingset " ", " " tokbase " ") > 0 }
function is_motion(tok) { token_split(tok); return tokbase ~ /^animate-/ || tokbase ~ /^order-/ || tokbase ~ /-reverse$/ || tokbase ~ /^(col|row)-(start|end)-/ }
function is_palette(tok) { token_split(tok); return tokbase ~ PALETTE }
function is_arbitrary(tok) { token_split(tok); return index(tokbase, "[") > 0 || tokbase ~ /^content-/ }
# own: tokens on this side's line that the paired line lacks.
function token_reason(s, L, cat, j, Lj, o,   mine, theirs, tok) {
  split("", mine); split("", theirs)
  line_tokens(s, L, mine, cat)
  if (j) line_tokens(o, Lj, theirs, category(o, Lj))
  for (tok in mine) if (!(tok in theirs) && is_hiding(tok)) return "quick-hiding-token"
  for (tok in mine) if (!(tok in theirs) && is_motion(tok)) return "quick-motion-order-token"
  if (s ~ /post$/) for (tok in mine) if (!(tok in theirs) && is_palette(tok)) return "quick-palette"
  for (tok in mine) if (!(tok in theirs) && is_arbitrary(tok)) return "quick-arbitrary-value"
  return ""
}
function only_text(s, L,   k) {
  if (segn[s, L] == 0) return 0
  for (k = 1; k <= segn[s, L]; k++) if (sgt[s, L, k] != "T") return 0
  return 1
}
function category(s, L,   x) {
  if ((s, L) in catcache) return catcache[s, L]
  x = ctx0[s, L]
  if (err[s]) x = "err"
  else if (raw[s, L] ~ /^[ \t]*$/ && (x == "CODE" || x == "JSXCHILD" || x == "JSXTAG")) x = "blank"
  else if (x == "CODE" && cnframe0[s, L] && d1[s, L] == d0[s, L] && raw[s, L] ~ CNLITLINE) x = "cnlit"
  else if (x == "JSXCHILD" && d1[s, L] == d0[s, L] && only_text(s, L)) x = "text"
  else if (x == "CODE" || x == "JSXCHILD" || x == "JSXTAG") x = "struct"
  else x = "other"
  catcache[s, L] = x
  return x
}
function generic_reason(c) {
  if (c ~ /^[ \t]*(import|export)([^A-Za-z0-9_$]|$)/ || c ~ /(^|[^A-Za-z0-9_$.])(import|require)[ \t]*\(/) return "quick-import"
  if (c ~ /(^|[^A-Za-z0-9_$])use[A-Z][A-Za-z0-9_$]*[ \t]*(<[^()]*>)?[ \t]*\(/) return "quick-hook"
  if (c ~ /(^|[^A-Za-z0-9_$])on[A-Z][A-Za-z0-9_$]*[ \t]*=/) return "quick-handler"
  if (index(c, "...") > 0) return "quick-spread"
  if (c ~ /&&|\|\||\?|=>/) return "quick-conditional"
  if (c ~ /\.(map|filter|flatMap|forEach|reduce)[ \t]*\(/) return "quick-map"
  return ""
}
function lexical_reason(s, L, t) {
  if (t ~ bidi) return "quick-codepoint"
  if (index(t, "/*") > 0 || index(t, "*/") > 0 || ctx0[s, L] == "BLOCK") return "quick-block-comment"
  if (index(t, "`") > 0 || ctx0[s, L] == "TMPL") return "quick-template-literal"
  return ""
}
# A changed line reads the nested-element pass (side prefix n) only when it lies
# in an admitted element's own opening tag, or opens one, with every attribute
# expression on its frame stack admitted; every other line reads the base pass,
# the lexer without the nested reading, and gets exactly that pass's outcome.
function chain_ok(chain, s,   n, parts, k) {
  if (chain == "" || index(chain, "BAD") > 0) return 0
  n = split(chain, parts, " ")
  for (k = 1; k <= n; k++) if (parts[k] != "" && !admitted[s, parts[k]]) return 0
  return 1
}
# The base pass can fail an image the nested pass reads cleanly (it lexes a value
# like `<Button ... />` as code), so only the nested pass's own failure blocks
# it; every line outside it still reads the base pass and stays deep there.
function nested_line(i,   s, L) {
  if (err["npre"] || err["npost"]) return 0
  s = "n" chs[i]; L = chl[i]
  return chain_ok(startchain[s, L], s) || chain_ok(candline[s, L], s)
}
# One-line capitalized element: exactly one opening on the line, capitalized,
# beginning and ending there, outside every attribute expression.
function oneline_name(s, L,   n, parts, k, count, nm) {
  if (ctx0[s, L] == "JSXTAG" || startinattr[s, L] || openinattr[s, L] || tagends[s, L] != 1) return ""
  count = 0; n = split(tagnames[s, L], parts, " ")
  for (k = 1; k <= n; k++) if (substr(parts[k], 1, 2) == "o:") { count++; nm = substr(parts[k], 3) }
  if (count != 1 || nm !~ /^[A-Z]/) return ""
  count = 0
  for (k = 1; k <= segn[s, L]; k++) if (is_classname(s, L, k)) count++
  return (count <= 1) ? nm : ""
}
function oneline_admitted(s, L, o, Lj,   nm) {
  if (!Lj) return 0
  nm = oneline_name(s, L)
  if (nm == "" || nm != oneline_name(o, Lj)) return 0
  return class_values(s, L) != class_values(o, Lj)
}
function class_values(s, L,   k, out) {
  out = ""
  for (k = 1; k <= segn[s, L]; k++) if (is_classname(s, L, k)) out = out "\034" sgt[s, L, k] "=" sgv[s, L, k]
  return out
}
# The raw line with its one static className string attribute and the single
# whitespace before it removed, searched only between the element's `<Name` and
# the first `>` after it; a className that is not one static string, or one not
# found there, yields a value no other side can equal.
function strip_class(s, L, nm,   k, t, p, q, lit, tag) {
  t = raw[s, L]
  for (k = 1; k <= segn[s, L]; k++) if (is_classname(s, L, k)) {
    if (sgt[s, L, k] != "A" || class_kind(sgv[s, L, k]) != "s") return "\001" s
    p = index(t, "<" nm); if (p == 0) return "\001" s
    tag = substr(t, p); q = index(tag, ">"); if (q == 0) return "\001" s
    lit = "className=" sgv[s, L, k]
    q = index(substr(tag, 1, q), lit); if (q < 2 || substr(tag, q - 1, 1) !~ /[ \t]/) return "\001" s
    return substr(t, 1, p - 1) substr(tag, 1, q - 2) substr(tag, q + length(lit))
  }
  return t
}
function eval_tsx(i, P,   s, cs, o, L, j, Lj, t, c, cat, r, f, g, admit) {
  cs = chs[i]; s = P cs; L = chl[i]; o = P ((cs == "pre") ? "post" : "pre"); j = pairof[P, i]; Lj = j ? chl[j] : 0
  t = raw[s, L]
  cat = category(s, L)
  if (cat == "blank") return ""
  if (t ~ bidi) return "quick-codepoint"
  if (cat != "err" && class_nonascii(s, L, cat)) return "quick-codepoint"
  r = lexical_reason(s, L, t); if (r != "") return r
  c = (cat == "err") ? t : cv[s, L]
  r = generic_reason(c); if (r != "") return r
  if (cat == "err") return "quick-unclassified"
  if (cvaany[s, L] || c ~ /(^|[^A-Za-z0-9_$.])cva[ \t]*\(/) return "quick-cva"
  if (cat == "cnlit") {
    if (!j) return "quick-cn-argument"
    f = cnframe0[s, L]; g = cnframe0[o, Lj]
    if (!cnstatic[s, f] || !cnstatic[o, g] || cnargs[s, f] != cnargs[o, g]) return "quick-cn-argument"
    if (tagin0[s, L] && !intrinsic(tagname0[s, L]) && changed[cs, tagline0[s, L]]) return "quick-element"
    if (attr0[s, L] != "" && attr0[s, L] != "className") return "quick-attribute"
    return token_reason(s, L, cat, j, Lj, o)
  }
  if (cnd0[s, L] > 0 || cnd1[s, L] > 0 || cnopen[s, L] > static_cn_count(s, L)) return "quick-cn-argument"
  if (textunsafe[s, L]) return "quick-unclassified"
  if (cat == "text") {
    if (cs == "pre" && !hunkaddtext[P, chh[i]]) return "quick-text-deleted"
    return ""
  }
  if (cat != "struct") return "quick-unclassified"
  admit = oneline_admitted(s, L, o, Lj)
  if (!admit && (has_nonintrinsic(tagnames[s, L]) || (j && has_nonintrinsic(tagnames[o, Lj])))) return "quick-element"
  if (ctx0[s, L] == "JSXTAG" && tagin0[s, L] && !intrinsic(tagname0[s, L]) && changed[cs, tagline0[s, L]]) return "quick-element"
  if (!j) { if (tagnames[s, L] != "") return "quick-tag" }
  else if (!tags_compatible(tagnames[s, L], tagnames[o, Lj])) return "quick-tag"
  if (attr0[s, L] != "" && attr0[s, L] != "className") return "quick-attribute"
  if (other_attrs(s, L) != (j ? other_attrs(o, Lj) : "")) return "quick-attribute"
  if (j) { r = class_value_reason(class_sig(s, L), class_sig(o, Lj)); if (r != "") return r }
  r = token_reason(s, L, cat, j, Lj, o); if (r != "") return r
  if (cs == "pre" && hastext[s, L] && !hunkaddtext[P, chh[i]]) return "quick-text-deleted"
  if (admit && strip_class(s, L, oneline_name(s, L)) != strip_class(o, Lj, oneline_name(o, Lj))) return "quick-element"
  if (!j) return "quick-unclassified"
  if (skeleton(s, L) != skeleton(o, Lj)) return "quick-unclassified"
  return ""
}
# Two className value signatures that differ: a non-static value differing, a
# cn() call gained, lost or changing its literal count, or a static string
# turned into cn() is not a token change. A className added or removed as a
# static string is (its tokens go through the token checks).
function class_value_reason(a, b,   na, nb, pa, pb) {
  if (a == b) return ""
  if (index(a, "x:") > 0 || index(b, "x:") > 0) return (index(a b, "cn(") > 0) ? "quick-cn-argument" : "quick-unclassified"
  na = split(a, pa, "\034"); nb = split(b, pb, "\034")
  if (na == nb || index(a b, "cn") > 0) return "quick-cn-argument"
  return ""
}

AWK
