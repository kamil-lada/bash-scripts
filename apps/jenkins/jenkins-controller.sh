#!/bin/bash
# jenkins-controller — Jenkins LTS controller as a Docker Compose stack, with SSH build agents.
# No setup wizard, no JCasC: first-boot Groovy (init.groovy.d) sets everything, then is deleted.
#
# Usage: jenkins-controller.sh   (interactive, run as root on the Docker host)
#
# Modes (asked first):
#   1  Controller only — builds run on the built-in node
#   2  Controller + worker(s) — built-in node 0 executors, SSH agents
#   3  Add a worker to an existing controller (reads <stack>/.env, uses /scriptText, no restart)
#
# Standalone: needs docker + compose plugin, curl, ssh-keygen, ssh-keyscan — NOT this repository.
set -Eeuo pipefail
umask 022

readonly DEFAULT_TAG=2.580.2-lts-jdk25          # pinned LTS, bump deliberately
readonly DEFAULT_STACK=/data/stacks/jenkins
readonly BASE_PLUGINS="ssh-slaves git workflow-aggregator credentials-binding"
readonly AGENT_CRED=agent-ssh
readonly GITHUB_CRED=github-deploy
readonly BOOT_TIMEOUT=600                       # seconds for the first boot

info() { echo "[→] $*"; }
ok()   { echo "[✓] $*"; }
warn() { echo "[!] $*" >&2; }
die()  { echo "[✗] $*" >&2; exit 1; }

# ask VAR "question" [default] [regex] — repeats until the answer matches regex
ask() {
    local __a
    while :; do
        read -rp "$2${3:+ [$3]}: " __a
        __a="${__a:-${3:-}}"
        if [[ -n ${4:-} && ! $__a =~ $4 ]]; then warn "Invalid value: '$__a'"; continue; fi
        printf -v "$1" '%s' "$__a"; return
    done
}
yesno() {  # yesno "question" y|n
    local a; read -rp "$1 [$([[ $2 == y ]] && echo Y/n || echo y/N)]: " a
    [[ ${a:-$2} =~ ^[Yy] ]]
}
ask_pass() {  # ask_pass VAR "question" [confirm]
    local p1 p2
    while :; do
        read -rsp "$2: " p1; echo
        [[ -n $p1 ]] || { warn "Empty password"; continue; }
        [[ -z ${3:-} ]] && break
        read -rsp "Repeat: " p2; echo
        [[ $p1 == "$p2" ]] && break || warn "Passwords differ"
    done
    printf -v "$1" '%s' "$p1"
}
b64() { printf '%s' "$1" | base64 -w0; }
# Workers run the same Java major as the controller image (maintainer advice: agent >= controller Java).
# Sets JAVA_MAJOR and WORKER_JAVA (javaPath of the nodes, Debian openjdk-N-jre-headless) from the tag.
java_from_tag() {
    [[ $1 =~ -jdk([0-9]+)$ ]] || die "Image tag '$1' has no -jdkNN suffix (e.g. 2.580.2-lts-jdk25)"
    JAVA_MAJOR=${BASH_REMATCH[1]}
    (( JAVA_MAJOR >= 21 )) || die "Jenkins needs Java 21 or newer (tag $1)"
    WORKER_JAVA=/usr/lib/jvm/java-$JAVA_MAJOR-openjdk-amd64/bin/java
}
env_get() { sed -n "s/^$1=//p" "$STACK/.env" | tail -1; }
dc() { docker compose --project-directory "$STACK" "$@"; }

readonly RE_NAME='^[A-Za-z0-9._-]+$'
readonly RE_HOST='^[A-Za-z0-9.-]+$'
readonly RE_INT='^[0-9]+$'
readonly RE_LABELS='^[A-Za-z0-9._ -]*$'
readonly RE_DIR='^/[A-Za-z0-9._/-]+$'

