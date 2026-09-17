#!/usr/bin/env bash

# Regression test for bashrc.d/prompt-gruvbox.sh: segment assembly, the Git
# status parser, the pom.xml reader, the Docker context reader and the PS1
# quoting of untrusted text.

set -u
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1

TEST_NAME='prompt-gruvbox'
# shellcheck source=tests/lib.sh
source tests/lib.sh

test_sandbox

# A non-interactive shell has neither of these, and the test runs with "set -u".
PROMPT_COMMAND=${PROMPT_COMMAND-}
PS1=${PS1-}

# shellcheck source=bashrc.d/prompt-core.sh
source bashrc.d/prompt-core.sh
# shellcheck source=bashrc.d/prompt-gruvbox.sh
source bashrc.d/prompt-gruvbox.sh

# The prompt is rendered without the readline markers so the assertions can
# look at the visible text.
visible() {
    local s=${PS1//\\[/}
    s=${s//\\]/}
    printf '%s' "$s"
}

# --- __gb_quote ------------------------------------------------------------

__gb_quote 'feature/$(id)'
assert_equal 'command substitution is neutralised' 'feature/\$(id)' "$REPLY"

__gb_quote 'a`b`c'
assert_equal 'backticks are neutralised' 'a\`b\`c' "$REPLY"

__gb_quote 'back\slash'
assert_equal 'backslashes are doubled' 'back\\slash' "$REPLY"

# --- __gb_find_up ----------------------------------------------------------

mkdir -p "$TEST_TMP/project/src/main/likec4" || fail 'sandbox tree'
: > "$TEST_TMP/project/pom.xml" || fail 'sandbox pom'

cd "$TEST_TMP/project/src/main/likec4" || fail 'cd into the sandbox tree'
assert 'the ancestor walk finds pom.xml' __gb_find_up pom.xml
assert_equal 'it reports the owning directory' "$TEST_TMP/project" "$REPLY"
assert_status 'a missing marker fails' 1 __gb_find_up definitely-not-here

# The walk has to terminate at the filesystem root instead of looping.
cd / || fail 'cd /'
assert_status 'the walk terminates at the root' 1 __gb_find_up definitely-not-here

# --- pom.xml ---------------------------------------------------------------

cat > "$TEST_TMP/project/pom.xml" <<'EOF'
<project>
  <parent>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>3.3.2</version>
  </parent>
  <artifactId>portal-doc</artifactId>
  <version>1.4.0-SNAPSHOT</version>
</project>
EOF

assert 'the pom version is read' __gb_maven_version "$TEST_TMP/project/pom.xml"
assert_equal 'the parent version is skipped' '1.4.0-SNAPSHOT' "$REPLY"

cat > "$TEST_TMP/no-version.xml" <<'EOF'
<project>
  <artifactId>child</artifactId>
  <dependencies/>
</project>
EOF
assert_status 'a pom without its own version fails' 1 \
    __gb_maven_version "$TEST_TMP/no-version.xml"

# The version is read fresh, so an edit shows up in the very next prompt.
cat > "$TEST_TMP/project/pom.xml" <<'EOF'
<project>
  <artifactId>portal-doc</artifactId>
  <version>1.5.0-SNAPSHOT</version>
</project>
EOF
assert 'the edited pom is read again' __gb_maven_version "$TEST_TMP/project/pom.xml"
assert_equal 'the new version wins' '1.5.0-SNAPSHOT' "$REPLY"

# The line budget bounds the cost of a pathological header.
{
    printf '<project>\n'
    for i in 1 2 3 4 5 6 7 8 9 10; do printf '  <!-- header %s -->\n' "$i"; done
    printf '  <version>7.7.7</version>\n</project>\n'
} > "$TEST_TMP/long-header.xml"

PROMPT_GRUVBOX_POM_MAX_LINES=500
assert 'a licence header does not hide the version' \
    __gb_maven_version "$TEST_TMP/long-header.xml"
assert_equal 'the version behind the header is read' '7.7.7' "$REPLY"

PROMPT_GRUVBOX_POM_MAX_LINES=3
assert_status 'the line budget stops the read' 1 \
    __gb_maven_version "$TEST_TMP/long-header.xml"
PROMPT_GRUVBOX_POM_MAX_LINES=500

# --- java ------------------------------------------------------------------

# A JDK switch has to be visible immediately, so the version is derived from
# JAVA_HOME on every call rather than cached for the life of the shell.
JAVA_HOME='/c/Program Files/Microsoft/jdk-21.0.5.11-hotspot'
assert 'the java version comes from JAVA_HOME' __gb_java_version
assert_equal 'the JAVA_HOME version is parsed' '21.0.5' "$REPLY"

JAVA_HOME='/c/Program Files/Eclipse Adoptium/jdk-17.0.11.9-hotspot'
assert 'a JDK switch is picked up' __gb_java_version
assert_equal 'the new JAVA_HOME wins' '17.0.11' "$REPLY"
unset JAVA_HOME

# --- docker context --------------------------------------------------------

mkdir -p "$TEST_HOME/.docker" || fail 'sandbox docker dir'
printf '{\n  "currentContext": "portal-dev"\n}\n' > "$TEST_HOME/.docker/config.json"

unset __gb_docker_cache
assert 'the docker context is read from config.json' __gb_docker_context
assert_equal 'the context name is parsed' 'portal-dev' "$REPLY"

# A stock Docker Desktop for Windows always reads "desktop-linux", so a badge
# for it would carry no information.
for stock in default desktop-linux desktop-windows; do
    unset __gb_docker_cache
    printf '{\n  "currentContext": "%s"\n}\n' "$stock" \
        > "$TEST_HOME/.docker/config.json"
    assert_status "the $stock context is hidden" 1 __gb_docker_context
done

unset __gb_docker_cache
PROMPT_GRUVBOX_DOCKER_HIDE=''
assert 'an empty hide list shows everything' __gb_docker_context
assert_equal 'the stock context is shown again' 'desktop-windows' "$REPLY"
PROMPT_GRUVBOX_DOCKER_HIDE='default desktop-linux desktop-windows'

# Git Bash does not guarantee that $HOME is %USERPROFILE%, and Docker Desktop
# writes into the latter. Windows separators have to survive the lookup.
unset __gb_docker_cache
rm -rf "$TEST_HOME/.docker"
mkdir -p "$TEST_TMP/winprofile/.docker" || fail 'sandbox winprofile'
printf '{\n  "currentContext": "remote-build"\n}\n' \
    > "$TEST_TMP/winprofile/.docker/config.json"
USERPROFILE=${TEST_TMP//\//\\}'\winprofile'
assert 'the context is found via USERPROFILE' __gb_docker_context
assert_equal 'the USERPROFILE context is parsed' 'remote-build' "$REPLY"
unset USERPROFILE
mkdir -p "$TEST_HOME/.docker" || fail 'restore docker dir'

unset __gb_docker_cache
DOCKER_CONTEXT=explicit
assert 'the environment wins over config.json' __gb_docker_context
assert_equal 'the environment context is used' 'explicit' "$REPLY"
unset DOCKER_CONTEXT __gb_docker_cache

# --- git status ------------------------------------------------------------

if command -v git >/dev/null 2>&1; then
    repo="$TEST_TMP/repo"
    mkdir -p "$repo" || fail 'sandbox repo'
    cd "$repo" || fail 'cd into the repo'

    git init -q . >/dev/null 2>&1 || fail 'git init'
    git config user.email test@example.invalid
    git config user.name 'Test'
    git symbolic-ref HEAD refs/heads/main

    printf 'one\n' > tracked.txt
    git add tracked.txt >/dev/null 2>&1
    git commit -qm 'initial' >/dev/null 2>&1 || fail 'git commit'

    assert 'the git segment is built inside a repository' __gb_git_segment
    assert_contains 'the branch name appears' "$REPLY" 'main'
    assert_not_contains 'a clean tree has no staged marker' "$REPLY" '+'

    printf 'two\n' >> tracked.txt
    printf 'new\n' > untracked.txt
    : > staged.txt
    git add staged.txt >/dev/null 2>&1

    __gb_git_segment
    assert_contains 'the staged file is counted' "$REPLY" '+1'
    assert_contains 'the modified file is counted' "$REPLY" '!1'
    assert_contains 'the untracked file is counted' "$REPLY" '?1'

    PROMPT_GRUVBOX_GIT=0
    assert_status 'the git segment can be switched off' 1 __gb_git_segment
    PROMPT_GRUVBOX_GIT=1
else
    printf 'SKIP: %s: git is not installed\n' "$TEST_NAME" >&2
fi

cd "$TEST_TMP" || fail 'cd out of the repo'
assert_status 'outside a repository there is no git segment' 1 __gb_git_segment

# --- assembled prompt ------------------------------------------------------

__cmd_last_exit=0
__cmd_duration=''
__cmd_elapsed_us=0
__gb_build

rendered=$(visible)
assert_contains 'the path escape survives' "$rendered" '\w'
assert_contains 'the user escape survives' "$rendered" '\u'
assert_contains 'the prompt breaks before the input symbol' "$rendered" '\n'

# root gets '#', everyone else the arrow, so the test derives the expectation
# instead of assuming who runs it.
if (( EUID == 0 )); then
    expected_symbol='#'
else
    expected_symbol=$'\u276f'
fi
assert_contains 'a successful prompt ends in the input symbol' \
    "$rendered" "$expected_symbol"
assert_not_contains 'no error marker on success' "$rendered" $'\u2718'

__cmd_last_exit=42
__cmd_duration='2m07s'
__cmd_elapsed_us=127000000
__gb_build

rendered=$(visible)
assert_contains 'the exit code is shown' "$rendered" '42'
assert_contains 'the error marker is shown' "$rendered" $'\u2718'
assert_contains 'the duration is shown' "$rendered" '2m07s'

# A fast, successful command shows neither.
__cmd_last_exit=0
__cmd_duration='12ms'
__cmd_elapsed_us=12000
__gb_build

rendered=$(visible)
assert_not_contains 'a fast command hides its duration' "$rendered" '12ms'

# --- ASCII fallback --------------------------------------------------------

PROMPT_GRUVBOX_POWERLINE=0
__gb_init_palette
__gb_build
rendered=$(visible)
assert_not_contains 'the ASCII mode drops the powerline separator' \
    "$rendered" $'\ue0b0'
PROMPT_GRUVBOX_POWERLINE=1
__gb_init_palette

pass 'the gruvbox prompt builds correctly'
