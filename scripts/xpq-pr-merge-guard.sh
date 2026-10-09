#!/usr/bin/env bash
# xpq-pr-merge-guard.sh: PreToolUse hook — blocks Claude from merging PRs and from
# pushing to the integration branches (main, master, dev).
#
# PRs must be merged by the user, not autonomously by Claude. This prevents Claude from
# self-merging even in permissive permission modes where broad gh/git wildcards exist in
# the allow list. Integration branches change only by a reviewed PR, so a direct push to
# one is the same bypass by another route.
#
# Denied:
#   - gh pr merge, with or without -R/--repo and odd whitespace
#   - REST .../pulls/<n>/merge and .../merges, matched by URL whatever the HTTP method, when
#     the command also uses gh/curl/wget. This denies the read-only GET "was it merged"
#     check too; use gh pr view --json mergedAt. The method is not parsed: it can come from
#     a variable, so reading it would only add a way around the rule.
#   - GraphQL mergePullRequest, enablePullRequestAutoMerge, mergeBranch (same condition)
#   - git push whose destination is main/master/dev: explicit refspec, HEAD while on one of
#     them, a bare push while on one of them, or --all/--mirror
#
# This is a backstop against accidents and injected text, not a security boundary: it does
# not see through variables, scripts or --input files. Credential separation (README,
# "Credentials") is what makes the merge itself impossible.
#
# Text that merely mentions a blocked command (a commit message, a comment body) also
# trips the gh/API checks; pass such text from a file (git commit -F, gh ... --body-file).

set -euo pipefail

input=$(cat)

printf '%s' "$input" | python3 -c '
import json, os, re, shlex, subprocess, sys

PROTECTED = {"main", "master", "dev"}
VALUE_OPTS = {"-o", "--push-option", "--receive-pack", "--exec"}
SHELLS = {"bash", "sh", "zsh", "dash"}

MERGE_MSG = (
    "Claude is not permitted to merge PRs autonomously. "
    "PRs must be reviewed and merged by you — either on GitHub "
    "or by explicitly running the command yourself."
)
PUSH_MSG = (
    "Claude is not permitted to push to main, master or dev. These branches change "
    "only by merging a reviewed PR. To push one yourself, run the command in this "
    "session with the ! prefix."
)
FILE_HINT = (
    "\n\nIf this is only text in a commit message or a comment body, pass it from a "
    "file (git commit -F, gh ... --body-file) so the command line does not contain it."
)

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

cmd = (data.get("tool_input") or {}).get("command", "") or ""
cwd = data.get("cwd") or ""


def deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason + "\n\nBlocked command: " + cmd,
        }
    }))
    sys.exit(0)


def current_branch(path):
    try:
        out = subprocess.run(
            ["git", "-C", path or cwd or ".", "branch", "--show-current"],
            capture_output=True, text=True, timeout=5,
        )
        return out.stdout.strip()
    except Exception:
        return ""


def tokens(text):
    text = text.replace("\n", " ; ")
    try:
        lex = shlex.shlex(text, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        return list(lex)
    except ValueError:
        return text.split()


def segments(toks):
    seg = []
    for t in toks:
        if t in {";", "&&", "||", "|", "&", "(", ")"}:
            if seg:
                yield seg
            seg = []
        else:
            seg.append(t)
    if seg:
        yield seg


def resolve_dir(cur, path):
    # cd - and paths built from variables or substitutions cannot be resolved here.
    if path == "-" or "$" in path or "`" in path:
        return cur
    return os.path.normpath(os.path.join(cur, os.path.expanduser(path)))


def check_push(args, cpath, cur):
    where = os.path.join(cur, os.path.expanduser(cpath)) if cpath else cur
    pos, skip, repo_opt = [], False, False
    for a in args:
        if skip:
            skip = False
        elif a == "--repo" or a.startswith("--repo="):
            # The remote comes from the option, so every positional is a refspec.
            repo_opt = True
            skip = a == "--repo"
        elif a in VALUE_OPTS:
            skip = True
        elif not a.startswith("-"):
            pos.append(a)
    if "--all" in args or "--mirror" in args:
        deny(PUSH_MSG)
    refspecs = pos if repo_opt else pos[1:]
    branch = None
    if not refspecs:
        branch = current_branch(where)
        if branch in PROTECTED:
            deny(PUSH_MSG)
        return
    for spec in refspecs:
        spec = spec.lstrip("+")
        dst = spec.split(":", 1)[1] if ":" in spec else spec
        if dst.startswith("refs/heads/"):
            dst = dst[len("refs/heads/"):]
        if dst in ("HEAD", ""):
            dst = current_branch(where)
        if dst in PROTECTED:
            deny(PUSH_MSG)


def check_text(text, cur):
    for seg in segments(tokens(text)):
        if seg[0] == "cd":
            args = [a for a in seg[1:] if not a.startswith("-") or a == "-"]
            if args:
                cur = resolve_dir(cur, args[0])
            continue
        if os.path.basename(seg[0]) in SHELLS and "-c" in seg[1:-1]:
            check_text(seg[seg.index("-c") + 1], cur)
            continue
        for i, t in enumerate(seg):
            if os.path.basename(t) != "git":
                continue
            j, cpath = i + 1, ""
            while j < len(seg) and seg[j].startswith("-"):
                if seg[j] == "-C" and j + 1 < len(seg):
                    cpath = seg[j + 1]
                    j += 1
                elif seg[j] == "-c" and j + 1 < len(seg):
                    j += 1
                j += 1
            if j < len(seg) and seg[j] == "push":
                check_push(seg[j + 1:], cpath, cur)
            break


flat = re.sub(r"\s+", " ", cmd)

# gh pr merge: fixed string anywhere (so bash -c "..." does not bypass), plus the
# -R/--repo placements and whitespace variants the fixed string misses.
if "gh pr merge" in flat or re.search(
    r"\bgh\b(?: (?:-R|--repo)(?: |=)\S+)* pr(?: (?:-R|--repo)(?: |=)\S+)* merge\b", flat
):
    deny(MERGE_MSG + FILE_HINT)

# API routes to the same action, only when the command talks to GitHub.
if re.search(r"\b(gh|curl|wget)\b", flat) and (
    re.search(r"pulls/\S*/merge\b", flat)
    or re.search(r"repos/\S+/merges\b", flat)
    or re.search(r"\b(mergePullRequest|enablePullRequestAutoMerge|mergeBranch)\b", flat)
):
    deny(MERGE_MSG + " This includes the REST and GraphQL merge calls." + FILE_HINT)

check_text(cmd, cwd)
'