############################################################# GROOVY (shared by first boot and mode 3)
# All values are embedded base64 (d('...')) — no quoting problems with passwords or keys.
groovy_lib() {
    cat <<'EOF'
import jenkins.model.*
import hudson.model.*
import hudson.security.*
import hudson.slaves.*
import hudson.plugins.sshslaves.SSHLauncher
import hudson.plugins.sshslaves.verifiers.ManuallyTrustedKeyVerificationStrategy
import com.cloudbees.plugins.credentials.*
import com.cloudbees.plugins.credentials.domains.Domain
import com.cloudbees.jenkins.plugins.sshcredentials.impl.BasicSSHUserPrivateKey
import org.jenkinsci.plugins.gitclient.GitHostKeyVerificationConfiguration
import org.jenkinsci.plugins.gitclient.verifier.KnownHostsFileVerificationStrategy

String d(String s) { new String(s.decodeBase64(), 'UTF-8') }

boolean hasCred(String id) { SystemCredentialsProvider.instance.credentials.any { it.id == id } }

void addKey(String id, String user, String key, String desc) {
    if (hasCred(id)) { println "credential ${id}: exists, skipped"; return }
    SystemCredentialsProvider.instance.store.addCredentials(Domain.global(),
        new BasicSSHUserPrivateKey(CredentialsScope.GLOBAL, id, user,
            new BasicSSHUserPrivateKey.DirectEntryPrivateKeySource(key), '', desc))
    println "credential ${id}: added"
}

void addNode(String name, String host, int executors, String labels, String dir, String credId, String javaPath) {
    if (Jenkins.get().getNode(name)) { println "node ${name}: exists, skipped"; return }
    def l = new SSHLauncher(host, 22, credId)
    l.javaPath = javaPath
    l.sshHostKeyVerificationStrategy = new ManuallyTrustedKeyVerificationStrategy(false)
    l.maxNumRetries = 10           // fast reconnects; after that the retention strategy keeps retrying
    l.retryWaitTime = 15
    l.launchTimeoutSeconds = 60
    def n = new DumbSlave(name, dir, l)
    n.numExecutors = executors
    n.labelString = labels
    n.mode = Node.Mode.NORMAL
    n.retentionStrategy = new RetentionStrategy.Always()   // keep online as much as possible
    Jenkins.get().addNode(n)
    println "node ${name}: added (${host}, ${executors} executors)"
}
EOF
}

# groovy_node NAME HOST EXECUTORS LABELS DIR — one addNode() call
groovy_node() {
    printf "addNode(d('%s'), d('%s'), %d, d('%s'), d('%s'), '%s', '%s')\n" \
        "$(b64 "$1")" "$(b64 "$2")" "$3" "$(b64 "$4")" "$(b64 "$5")" "$AGENT_CRED" "$WORKER_JAVA"
}

# First-boot script. Writes .bootstrap/done (or .bootstrap/failed) so the shell side knows the result.
groovy_firstboot() {
    groovy_lib
    cat <<EOF

def j = Jenkins.get()
def boot = new File(j.rootDir, '.bootstrap')
try {
    // security: own user database, no sign-up; logged-in users = full control, anonymous = nothing
    def realm = j.securityRealm instanceof HudsonPrivateSecurityRealm ? j.securityRealm : new HudsonPrivateSecurityRealm(false)
    if (realm.getUser(d('$(b64 "$ADMIN_USER")')) == null) realm.createAccount(d('$(b64 "$ADMIN_USER")'), d('$(b64 "$ADMIN_PASS")'))
    j.securityRealm = realm
    def authz = new FullControlOnceLoggedInAuthorizationStrategy()
    authz.allowAnonymousRead = false
    j.authorizationStrategy = authz
    j.numExecutors = $BUILTIN_EXECUTORS
    j.save()

    def loc = JenkinsLocationConfiguration.get()
    loc.url = d('$(b64 "$JENKINS_URL")')
    loc.save()

    // git: verify hosts against ~/.ssh/known_hosts (controller and each agent)
    def git = GitHostKeyVerificationConfiguration.get()
    git.sshHostKeyVerificationStrategy = new KnownHostsFileVerificationStrategy()
    git.save()

    addKey('$GITHUB_CRED', 'git', d('$(b64 "$(cat "$BOOT/github_ed25519")")'), 'GitHub deploy key ($CONTROLLER_NAME)')
EOF
    [[ -f $BOOT/agent_ed25519 ]] &&
        echo "    addKey('$AGENT_CRED', 'jenkins', d('$(b64 "$(cat "$BOOT/agent_ed25519")")'), 'SSH agents ($CONTROLLER_NAME)')"
    local w n h e l f
    for w in "${WORKERS[@]}"; do
        IFS='|' read -r n h e l f <<< "$w"
        echo "    $(groovy_node "$n" "$h" "$e" "$l" "$f")"
    done
    cat <<'EOF'

    // --- settings from the dump (jenkins-dump.sh) go here ---

    new File(boot, 'done').text = 'ok'
    println 'bootstrap: done'
} catch (Throwable e) {
    new File(boot, 'failed').text = e.toString()
    throw e
}
EOF
}

