# Shell Stack (bats)

Tests for the bash scripts your own skills and hooks run, using the pinned npm `bats` package (bats-core). No system install is needed.

## Where suites live

- Suites go in `tests/shell/`, one `.bats` file per script under test, named after the script.
- Build fixtures (fake repos, input files, stub commands) inside `$BATS_TEST_TMPDIR`, never in the working tree. bats deletes it after each test.
- Run the script as a user would, through its public interface (arguments, stdin, exit code, stdout, stderr), not by sourcing its internals.

## Run them

```bash
pnpm test:shell
```

```bash
pnpm test:shell tests/shell/my-script.bats
```

```bash
pnpm exec bats --version
```

With no arguments `pnpm test:shell` runs the `tests/shell` directory (not recursive). Arguments pass straight to bats.

## Put bash 5 first on PATH

The npm bats launcher runs under the first `bash` on `PATH`. A stock Mac puts bash 3.2 there, where a failing bare `[[ ]]` inside a test silently passes. `pnpm test:shell` refuses to run, with a one-line message, when that bash is older than 4.

- macOS: `brew install bash`, then make sure `$(brew --prefix)/bin` comes before `/bin` on `PATH`, and open a new shell.
- Linux: bash is already 5; nothing to do.

## Write assertions that can fail

A test is only evidence if red is reachable. bash 3.2 skips a failing bare `[[ ]]`, and a `!`-negated command that is not the last line of a test never fails it on any bash version. Read `.claude/rules/bats-assertions.md` before writing assertions: it owns the shapes that can silently pass and the fixes, and it loads on its own when you edit a `.bats` file. Do not copy its patterns from memory.

## Red-green loop for a small script

Say the script `scripts/slugify.sh` should print a lowercase, dash-separated slug of its argument.

1. Write the first test in `tests/shell/slugify.bats`:

```bash
#!/usr/bin/env bats

@test "lowercases and dashes a phrase" {
  run sh scripts/slugify.sh "Hello World"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "hello-world" ] || return 1
}
```

2. Run `pnpm test:shell tests/shell/slugify.bats` and confirm it fails because the script is missing or prints the wrong thing.
3. Write the least script that passes, run again, confirm green.
4. Add the next behavior (an empty argument exits 1 with a message), watch it fail, make it pass. One test, one change, repeat.

## More

`wiki/concepts/Shell Testing and CI.md` covers linting shell with shellcheck in CI, keeping a suite fast, and sharding a large one. Read it when you add a CI job for shell or a suite gets slow.
