#!/usr/bin/env bash
# audit-quick-classify-awk-nested-lib.sh: the second fragment of the quick
# classifier's awk line program: the nested-element pass. Sourced by
# audit-quick-classify-lib.sh; holds only awk text, and the lines stage joins
# the fragments, in order, into the one program.
# shellcheck disable=SC2034
IFS= read -r -d '' _QUICK_AWK_NESTED <<'AWK' || true
# ---- nested-element pass (NEWLEX) -------------------------------------------
# An attribute expression is admitted when its whole value is one capitalized
# element, optionally in one pair of parentheses: its signature (fsig) records
# every token lexed directly in it, `(`, `)`, `<C` for a capitalized opening,
# and X for anything else, so a ternary, a call, a second element or an
# identifier leaves it unadmitted. The value is known only when the expression
# closes, so evaluation, which runs after both images are lexed, reads it.
function sigframe() {
  if (depth > 0 && ft[depth] == "attrexpr") return depth
  if (depth > 1 && ft[depth] == "paren" && ft[depth - 1] == "attrexpr") return depth - 1
  return 0
}
function sigmark(x,   a) { a = sigframe(); if (a) fsig[CS, fid[a]] = fsig[CS, fid[a]] x }
# The attribute expressions from frame k down: each must be held by an element's
# opening tag, which may itself be the value of another; any other frame ends
# the walk, and an attribute expression below that point fails it.
function chain_walk(k,   chain, n) {
  chain = ""; n = 0
  while (k >= 1) {
    if (ft[k] == "paren" && k > 1 && ft[k - 1] == "attrexpr") k--
    if (ft[k] != "attrexpr") break
    chain = chain " " fid[k]; n++; k--
    if (k < 1 || ft[k] != "jsxtag") return " BAD"
    k--
  }
  if (n == 0) return " BAD"
  for (; k >= 1; k--) if (ft[k] == "attrexpr") return " BAD"
  return chain
}
function restore_capture() {
  if (!fsusp[depth]) return
  capdepth = fsusp[depth]; capkind = fsuspkind[depth]; capname = fsuspname[depth]; capbuf = ""; fsusp[depth] = 0
}
function fail_image() { err[CS] = 1 }
function startcap(kind, name) {
  if (capdepth == 0) { capdepth = depth + 1; capbuf = "{"; capkind = kind; capname = name } else emit("{")
}
function afterjsx() { if (depth == 0 || ft[depth] != "jsxchild") { prev = ")"; prevword = "" } }
function regex_allowed() {
  if (prev == "" || index("(,=:[!&|?{};", prev) > 0) return 1
  return (prev == "a" && (prevword == "return" || prevword == "typeof"))
}
function jsx_allowed(n) {
  if (n !~ /^[A-Za-z>]$/) return 0
  if (prev == "" || index("(,=:[!&|?{};>", prev) > 0) return 1
  return (prev == "a" && (prevword == "return" || prevword == "default"))
}
function scan_regex(line, i,   j, ch, inclass) {
  inclass = 0
  for (j = i + 1; j <= linelength; j++) {
    ch = substr(line, j, 1)
    if (ch == "\\") { j++; continue }
    if (ch == "[") inclass = 1
    else if (ch == "]") inclass = 0
    else if (ch == "/" && !inclass) {
      while (j + 1 <= linelength && substr(line, j + 1, 1) ~ /[a-z]/) j++
      return j
    }
  }
  return 0
}
function open_tag(line, i,   j, k, nm, susp, skind, sname) {
  j = i + 1; k = j
  while (k <= linelength && substr(line, k, 1) ~ /[A-Za-z0-9_$.:-]/) k++
  nm = substr(line, j, k - j)
  for (susp = depth; susp >= 1; susp--) if (ft[susp] == "attrexpr") { openinattr[CS, CL] = 1; break }
  susp = 0
  # A capitalized element as an attribute expression's value lexes its own
  # opening tag as a top-level one would, its attributes landing as the line's
  # own segments; the enclosing capture resumes at the tag's end.
  if (NEWLEX && sigframe()) {
    sigmark(nm ~ /^[A-Z]/ ? "<C" : "<o")
    if (nm ~ /^[A-Z]/) {
      candline[CS, CL] = candline[CS, CL] chain_walk(depth)
      if (capdepth > 0) {
        if (capbuf != "") addseg(capkind "~", capname, capbuf)
        susp = capdepth; skind = capkind; sname = capname; capdepth = 0; capbuf = ""
      }
    }
  }
  if (capdepth == 0) { flushK(); flushT(); addseg("O", nm, "") } else emit("<" nm)
  cvadd(" <" nm)
  tagl = tagl " o:" nm
  if (nm == "") {
    if (substr(line, k, 1) != ">") { fail_image(); return linelength }
    pushf("jsxchild", "")
    if (capdepth == 0) addseg("E", "", ""); else emit(">")
    return k
  }
  pushf("jsxtag", nm)
  fsusp[depth] = susp; fsuspkind[depth] = skind; fsuspname[depth] = sname
  return k - 1
}
function jsx_tag_char(line, i, c,   k, j, nm, q, e, val) {
  if (c == " " || c == "\t") { if (capdepth > 0) emit(c); return i }
  if (c == "/" && substr(line, i + 1, 1) == ">") {
    if (capdepth > 0) emit("/>"); else addseg("S", "", "")
    if (fline[depth] == CL) tagends[CS, CL]++
    restore_capture(); popf(); afterjsx(); return i + 1
  }
  if (c == ">") {
    if (capdepth > 0) emit(">"); else addseg("E", "", "")
    if (fline[depth] == CL) tagends[CS, CL]++
    restore_capture(); ft[depth] = "jsxchild"; return i
  }
  if (c == "{") { startcap("X", ""); pushf("attrexpr", ""); cvadd(" {"); if (NEWLEX) { prev = "{"; prevword = "" } return i }
  if (c ~ /[A-Za-z_$]/) {
    k = i
    while (k + 1 <= linelength && substr(line, k + 1, 1) ~ /[A-Za-z0-9_$:.-]/) k++
    nm = substr(line, i, k - i + 1)
    cvadd(" " nm)
    j = k + 1
    while (j <= linelength && substr(line, j, 1) ~ /[ \t]/) j++
    if (substr(line, j, 1) != "=") { if (capdepth > 0) emit(" " nm); else addseg("A", nm, ""); return k }
    cvadd("=")
    j++
    while (j <= linelength && substr(line, j, 1) ~ /[ \t]/) j++
    q = substr(line, j, 1)
    if (q == "\"" || q == "'") {
      cvadd("\"\"")
      e = index(substr(line, j + 1), q)
      if (e == 0) {
        inattrstr = q; attrname = nm
        if (capdepth > 0) emit(" " nm "=" substr(line, j)); else attrval = substr(line, j)
        return linelength
      }
      val = substr(line, j, e + 1)
      if (capdepth > 0) emit(" " nm "=" val); else addseg("A", nm, val)
      return j + e
    }
    if (q == "{") {
      if (capdepth > 0) emit(" " nm "=")
      startcap("A", nm); pushf("attrexpr", ""); fattr[depth] = nm; cvadd("{")
      # The base pass keeps whatever prev the tag inherited, which can stop a
      # `<` at the start of the value from reading as JSX.
      if (NEWLEX) { prev = "{"; prevword = "" }
      return j
    }
    fail_image(); return linelength
  }
  fail_image(); return linelength
}
function jsx_child_char(line, i, c,   k, j, nm) {
  if (c == "{") { flushT(); startcap("X", ""); pushf("childexpr", ""); cvadd("{"); return i }
  if (c == "<") {
    if (substr(line, i + 1, 1) == "/") {
      k = i + 2
      while (k <= linelength && substr(line, k, 1) ~ /[ \t]/) k++
      j = k
      while (k <= linelength && substr(line, k, 1) ~ /[A-Za-z0-9_$.:-]/) k++
      nm = substr(line, j, k - j)
      while (k <= linelength && substr(line, k, 1) ~ /[ \t]/) k++
      if (substr(line, k, 1) != ">" || nm != fname[depth]) { fail_image(); return linelength }
      flushT()
      if (capdepth > 0) emit("</" nm ">"); else addseg("C", nm, "")
      tagl = tagl " c:" nm
      cvadd(" </" nm)
      popf(); afterjsx(); return k
    }
    if (substr(line, i + 1, 1) ~ /^[A-Za-z>]$/) { flushT(); return open_tag(line, i) }
    fail_image(); return linelength
  }
  if (capdepth > 0) emit(c); else tbuf = tbuf c
  return i
}
function code_char(line, i, c,   n, j, k, w, callee, t) {
  n = substr(line, i + 1, 1)
  if (c == " " || c == "\t") { emit(c); cvadd(c); return i }
  if (NEWLEX && c != "}" && !(c == "<" && jsx_allowed(n))) sigmark(c == "(" ? "(" : (c == ")" ? ")" : "X"))
  if (c == "/" && n == "/") { w = substr(line, i); emit(w); cvadd(w); return linelength }
  if (c == "/" && n == "*") { emit("/*"); inblock = 1; return i + 1 }
  if (c == "\"" || c == "'") { emit(c); instr = c; cvadd("\"\""); cnmark("Q"); return i }
  if (c == "`") { emit(c); cvadd("`"); cnmark("T"); pushf("tmpl", ""); return i }
  if (c == "/" && regex_allowed()) {
    j = scan_regex(line, i)
    if (j == 0) { fail_image(); return linelength }
    emit(substr(line, i, j - i + 1)); cvadd("/r/"); cnmark("R"); prev = ")"; prevword = ""
    return j
  }
  if (c == "<" && jsx_allowed(n)) return open_tag(line, i)
  if (c ~ /[A-Za-z_$]/) {
    j = i
    while (j + 1 <= linelength && substr(line, j + 1, 1) ~ /[A-Za-z0-9_$]/) j++
    w = substr(line, i, j - i + 1)
    emit(w); cvadd(w); cnmark("I")
    if (depth == 0) {
      if (w == "export") pendstate = 1
      else if (w == "const" && pendstate == 1) pendstate = 2
      else if (pendstate == 2) { pendstory = w; pendstate = 3 }
      else if (pendstate != 3) pendstate = 0
    }
    if (depth > 0 && ft[depth] == "brace" && (prev == "{" || prev == ",")) {
      k = j + 1
      while (k <= linelength && substr(line, k, 1) ~ /[ \t]/) k++
      if (substr(line, k, 1) == ":") {
        fprop[depth] = w
        if (fstory[depth] ~ /^story:/ && w == "play") playany[CS, CL] = 1
      }
    }
    prev = "a"; prevword = w
    return j
  }
  if (c ~ /[0-9]/) {
    j = i
    while (j + 1 <= linelength && substr(line, j + 1, 1) ~ /[A-Za-z0-9_.]/) j++
    w = substr(line, i, j - i + 1)
    emit(w); cvadd(w); cnmark("D"); prev = "a"; prevword = ""
    return j
  }
  if (c == "{" || c == "(" || c == "[") {
    emit(c); cvadd(c)
    callee = (c == "(" && prev == "a") ? prevword : ""
    pushf(c == "{" ? "brace" : (c == "(" ? "paren" : "bracket"), callee)
    prev = c; prevword = ""
    return i
  }
  if (c == "}") {
    if (depth == 0) { fail_image(); return linelength }
    t = ft[depth]
    emit(c); cvadd(c)
    if (t == "tmplexpr") { popf(); return i }
    if (t == "attrexpr" || t == "childexpr") {
      if (depth == capdepth) { addseg(capkind, capname, capbuf); capdepth = 0; capbuf = "" }
      popf(); return i
    }
    if (t != "brace") { fail_image(); return linelength }
    popf(); prev = "}"; prevword = ""
    return i
  }
  if (c == ")" || c == "]") {
    if (depth == 0 || ft[depth] != (c == ")" ? "paren" : "bracket")) { fail_image(); return linelength }
    emit(c); cvadd(c); popf(); prev = c; prevword = ""
    return i
  }
  emit(c); cvadd(c); cnmark(c)
  if (c == ";" && depth == 0) { pendstate = 0; pendstory = "" }
  prev = c; prevword = ""
  return i
}
function mode_now(   t) {
  if (inblock) return "BLOCK"
  if (instr != "") return "STRING"
  if (inattrstr != "") return "ATTRSTR"
  t = (depth > 0) ? ft[depth] : ""
  if (t == "tmpl") return "TMPL"
  if (t == "jsxtag") return "JSXTAG"
  if (t == "jsxchild") return "JSXCHILD"
  return "CODE"
}
function line_start(s, L,   k) {
  ctx0[s, L] = mode_now()
  d0[s, L] = depth
  cnd0[s, L] = cndepth
  if (cvadepth > 0) cvaany[s, L] = 1
  for (k = depth; k >= 1; k--) if (ft[k] == "jsxtag") { tagname0[s, L] = fname[k]; tagline0[s, L] = fline[k]; tagin0[s, L] = 1; break }
  for (k = depth; k >= 1; k--) if (ft[k] == "attrexpr") { startinattr[s, L] = 1; break }
  if (!NEWLEX) { for (k = depth; k >= 1; k--) if (ft[k] == "attrexpr") { attr0[s, L] = fattr[k]; break } }
  else {
    # The enclosing attribute is the innermost element's own: the scan stops at
    # the first opening-tag frame.
    for (k = depth; k >= 1; k--) { if (ft[k] == "jsxtag") break; if (ft[k] == "attrexpr") { attr0[s, L] = fattr[k]; break } }
    for (k = depth; k >= 1; k--) if (ft[k] == "jsxtag") break
    startchain[s, L] = (k >= 1) ? chain_walk(k - 1) : " BAD"
  }
  for (k = 1; k <= depth; k++) if (fstory[k] ~ /^story:/) { story0[s, L] = substr(fstory[k], 7); if (fprop[k] == "play") playany[s, L] = 1; break }
  argsdirect0[s, L] = (depth > 0 && fstory[depth] == "args") ? 1 : 0
  storytop0[s, L] = (depth > 0 && fstory[depth] ~ /^story:/) ? 1 : 0
  cnframe0[s, L] = (depth > 0 && ft[depth] == "paren" && fname[depth] == "cn") ? fid[depth] : 0
}
function line_end(s, L,   k, key, rest) {
  flushT()
  if (capdepth > 0 && capbuf != "") { addseg(capkind "~", capname, capbuf); capbuf = "" }
  if (inattrstr != "" && capdepth == 0) { addseg("A~", attrname, attrval); attrval = "" }
  flushK()
  cv[s, L] = cvbuf
  tagnames[s, L] = tagl
  d1[s, L] = depth
  cnd1[s, L] = cndepth
  for (k = 1; k <= depth; k++) if (fstory[k] ~ /^story:/) { if (fprop[k] == "play") playany[s, L] = 1; break }
  if (argsdirect0[s, L] && d1[s, L] == d0[s, L] && raw[s, L] ~ ARGLINE) {
    key = raw[s, L]; sub(/^[ \t]*/, "", key); sub(/[ \t]*:.*$/, "", key)
    argskey[s, story0[s, L], key] = 1
  }
  if (storytop0[s, L] && d1[s, L] == d0[s, L] && raw[s, L] ~ ARGINLINE) {
    argsinline[s, story0[s, L]] = inline_keys(raw[s, L])
  }
}
function inline_keys(t,   rest, keys, key) {
  rest = t; sub(/^[ \t]*args:[ \t]*\{[ \t]*/, "", rest); keys = ""
  while (match(rest, "^" ARGPAIR)) {
    key = substr(rest, 1, RLENGTH); sub(/[ \t]*:.*$/, "", key)
    keys = keys "," key
    rest = substr(rest, RLENGTH + 1); sub(/^[ \t]*,?[ \t]*/, "", rest)
  }
  return keys
}
function tokenize(s,   L, line, i, c, t) {
  depth = 0; instr = ""; inblock = 0; inattrstr = ""; prev = ""; prevword = ""
  cvadepth = 0; cndepth = 0; capdepth = 0; capbuf = ""; capname = ""; capkind = ""
  pendstate = 0; pendstory = ""; attrval = ""; attrname = ""
  CS = s; NEWLEX = (s ~ /^n/) ? 1 : 0
  for (L = 1; L <= nlines[s]; L++) {
    CL = L
    line = raw[s, L]; linelength = length(line)
    line_start(s, L)
    kbuf = ""; tbuf = ""; cvbuf = ""; tagl = ""
    for (i = 1; i <= linelength; i++) {
      c = substr(line, i, 1)
      if (inblock) {
        if (c == "*" && substr(line, i + 1, 1) == "/") { emit("*/"); i++; inblock = 0 } else emit(c)
        continue
      }
      if (instr != "") {
        emit(c)
        if (c == "\\") { emit(substr(line, i + 1, 1)); i++; continue }
        if (c == instr) { instr = ""; prev = "\""; prevword = "" }
        continue
      }
      if (inattrstr != "") {
        if (capdepth > 0) emit(c); else attrval = attrval c
        if (c == inattrstr) { inattrstr = ""; if (capdepth == 0) addseg("A~", attrname, attrval); attrval = "" }
        continue
      }
      t = (depth > 0) ? ft[depth] : ""
      if (t == "tmpl") {
        emit(c)
        if (c == "\\") { emit(substr(line, i + 1, 1)); i++; continue }
        if (c == "`") { popf(); prev = ")"; prevword = ""; continue }
        if (c == "$" && substr(line, i + 1, 1) == "{") { emit("{"); i++; pushf("tmplexpr", ""); continue }
        continue
      }
      if (t == "jsxtag") { i = jsx_tag_char(line, i, c); if (err[s]) break; continue }
      if (t == "jsxchild") { i = jsx_child_char(line, i, c); if (err[s]) break; continue }
      i = code_char(line, i, c)
      if (err[s]) break
    }
    line_end(s, L)
    if (err[s]) return
  }
  if (depth != 0 || instr != "" || inblock || inattrstr != "") err[s] = 1
}

AWK