############################################################# QUESTIONS
ask_worker() {  # appends "name|host|executors|labels|dir" to WORKERS
    local n h e l f w
    echo "--- Worker $(( ${#WORKERS[@]} + 1 ))"
    while :; do
        ask n "  Name" "worker$(( ${#WORKERS[@]} + 1 ))" "$RE_NAME"
        for w in "${WORKERS[@]}"; do [[ ${w%%|*} == "$n" ]] && { warn "Name already used"; continue 2; }; done
        break
    done
    ask h "  IP (or hostname)" "" "$RE_HOST"
    ask e "  Executors" 3 "$RE_INT"
    ask l "  Labels (space separated)" "linux" "$RE_LABELS"
    ask f "  Agent folder" "/home/jenkins/agent-$CONTROLLER_NAME" "$RE_DIR"
    WORKERS+=("$n|$h|$e|$l|$f")
}

worker_command() {  # worker_command DIR
    echo "  bash jenkins-worker.sh --java $JAVA_MAJOR --key '$(cat "$STACK/keys/agent_ed25519.pub")' --dir $1"
}

############################################################# MODE 1 / 2
install_controller() {
    ask STACK "Stack path" "$DEFAULT_STACK" '^/.+'
    STACK=${STACK%/}
    HOME_DIR=$STACK/jenkins_home
    BOOT=$HOME_DIR/.bootstrap
    [[ -d $HOME_DIR && -n $(ls -A "$HOME_DIR") ]] && die "$HOME_DIR is not empty — refusing (fresh install only)"
    ask CONTROLLER_NAME "Controller name (compose project + container)" "$(basename "$STACK")" '^[a-z0-9][a-z0-9_-]*$'
    ask BIND "Bind IP:port" "10.0.20.10:8080" '^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$'
    BIND_IP=${BIND%:*} HTTP_PORT=${BIND##*:}
    ask JENKINS_URL "Jenkins HTTPS URL (Caddy/NPM)" "https://$CONTROLLER_NAME.example.com/" '^https?://[^ ]+$'
    [[ $JENKINS_URL == */ ]] || JENKINS_URL+=/
    ask ADMIN_USER "Admin user" "admin" "$RE_NAME"
    ask_pass ADMIN_PASS "Admin password" confirm
    ask TZ_NAME "Timezone" "Europe/Warsaw" '^[A-Za-z0-9_+/-]+$'
    [[ ! -d /usr/share/zoneinfo || -f /usr/share/zoneinfo/$TZ_NAME ]] || warn "Unknown timezone $TZ_NAME on this host"
    ask TAG "Image tag (jenkins/jenkins)" "$DEFAULT_TAG" '^[A-Za-z0-9._-]+-jdk[0-9]+$'
    [[ $TAG == *lts* ]] || warn "Tag is not an LTS tag"
    java_from_tag "$TAG"
    ask EXTRA_PLUGINS "Extra plugins (space separated, name or name:version)" "" '^[A-Za-z0-9._:, -]*$'
    GITHUB_CHECK=n; yesno "Live GitHub check after start (needs the deploy key added)?" n && GITHUB_CHECK=y

    WORKERS=()
    AGENT_KEY=n
    if [[ $MODE == 1 ]]; then
        warn "Builds on the built-in node run with the controller's file access (incl. secrets)."
        ask BUILTIN_EXECUTORS "Built-in node executors" 2 "$RE_INT"
        yesno "Create the agent SSH key now (for workers added later with mode 3)?" n && AGENT_KEY=y
    else
        BUILTIN_EXECUTORS=0
        AGENT_KEY=y
        ask_worker
        while yesno "Add another worker?" n; do ask_worker; done
    fi

    echo
    echo "Stack:      $STACK   (container $CONTROLLER_NAME, jenkins/jenkins:$TAG, workers Java $JAVA_MAJOR)"
    echo "Listen:     http://$BIND_IP:$HTTP_PORT  ->  $JENKINS_URL"
    echo "Admin:      $ADMIN_USER    Timezone: $TZ_NAME    Built-in executors: $BUILTIN_EXECUTORS"
    echo "Plugins:    $BASE_PLUGINS ${EXTRA_PLUGINS//,/ }"
    local w n h f; for w in "${WORKERS[@]}"; do echo "Worker:     ${w//|/  }"; done
    yesno "Proceed?" y || die "Aborted"

    # 1. stack folder
    command -v docker >/dev/null && docker compose version >/dev/null 2>&1 || die "docker + compose plugin required"
    install -d -m 755 "$STACK" "$STACK/keys"
    install -d -m 750 "$HOME_DIR"
    cat > "$STACK/.env" <<EOF
COMPOSE_PROJECT_NAME=$CONTROLLER_NAME
JENKINS_TAG=$TAG
BIND_IP=$BIND_IP
HTTP_PORT=$HTTP_PORT
TZ=$TZ_NAME
JENKINS_URL=$JENKINS_URL
ADMIN_USER=$ADMIN_USER
EOF
    cat > "$STACK/compose.yaml" <<'EOF'
# Jenkins controller — generated by jenkins-controller.sh. HTTPS via Caddy/NPM, agents via SSH (no port 50000).
services:
  jenkins:
    image: jenkins/jenkins:${JENKINS_TAG}
    container_name: ${COMPOSE_PROJECT_NAME}
    restart: unless-stopped
    stop_grace_period: 60s
    environment:
      TZ: ${TZ}
      # slaveAgentPort=-1: no inbound TCP agent listener (initial value, can be changed in the GUI)
      JAVA_OPTS: >-
        -Djenkins.install.runSetupWizard=false
        -Duser.timezone=${TZ}
        -Djenkins.model.Jenkins.slaveAgentPort=-1
    ports:
      - "${BIND_IP}:${HTTP_PORT}:8080"
    volumes:
      - ./jenkins_home:/var/jenkins_home
EOF
    printf '%s\n' $BASE_PLUGINS ${EXTRA_PLUGINS//,/ } > "$STACK/plugins.txt"
    chown -R 1000:1000 "$HOME_DIR"
    ok "Stack written: $STACK"

    # Secrets live in .bootstrap until cleanup — removed on any exit from here on
    trap cleanup_bootstrap EXIT
    install -d -m 700 -o 1000 -g 1000 "$BOOT" "$HOME_DIR/init.groovy.d" "$HOME_DIR/.ssh"

    # 2. plugins, before the first start
    info "Pulling image and downloading plugins..."
    dc pull -q
    local log; log=$(mktemp)
    if ! dc run --rm --no-deps -T --entrypoint jenkins-plugin-cli -v "$STACK/plugins.txt:/tmp/plugins.txt:ro" \
            jenkins --plugin-file /tmp/plugins.txt --plugin-download-directory /var/jenkins_home/plugins >"$log" 2>&1; then
        tail -20 "$log" >&2; rm -f "$log"; die "Plugin download failed"
    fi
    rm -f "$log"
    rm -rf "$HOME_DIR/.cache/jenkins-plugin-management-cli"
    ok "Plugins downloaded: $(find "$HOME_DIR/plugins" -maxdepth 1 -name '*.jpi' | wc -l)"

    # 3. keys
    ssh-keygen -q -t ed25519 -N '' -C "jenkins-$CONTROLLER_NAME-github" -f "$BOOT/github_ed25519"
    cp "$BOOT/github_ed25519.pub" "$STACK/keys/"
    if [[ $AGENT_KEY == y ]]; then
        ssh-keygen -q -t ed25519 -N '' -C "jenkins-$CONTROLLER_NAME-agent" -f "$BOOT/agent_ed25519"
        cp "$BOOT/agent_ed25519.pub" "$STACK/keys/"
    fi
    ok "Keys generated (public keys in $STACK/keys)"

    # 4. github.com host keys for the controller (HOME=/var/jenkins_home in the image)
    github_known_hosts > "$HOME_DIR/.ssh/known_hosts"
    ok "github.com added to jenkins_home/.ssh/known_hosts (fingerprints verified against api.github.com/meta)"

    # 5. first-boot Groovy
    groovy_firstboot > "$HOME_DIR/init.groovy.d/10-bootstrap.groovy"
    chown -R 1000:1000 "$HOME_DIR"
    chmod 600 "$HOME_DIR/init.groovy.d/10-bootstrap.groovy" "$BOOT"/*

    # 6. start + wait
    info "Starting Jenkins (first boot can take a few minutes)..."
    dc up -d
    wait_for_boot
    ok "Jenkins is up: http://$BIND_IP:$HTTP_PORT (initial config applied)"

    # GitHub check needs the private key, so it runs before cleanup
    echo
    echo "GitHub deploy key — add to the repo as a read-only deploy key:"
    echo "  $(cat "$STACK/keys/github_ed25519.pub")"
    [[ $GITHUB_CHECK == y ]] && github_check

    # 7. cleanup (also done by the EXIT trap)
    cleanup_bootstrap
    trap - EXIT
    ok "Removed init.groovy.d/*, private keys and the admin password from disk"

    # 8. next steps
    echo
    if (( ${#WORKERS[@]} )); then
        echo "Run on each worker (fresh Debian 13, as root) — before or after this, the agent connects by itself:"
        for w in "${WORKERS[@]}"; do
            IFS='|' read -r n h _ _ f <<< "$w"
            echo "  # $n ($h)"
            worker_command "$f"
        done
    elif [[ $AGENT_KEY == y ]]; then
        echo "Workers later: run this script in mode 3, it prints the worker command."
    fi
    echo
    echo "Next: Caddy/NPM route ${JENKINS_URL} -> http://$BIND_IP:$HTTP_PORT, then create the jobs"
    echo "      (New Item -> Pipeline -> Pipeline script from SCM, credential '$GITHUB_CRED')."
    echo "Public keys: $STACK/keys/   Logs: docker compose --project-directory $STACK logs -f"
}

cleanup_bootstrap() {
    [[ -n ${HOME_DIR:-} ]] || return 0
    rm -rf "$BOOT" "$HOME_DIR"/init.groovy.d/*
}

wait_for_boot() {
    local t=0 code
    while (( t < BOOT_TIMEOUT )); do
        [[ -f $BOOT/failed ]] && { dc logs --tail 40 >&2; die "First-boot Groovy failed: $(cat "$BOOT/failed")"; }
        [[ $(docker inspect -f '{{.State.Running}}' "$CONTROLLER_NAME" 2>/dev/null) == true ]] \
            || { dc logs --tail 40 >&2; die "Container is not running"; }
        if dc logs 2>&1 | grep -q 'init.groovy.d.*\(Failed\|Exception\|Error\)\|Failed to run script'; then
            dc logs --tail 40 >&2; die "First-boot Groovy failed (see log above)"
        fi
        if [[ -f $BOOT/done ]]; then
            code=$(curl -s -o /dev/null -w '%{http_code}' "http://$(local_ip):$HTTP_PORT/login" || true)
            [[ $code == 200 ]] && return 0
        fi
        sleep 5; (( t += 5 ))
    done
    dc logs --tail 40 >&2
    die "Jenkins did not come up within ${BOOT_TIMEOUT}s"
}

local_ip() { [[ $BIND_IP == 0.0.0.0 ]] && echo 127.0.0.1 || echo "$BIND_IP"; }

github_check() {
    local out
    while :; do
        read -rp "Press Enter once the deploy key is added (s = skip): " out
        [[ $out == s ]] && { warn "GitHub check skipped"; return; }
        out=$(dc exec -T jenkins ssh -i /var/jenkins_home/.bootstrap/github_ed25519 -o IdentitiesOnly=yes \
              -o BatchMode=yes -T git@github.com 2>&1 || true)
        if grep -q 'successfully authenticated' <<< "$out"; then
            ok "GitHub: $(grep -o 'Hi [^!]*' <<< "$out" | head -1) — key and controller known_hosts work"
            return
        fi
        warn "GitHub check failed: $out"
    done
}

# Prints github.com known_hosts lines from ssh-keyscan, verified against GitHub's published fingerprints
github_known_hosts() {
    local meta scan line fp out=""
    meta=$(curl -fsS --max-time 20 https://api.github.com/meta) || die "Cannot fetch https://api.github.com/meta"
    scan=$(ssh-keyscan -T 10 -t ed25519,ecdsa,rsa github.com 2>/dev/null) || true
    [[ -n $scan ]] || die "ssh-keyscan github.com returned nothing"
    while read -r line; do
        [[ $line == "github.com "* ]] || continue
        fp=$(ssh-keygen -lf - <<< "$line" | awk '{print $2}')
        grep -qF "\"${fp#SHA256:}\"" <<< "$meta" || die "github.com host key $fp does not match GitHub's published fingerprints"
        out+="$line"$'\n'
    done <<< "$scan"
    printf '%s' "$out"
}

############################################################# MODE 3
# jenkins_script FILE — run Groovy on the running controller via /scriptText (password + crumb + session)
jenkins_script() {
    local crumb field
    crumb=$(curl -fsS -K "$TMP/curl.cfg" -c "$TMP/jar" -b "$TMP/jar" "$BASE/crumbIssuer/api/json") \
        || die "Login to $BASE failed (wrong user/password?)"
    field=$(sed -n 's/.*"crumbRequestField":"\([^"]*\)".*/\1/p' <<< "$crumb")
    crumb=$(sed -n 's/.*"crumb":"\([^"]*\)".*/\1/p' <<< "$crumb")
    curl -fsS -K "$TMP/curl.cfg" -c "$TMP/jar" -b "$TMP/jar" -H "$field: $crumb" \
        --data-urlencode "script@$1" "$BASE/scriptText"
}

add_worker() {
    ask STACK "Stack path of the existing controller" "$DEFAULT_STACK" '^/.+'
    STACK=${STACK%/}
    [[ -f $STACK/.env ]] || die "$STACK/.env not found"
    CONTROLLER_NAME=$(env_get COMPOSE_PROJECT_NAME)
    BIND_IP=$(env_get BIND_IP) HTTP_PORT=$(env_get HTTP_PORT)
    java_from_tag "$(env_get JENKINS_TAG)"
    BASE="http://$(local_ip):$HTTP_PORT"
    ask ADMIN_USER "Admin user" "$(env_get ADMIN_USER)" "$RE_NAME"
    ask_pass ADMIN_PASS "Admin password (not stored)"

    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
    local esc="${ADMIN_USER}:${ADMIN_PASS}"
    esc=${esc//\\/\\\\}; esc=${esc//\"/\\\"}
    printf 'user = "%s"\n' "$esc" > "$TMP/curl.cfg"
    echo 'println "builtin=" + Jenkins.get().numExecutors' > "$TMP/q.groovy"
    local builtin
    builtin=$(jenkins_script "$TMP/q.groovy" | sed -n 's/^builtin=//p')
    [[ $builtin =~ $RE_INT ]] || die "Unexpected answer from $BASE/scriptText"
    ok "Logged in to $BASE (built-in executors: $builtin)"

    WORKERS=()
    ask_worker
    while yesno "Add another worker?" n; do ask_worker; done
    local zero=n
    (( builtin > 0 )) && yesno "Built-in node has $builtin executors — set to 0 (builds only on workers)?" y && zero=y

    # Agent key: reuse the existing credential; create one only if the controller never had it (mode 1)
    { groovy_lib; echo; } > "$TMP/s.groovy"
    if [[ ! -f $STACK/keys/agent_ed25519.pub ]]; then
        info "No agent key yet — creating credential '$AGENT_CRED'"
        ssh-keygen -q -t ed25519 -N '' -C "jenkins-$CONTROLLER_NAME-agent" -f "$TMP/agent_ed25519"
        echo "if (hasCred('$AGENT_CRED')) throw new Exception('credential $AGENT_CRED exists but keys/agent_ed25519.pub is missing')" >> "$TMP/s.groovy"
        echo "addKey('$AGENT_CRED', 'jenkins', d('$(b64 "$(cat "$TMP/agent_ed25519")")'), 'SSH agents ($CONTROLLER_NAME)')" >> "$TMP/s.groovy"
        NEW_PUB="$TMP/agent_ed25519.pub"
    else
        echo "if (!hasCred('$AGENT_CRED')) throw new Exception('credential $AGENT_CRED not found')" >> "$TMP/s.groovy"
    fi
    local w n h e l f
    for w in "${WORKERS[@]}"; do
        IFS='|' read -r n h e l f <<< "$w"
        groovy_node "$n" "$h" "$e" "$l" "$f" >> "$TMP/s.groovy"
    done
    [[ $zero == y ]] && echo 'Jenkins.get().numExecutors = 0; Jenkins.get().save(); println "built-in executors: 0"' >> "$TMP/s.groovy"
    echo 'println "RESULT: ok"' >> "$TMP/s.groovy"

    local out; out=$(jenkins_script "$TMP/s.groovy")
    sed 's/^/    /' <<< "$out"
    grep -q '^RESULT: ok' <<< "$out" || die "Groovy on the controller failed (output above)"
    [[ -n ${NEW_PUB:-} ]] && cp "$NEW_PUB" "$STACK/keys/agent_ed25519.pub"   # private key goes with $TMP
    ok "Done (no restart needed)"

    echo
    echo "Run on each new worker (fresh Debian 13, as root):"
    for w in "${WORKERS[@]}"; do
        IFS='|' read -r n h _ _ f <<< "$w"
        echo "  # $n ($h)"
        worker_command "$f"
    done
}

############################################################# MAIN
[[ $EUID -eq 0 ]] || die "Run as root"
for c in docker curl ssh-keygen ssh-keyscan base64; do command -v "$c" >/dev/null || die "$c not found"; done

cat <<'EOF'
Jenkins controller (Docker Compose) with SSH build agents
  1) Controller only (builds on the built-in node)
  2) Controller + worker(s) (built-in node 0 executors)
  3) Add worker(s) to an existing controller (no restart)
Order: controller -> worker (jenkins-worker.sh, before or after) -> Caddy/NPM route -> create jobs
EOF
ask MODE "Mode" 2 '^[123]$'
case $MODE in
    1|2) install_controller ;;
    3)   add_worker ;;
esac
