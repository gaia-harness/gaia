# Shared x.y.z comparison for the scripts that range over release versions.
# Load it ahead of the program text; vcmp(a, b) returns 1 when a is newer than
# b, -1 when older, 0 when equal. Components compare numerically, so 2.10.0
# sorts above 2.9.0.
function vcmp(a, b,   x, y, i) {
  split(a, x, ".")
  split(b, y, ".")
  for (i = 1; i <= 3; i++) {
    if ((x[i] + 0) > (y[i] + 0)) return 1
    if ((x[i] + 0) < (y[i] + 0)) return -1
  }
  return 0
}
