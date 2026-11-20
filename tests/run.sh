#!/bin/bash
# Tests for the shibd image. Run from anywhere:  tests/run.sh
#
# Needs docker and git; shellcheck for the lint step. Works with the bash 3.2
# that macOS ships. Settings (environment):
#   IMAGE=lthub/shibd:memory-test  image to build and test
#   PLATFORM=linux/amd64           build and run for that platform (default: the host's)
#   SKIP_BUILD=1                   test IMAGE as it is
#   BASELINE_REF=<git ref>         the pre-change code for the ODBC comparisons
#                                  (default: the rocky9 commit memory storage was added to)
#   SKIP_ODBC_E2E=1                skip the start-up test against MariaDB
#   UPDATE_GOLDEN=1                rewrite tests/fixtures/expected/ from the current templates
#   SKIP_LAYER_SCAN=1              skip the check that no image layer holds the RPM's keys
#   RUN_ID=shibd-test-<pid>        label and name prefix of the test's containers,
#                                  volumes and networks
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
IMAGE=${IMAGE:-lthub/shibd:memory-test}
BASELINE_REF=${BASELINE_REF:-3309e6958cd3d9421ed81436bc42dd4e4e7e9147}
MARIADB_IMAGE=mariadb:10.11.18
FIXTURES=tests/fixtures
METADATA_PATH=/etc/shibboleth/idp/idp-metadata.xml
# Every container, volume and network gets this label so cleanup finds them.
RUN_ID=${RUN_ID:-shibd-test-$$}
TMP=$(mktemp -d)
failures=0

pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }
skip() { echo "SKIP  $*"; }

# check <description> <command...>: run quietly, show the output only on failure
check() {
    local desc=$1
    shift
    if "$@" > "$TMP/check.log" 2>&1; then
        pass "$desc"
    else
        fail "$desc"
        sed 's/^/      | /' "$TMP/check.log"
    fi
}

cleanup() {
    # xargs -r: GNU and BSD both skip the command when there is nothing to remove.
    # rm -v also removes a container's anonymous volumes: the MariaDB image
    # declares one for /var/lib/mysql, which would otherwise be left behind.
    docker ps -aq --filter "label=$RUN_ID" | xargs -r docker rm -f -v > /dev/null
    docker volume ls -q --filter "label=$RUN_ID" | xargs -r docker volume rm > /dev/null
    docker network ls -q --filter "label=$RUN_ID" | xargs -r docker network rm > /dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT

drun() { docker run ${PLATFORM:+--platform "$PLATFORM"} --label "$RUN_ID" "$@"; }

have_baseline() { git cat-file -e "$BASELINE_REF:docker-entrypoint.sh" 2> /dev/null; }

# --- build -------------------------------------------------------------------

if [ "${SKIP_BUILD:-}" != 1 ]; then
    echo "Building $IMAGE (${PLATFORM:-host platform})..."
    if ! docker build ${PLATFORM:+--platform "$PLATFORM"} -t "$IMAGE" . > "$TMP/build.log" 2>&1; then
        tail -40 "$TMP/build.log"
        echo "FAIL  docker build"
        exit 1
    fi
fi
echo "Testing $IMAGE ($(docker image inspect -f '{{.Os}}/{{.Architecture}}' "$IMAGE"))"

# --- shellcheck --------------------------------------------------------------

# One "SCxxxx|<source line>" per finding, so findings survive line renumbering.
shellcheck_keys() {
    shellcheck -f gcc "$1" | sed -E 's/^[^:]*:([0-9]+):[0-9]+: .*\[(SC[0-9]+)\]$/\1 \2/' |
        while read -r n code; do
            printf '%s|%s\n' "$code" "$(sed -n "${n}p" "$1" | sed -E 's/^[[:space:]]+//')"
        done | sort -u
}

no_new_entrypoint_findings() {
    git show "$BASELINE_REF:docker-entrypoint.sh" > "$TMP/baseline-entrypoint.sh" || return 1
    shellcheck_keys "$TMP/baseline-entrypoint.sh" > "$TMP/sc-old"
    shellcheck_keys docker-entrypoint.sh > "$TMP/sc-new"
    ! comm -23 "$TMP/sc-new" "$TMP/sc-old" | grep .
}

if command -v shellcheck > /dev/null; then
    check "shellcheck: render-config.sh, check-idp-metadata.sh and tests/run.sh are clean" \
        shellcheck render-config.sh check-idp-metadata.sh tests/run.sh
    if have_baseline; then
        check "shellcheck: docker-entrypoint.sh adds no findings to the baseline's" no_new_entrypoint_findings
    else
        skip "shellcheck entrypoint comparison: $BASELINE_REF not in this clone"
    fi
else
    skip "shellcheck not installed"
fi

# --- rendering ---------------------------------------------------------------

# render <out-dir> <env-file> <script> [<dir copied to /baseline>]
# Runs <script> in a fresh container and copies the rendered files out.
render() {
    local out=$1 env_file=$2 script=$3 extra=${4:-} cid status
    cid=$(docker create ${PLATFORM:+--platform "$PLATFORM"} --label "$RUN_ID" \
        --env-file "$env_file" --entrypoint bash "$IMAGE" -c "$script") || return 1
    if [ -n "$extra" ]; then
        docker cp "$extra/." "$cid:/baseline" || return 1
    fi
    docker start -a "$cid"
    status=$?
    mkdir -p "$out"
    if [ "$status" = 0 ]; then
        docker cp "$cid:/etc/shibboleth/shibboleth2.xml" "$out/shibboleth2.xml" &&
            docker cp "$cid:/etc/shibboleth/console.logger" "$out/console.logger" ||
            status=1
    fi
    docker rm "$cid" > /dev/null
    return "$status"
}

render_new() {
    render "$1" "$2" '/render-config.sh && xmllint --noout /etc/shibboleth/shibboleth2.xml'
}

# The original entrypoint's lines up to the ##ATTRIBUTE_EXTRACTOR## sed are its
# whole rendering step; run them against the original templates.
render_baseline() {
    local src=$TMP/baseline-src
    if [ ! -d "$src" ]; then
        mkdir -p "$src"
        git show "$BASELINE_REF:shibboleth2.xml-template" > "$src/shibboleth2.xml-template" &&
            git show "$BASELINE_REF:console.logger-template" > "$src/console.logger-template" &&
            git show "$BASELINE_REF:docker-entrypoint.sh" |
            sed -n '1,/##ATTRIBUTE_EXTRACTOR##/p' > "$src/render.sh" || return 1
        if [ "$(grep -c '^envsubst' "$src/render.sh")" != 2 ] ||
            ! tail -1 "$src/render.sh" | grep -q '^sed -i "s|##ATTRIBUTE_EXTRACTOR##'; then
            echo "unexpected baseline entrypoint layout"
            return 1
        fi
    fi
    render "$1" "$2" 'cp /baseline/*-template /etc/shibboleth/ && bash /baseline/render.sh' "$src"
}

# same_as_baseline <case name> <env file>
same_as_baseline() {
    render_baseline "$TMP/old/$1" "$2" &&
        cmp "$TMP/old/$1/shibboleth2.xml" "$TMP/new/$1/shibboleth2.xml" &&
        cmp "$TMP/old/$1/console.logger" "$TMP/new/$1/console.logger"
}

for env_file in "$FIXTURES"/render/*.env; do
    name=$(basename "$env_file" .env)
    if ! render_new "$TMP/new/$name" "$env_file" > "$TMP/render.log" 2>&1; then
        fail "render $name: renders well-formed XML"
        sed 's/^/      | /' "$TMP/render.log"
        continue
    fi
    pass "render $name: renders well-formed XML"
    if [ "${UPDATE_GOLDEN:-}" = 1 ]; then
        mkdir -p "$FIXTURES/expected/$name"
        cp "$TMP/new/$name/"* "$FIXTURES/expected/$name/"
    fi
    check "render $name: matches $FIXTURES/expected/$name" \
        diff -r "$FIXTURES/expected/$name" "$TMP/new/$name"
    case "$name" in odbc*) ;; *) continue ;; esac
    if have_baseline; then
        check "render $name: byte-identical to the original entrypoint at ${BASELINE_REF:0:7}" \
            same_as_baseline "$name" "$env_file"
    else
        skip "render $name: baseline comparison ($BASELINE_REF not in this clone)"
    fi
done

# --- bad settings stop the container ------------------------------------------

# expect_failure <description> <expected message> <docker run args...>
expect_failure() {
    local desc=$1 message=$2
    shift 2
    if drun --rm "$@" > "$TMP/fail.log" 2>&1; then
        fail "$desc (exited 0)"
    elif grep -qF "$message" "$TMP/fail.log"; then
        pass "$desc"
    else
        fail "$desc (no \"$message\" in output)"
        sed 's/^/      | /' "$TMP/fail.log"
    fi
}

expect_failure "unknown SHIBD_STORAGE exits non-zero" "SHIBD_STORAGE must be" \
    -e SHIBD_STORAGE=redis "$IMAGE" true
expect_failure "unknown SHIBBOLETH_HANDLER_SSL exits non-zero" "SHIBBOLETH_HANDLER_SSL must be" \
    -e SHIBD_STORAGE=memory -e SHIBBOLETH_HANDLER_SSL=yes "$IMAGE" true
expect_failure "unsafe SHIBBOLETH_IDP_METADATA_FILE exits non-zero" "may only contain" \
    -e SHIBD_STORAGE=memory -e 'SHIBBOLETH_IDP_METADATA_FILE=/tmp/a"b.xml' "$IMAGE" true
expect_failure "SHIBBOLETH_IDP_METADATA_FILE without SHIBBOLETH_IDP_ENTITY_ID exits non-zero" \
    "SHIBBOLETH_IDP_ENTITY_ID must be set" \
    -e SHIBD_STORAGE=memory -e SHIBBOLETH_IDP_METADATA_FILE=/nonexistent.xml "$IMAGE" true
expect_failure "unsafe SHIBBOLETH_HOME_URL exits non-zero" "SHIBBOLETH_HOME_URL must be" \
    -e SHIBD_STORAGE=memory -e 'SHIBBOLETH_HOME_URL=javascript:alert(1)' "$IMAGE" true

# rendered_has <description> <string> <docker run args...>: render only, then grep
rendered_has() {
    local desc=$1 string=$2
    shift 2
    # shellcheck disable=SC2016 # $0 is expanded by the container's bash
    check "$desc" drun --rm --entrypoint bash "$@" "$IMAGE" -c \
        '/render-config.sh && grep -F -- "$0" /etc/shibboleth/shibboleth2.xml' "$string"
}
rendered_has "memory: homeURL defaults to / (the SP's own default)" 'homeURL="/">' \
    -e SHIBD_STORAGE=memory
rendered_has "odbc: SHIBBOLETH_HOME_URL is ignored (no homeURL)" 'REMOTE_USER="somerandomname">' \
    -e SHIBBOLETH_HOME_URL=/signed-in

# --- the image ------------------------------------------------------------------

# The shibboleth RPM's %post generates these; a key baked into a public image is
# known to everyone who pulls it. The configuration uses cert/sp-{key,cert}.pem.
RPM_KEYS="sp-signing-key.pem sp-signing-cert.pem sp-encrypt-key.pem sp-encrypt-cert.pem"
# shellcheck disable=SC2016 # $0 and $f are expanded by the container's bash
check "image: no RPM-generated SP key pairs in /etc/shibboleth" \
    drun --rm --entrypoint bash "$IMAGE" -c \
    'cd /etc/shibboleth && for f in $0; do [ ! -e "$f" ] || { echo "$f is in the image"; exit 1; }; done' "$RPM_KEYS"

# Deleting them in a later layer would still ship them, so look inside every layer.
no_layer_has_rpm_keys() {
    local dir=$TMP/image f found=0 read_layers=0
    mkdir -p "$dir" && docker save "$IMAGE" | tar -xf - -C "$dir" || return 1
    while IFS= read -r f; do
        tar -tf "$f" > "$TMP/layer.list" 2> /dev/null || continue
        # The layer with our templates proves the layers could be read at all.
        grep -q 'etc/shibboleth/shibboleth2.xml-template$' "$TMP/layer.list" && read_layers=1
        if grep -E 'etc/shibboleth/sp-(signing|encrypt)-(key|cert)\.pem$' "$TMP/layer.list"; then
            found=1
        fi
    done < <(find "$dir" -type f -size +0)
    rm -rf "$dir"
    [ "$read_layers" = 1 ] || echo "found no readable layer with the templates"
    [ "$read_layers" = 1 ] && [ "$found" = 0 ]
}
if [ "${SKIP_LAYER_SCAN:-}" = 1 ]; then
    skip "image: no layer holds the RPM-generated keys (SKIP_LAYER_SCAN=1)"
else
    check "image: no layer holds the RPM-generated keys" no_layer_has_rpm_keys
fi

# --- running containers --------------------------------------------------------

# A throwaway SP key pair in a volume, owned and readable the way a Kubernetes
# Secret mount with fsGroup = shibd's gid and defaultMode 0440 would be.
make_sp_cert_volume() {
    docker volume create --label "$RUN_ID" "$RUN_ID-cert" > /dev/null &&
        drun --rm -v "$RUN_ID-cert:/cert" --entrypoint bash "$IMAGE" -c '
            /etc/shibboleth/keygen.sh -f -h pages.example.test -y 1 \
                -e https://pages.example.test/shibboleth -o /cert > /dev/null 2>&1
            chown root:shibd /cert/sp-key.pem /cert/sp-cert.pem &&
                chmod 0440 /cert/sp-key.pem /cert/sp-cert.pem'
}

# listening <container> <hex addr:port from /proc/net/tcp>
listening() {
    docker exec "$1" cat /proc/net/tcp | awk -v a="$2" '$2 == a && $4 == "0A" { found = 1 } END { exit !found }'
}

not_listening() { ! listening "$@"; }

# wait_for_listener <container> <hex addr:port> <seconds>
wait_for_listener() {
    local waited=0
    while [ "$waited" -lt "$3" ]; do
        listening "$1" "$2" && return 0
        [ "$(docker inspect -f '{{.State.Running}}' "$1")" = true ] || return 1
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

still_running() { [ "$(docker inspect -f '{{.State.Running}} {{.RestartCount}}' "$1")" = "true 0" ]; }

logs_have() { docker logs "$1" 2>&1 | grep -F -- "$2"; }
logs_lack() { ! docker logs "$1" 2>&1 | grep -Ei -- "$2"; }

xml_has() { grep -qF -- "$2" "$1"; }
xml_lacks() { ! grep -F -- "$2" "$1"; }
# xml_count <file> <string> <n>: <string> appears on exactly <n> lines
xml_count() { [ "$(grep -cF -- "$2" "$1")" = "$3" ]; }

# odbc_tables <db container>: the tables docker-entrypoint.sh creates exist
odbc_tables() {
    [ "$(docker exec "$1" mariadb -umoodle -ppassword moodle -N -e 'SHOW TABLES' |
        sort | tr '\n' ' ')" = "strings texts version " ]
}

# Address:port as /proc/net/tcp prints them (little-endian IPv4, port 1600).
LOOPBACK_1600=0100007F:0640
ANY_1600=00000000:0640

check "SP key pair volume created" make_sp_cert_volume
MOUNTS=(-v "$RUN_ID-cert:/etc/shibboleth/cert:ro" -v "$PWD/$FIXTURES/idp-metadata.xml:$METADATA_PATH:ro")

# Memory mode with the C2 settings; only the IdP is swapped for the fixture's.
grep -v '^SHIBBOLETH_IDP_\(ENTITY_ID\|DISCOVERY_URL\)=' "$FIXTURES/render/memory.env" > "$TMP/memory.env"
printf '%s\n' SHIBBOLETH_IDP_ENTITY_ID=https://idp.example.test \
    SHIBBOLETH_IDP_DISCOVERY_URL=https://idp.example.test >> "$TMP/memory.env"

# shibd -t exits 0 even when, say, the metadata fails to load, so read its output.
config_loadable() {
    drun --rm "$@" shibd -t > "$TMP/shibd-t.log" 2>&1
    cat "$TMP/shibd-t.log"
    grep -q 'overall configuration is loadable' "$TMP/shibd-t.log" &&
        ! grep -Eq ' (ERROR|CRIT|FATAL) ' "$TMP/shibd-t.log"
}

# --network none: memory mode with a metadata file must need nothing outside the pod.
check "memory: shibd -t loads the configuration without errors" \
    config_loadable --network none --env-file "$TMP/memory.env" "${MOUNTS[@]}" "$IMAGE"

mem=$(drun -d --name "$RUN_ID-memory" --network none --env-file "$TMP/memory.env" "${MOUNTS[@]}" "$IMAGE")
if wait_for_listener "$mem" "$LOOPBACK_1600" 60; then
    pass "memory: shibd listens on 127.0.0.1:1600"
    sleep 20
else
    fail "memory: shibd listens on 127.0.0.1:1600"
    docker logs "$mem" 2>&1 | tail -30 | sed 's/^/      | /'
fi
check "memory: container still running 20 s later" still_running "$mem"
check "memory: pgrep -x shibd" docker exec "$mem" pgrep -x shibd
check "memory: shibd runs as the shibd user" docker exec "$mem" pgrep -u shibd -x shibd
# shibd reads the key when it first needs it, after dropping to the shibd user.
check "memory: the shibd user can read the SP key" \
    docker exec --user shibd "$mem" test -r /etc/shibboleth/cert/sp-key.pem
check "memory: not listening on 0.0.0.0:1600" not_listening "$mem" "$ANY_1600"
check "memory: no ODBC or database messages in the logs" logs_lack "$mem" 'odbc|database|mysql|mariadb'
check "memory: no DEBUG lines in the logs" logs_lack "$mem" ' DEBUG '
check "memory: no CRIT or ERROR lines in the logs" logs_lack "$mem" ' (CRIT|ERROR|FATAL) '
check "memory: metadata loaded from the mounted file" logs_have "$mem" "loaded XML resource ($METADATA_PATH)"
# Block-buffered stdout would hold the last lines until 4 KB more or exit.
check "memory: the last start-up line is in the logs while shibd runs (line-buffered)" \
    logs_have "$mem" "listener service starting"

docker exec "$mem" cat /etc/shibboleth/shibboleth2.xml > "$TMP/memory-runtime.xml"
for s in '<StorageService type="Memory" id="mem" cleanupInterval="900"/>' \
    '<SessionCache type="StorageService" StorageService="mem"' \
    '<ReplayCache StorageService="mem"/>' \
    '<ArtifactMap StorageService="mem"' \
    'relayState="ss:mem"' \
    'handlerSSL="true"' \
    'cookieProps="https"' \
    "<MetadataProvider type=\"XML\" validate=\"true\" path=\"$METADATA_PATH\">" \
    '<MetadataFilter type="Include">' \
    '<Include>https://idp.example.test</Include>' \
    'REMOTE_USER="uid"' \
    'homeURL="/signed-in">' \
    '<Logout>Local</Logout>' \
    '<SessionCache type="StorageService" StorageService="mem" cacheAllowance="3600" inprocTimeout="900" cleanupInterval="900"/>' \
    '<TCPListener address="127.0.0.1" port="1600" acl="127.0.0.1"/>' \
    'redirectLimit="exact">' \
    '<LogoutInitiator type="Local" Location="/Logout/Redirect" />' \
    'tranLogFormat="%IDP|%i|%ac|%t|%attr|%b|%E|%S|%SS|%L">'; do
    check "memory XML has $s" xml_has "$TMP/memory-runtime.xml" "$s"
done
for s in 'type="ODBC"' '<Extensions>' 'odbc-store' 'ConnectionString' 'backingFilePath' 'StorageService="db"' \
    'Location="/Logout/Redirect "' '%u|' '|%UA|%a"' 'cacheTimeout=' 'SAML2 Local'; do
    check "memory XML lacks $s" xml_lacks "$TMP/memory-runtime.xml" "$s"
done
docker exec "$mem" cat /etc/shibboleth/console.logger > "$TMP/memory-console.logger"
# Whether a login really lands there (and without a CWL) is checked by the
# CWL Pages E2E suite, which has an IdP.
check "memory console.logger sends login events to the console" \
    xml_has "$TMP/memory-console.logger" 'log4j.category.Shibboleth-TRANSACTION=INFO, console'
check "memory console.logger keeps the session cache at WARN" \
    xml_has "$TMP/memory-console.logger" 'log4j.category.Shibboleth.SessionCache=WARN'
check "memory XML has exactly one MetadataProvider" xml_count "$TMP/memory-runtime.xml" '<MetadataProvider' 1

# What shibd did with that configuration. At INFO the session cache logs session
# IDs (the cookie values) on every login; at start-up it logs "bound to
# StorageService", so no INFO line from it at all means the WARN level took.
check "memory: no INFO lines from Shibboleth.SessionCache (no session IDs)" \
    logs_lack "$mem" ' INFO Shibboleth\.SessionCache '
check "memory: no cacheTimeout deprecation warning" logs_lack "$mem" 'cacheTimeout property'
check "memory: /Logout chains the Local initiator" \
    logs_have "$mem" 'adding LogoutInitiator of type (Local) to chain (/Logout)'
check "memory: no SAML2 logout initiator" logs_lack "$mem" 'LogoutInitiator of type \(SAML2\)'
check "memory: no SingleLogoutService endpoints" logs_lack "$mem" 'adding SingleLogoutService'
check "memory: chown of the read-only cert mount skipped quietly" \
    logs_lack "$mem" 'chown|read-only file system'

# A writable cert directory (no mount: the entrypoint generates a key pair) still
# goes to shibd, as it always did for ODBC deployments.
cert_dir_owner() {
    drun --rm --network none --env-file "$TMP/memory.env" \
        -v "$PWD/$FIXTURES/idp-metadata.xml:$METADATA_PATH:ro" \
        "$IMAGE" stat -c %U:%G /etc/shibboleth/cert 2>&1 | tail -1 | grep -x shibd:shibd
}
check "memory: a writable cert directory is still chowned to shibd" cert_dir_owner

# --- memory mode with a second IdP in the metadata file --------------------------

# mdquery_idp <container> <entityID>: what metadata shibd's config yields for that IdP
mdquery_idp() { docker exec "$1" mdquery -e "$2" -saml2 -idp 2>&1; }
idp_kept() { mdquery_idp "$1" "$2" | grep -F '<IDPSSODescriptor'; }
idp_dropped() { ! idp_kept "$@"; }

two=$(drun -d --name "$RUN_ID-two-idps" --network none --env-file "$TMP/memory.env" \
    -v "$RUN_ID-cert:/etc/shibboleth/cert:ro" \
    -v "$PWD/$FIXTURES/idp-metadata-two-idps.xml:$METADATA_PATH:ro" "$IMAGE")
if wait_for_listener "$two" "$LOOPBACK_1600" 60; then
    pass "two IdPs in the file: shibd starts and listens"
    sleep 5
else
    fail "two IdPs in the file: shibd starts and listens"
    docker logs "$two" 2>&1 | tail -30 | sed 's/^/      | /'
fi
check "two IdPs in the file: container still running" still_running "$two"
check "two IdPs in the file: no CRIT or ERROR lines" logs_lack "$two" ' (CRIT|ERROR|FATAL) '
check "two IdPs in the file: the other IdP is filtered out" \
    logs_have "$two" 'filtering out non-included entity (https://other-idp.example.test)'
check "two IdPs in the file: metadata keeps the configured IdP" idp_kept "$two" https://idp.example.test
check "two IdPs in the file: metadata has no other IdP" idp_dropped "$two" https://other-idp.example.test

# --- the metadata file is checked before shibd starts -----------------------------

# shibd starts without a usable metadata file too, logs CRIT and fails every
# login, so check-idp-metadata.sh stops the container first. The memory
# containers above are the good case.
GOOD_MD=$PWD/$FIXTURES/idp-metadata.xml

# md_rejected <description> <message> <docker run args...>: the memory container
# exits non-zero, before generating a key pair or starting shibd, printing one
# line (none of xmllint's, which quote the file) with <message> and the path.
md_rejected() {
    local desc=$1 message=$2
    shift 2
    if drun --rm --network none --env-file "$TMP/memory.env" "$@" > "$TMP/md.log" 2>&1; then
        fail "$desc (exited 0)"
    elif [ "$(wc -l < "$TMP/md.log")" -eq 1 ] && grep -qF -- "$message" "$TMP/md.log" &&
        grep -qF -- "SHIBBOLETH_IDP_METADATA_FILE $METADATA_PATH " "$TMP/md.log"; then
        pass "$desc"
    else
        fail "$desc (want one line with \"$message\" and $METADATA_PATH)"
        sed 's/^/      | /' "$TMP/md.log"
    fi
}

# md_accepted <description> <docker run args...>: the check passes and the command runs.
md_accepted() {
    local desc=$1
    shift
    check "$desc" drun --rm --network none --env-file "$TMP/memory.env" "$@"
}

# Copies the fixture in as root:root 0440, then runs the entrypoint with the
# command given after it.
# shellcheck disable=SC2016 # expanded by the container's bash
ROOT_ONLY_MD='install -D -m 0440 /fixture.xml "$SHIBBOLETH_IDP_METADATA_FILE" && exec /docker-entrypoint.sh "$@"'

# The fixture with an md: prefix on every metadata element, as many IdPs write it.
sed -e 's#<\(/\{0,1\}\)\([A-Z]\)#<\1md:\2#g' -e 's#xmlns="#xmlns:md="#' "$GOOD_MD" > "$TMP/md-prefixed.xml"
# The fixture without its namespace: the right entityID, but not SAML metadata.
sed 's#xmlns="urn:oasis:names:tc:SAML:2.0:metadata"##' "$GOOD_MD" > "$TMP/md-no-namespace.xml"
# Not well-formed: an end tag that doesn't match.
sed 's#</IDPSSODescriptor>#</IDPSSODescriptorX>#' "$GOOD_MD" > "$TMP/md-malformed.xml"

md_accepted "metadata check: md:-prefixed metadata passes" \
    -v "$TMP/md-prefixed.xml:$METADATA_PATH:ro" "$IMAGE" true
check "metadata check: shibd -t loads that md:-prefixed metadata without errors" \
    config_loadable --network none --env-file "$TMP/memory.env" -v "$RUN_ID-cert:/etc/shibboleth/cert:ro" \
    -v "$TMP/md-prefixed.xml:$METADATA_PATH:ro" "$IMAGE"
md_rejected "metadata check: a missing file stops the container" \
    'is missing (expected an EntityDescriptor with entityID="https://idp.example.test")' "$IMAGE" true
md_rejected "metadata check: metadata for another IdP stops the container" \
    'has no EntityDescriptor with entityID="https://other-idp.example.test"' \
    -e SHIBBOLETH_IDP_ENTITY_ID=https://other-idp.example.test -v "$GOOD_MD:$METADATA_PATH:ro" "$IMAGE" true
md_rejected "metadata check: the entityID must match exactly, not as a prefix" \
    'has no EntityDescriptor with entityID="https://idp.example"' \
    -e SHIBBOLETH_IDP_ENTITY_ID=https://idp.example -v "$GOOD_MD:$METADATA_PATH:ro" "$IMAGE" true
md_rejected "metadata check: an EntityDescriptor outside the metadata namespace doesn't count" \
    'has no EntityDescriptor with entityID="https://idp.example.test"' \
    -v "$TMP/md-no-namespace.xml:$METADATA_PATH:ro" "$IMAGE" true
md_rejected "metadata check: malformed XML stops the container" \
    'is not well-formed XML (expected an EntityDescriptor with entityID="https://idp.example.test")' \
    -v "$TMP/md-malformed.xml:$METADATA_PATH:ro" "$IMAGE" true
# shibd reads the file after dropping root, as the -u user and -g group (root's
# group without -g), so the check does too.
md_rejected "metadata check: a file shibd -u shibd -g shibd can't read stops the container" \
    'is not readable by user shibd, group shibd (expected an EntityDescriptor' \
    -v "$GOOD_MD:/fixture.xml:ro" -v "$RUN_ID-cert:/etc/shibboleth/cert:ro" \
    --entrypoint bash "$IMAGE" -c "$ROOT_ONLY_MD" bash shibd -t -u shibd -g shibd
md_accepted "metadata check: shibd -u shibd (root's group) can read that root:root 0440 file" \
    -v "$GOOD_MD:/fixture.xml:ro" -v "$RUN_ID-cert:/etc/shibboleth/cert:ro" \
    --entrypoint bash "$IMAGE" -c "$ROOT_ONLY_MD" bash shibd -t -u shibd
# The chart's shibd securityContext: root without DAC_OVERRIDE, and only
# SETUID and SETGID, which setpriv needs as much as shibd does.
md_accepted "metadata check: passes with only SETUID and SETGID, as the shibd user and group" \
    --cap-drop ALL --cap-add SETUID --cap-add SETGID --security-opt no-new-privileges \
    -v "$GOOD_MD:$METADATA_PATH:ro" -v "$RUN_ID-cert:/etc/shibboleth/cert:ro" \
    "$IMAGE" shibd -t -u shibd -g shibd
check "metadata check: runs by hand in a running container" docker exec "$mem" /check-idp-metadata.sh

# --- ODBC start-up against MariaDB (backward compatibility) ------------------------

if [ "${SKIP_ODBC_E2E:-}" = 1 ]; then
    skip "odbc: start-up against MariaDB (SKIP_ODBC_E2E=1)"
else
    net=$RUN_ID-net
    docker network create --label "$RUN_ID" "$net" > /dev/null
    docker run -d --label "$RUN_ID" --name "$RUN_ID-db" --network "$net" --network-alias db \
        -e MARIADB_ROOT_PASSWORD=password -e MARIADB_DATABASE=moodle \
        -e MARIADB_USER=moodle -e MARIADB_PASSWORD=password "$MARIADB_IMAGE" > /dev/null
    # The moodle settings, with the IdP metadata (and so the IdP) from the
    # fixture so the test does not depend on reaching the staging IdP.
    { grep -v '^SHIBBOLETH_IDP_ENTITY_ID=' "$FIXTURES/render/odbc.env"
        echo "SHIBBOLETH_IDP_METADATA_FILE=$METADATA_PATH"
        echo "SHIBBOLETH_IDP_ENTITY_ID=https://idp.example.test"; } > "$TMP/odbc.env"
    odbc=$(drun -d --name "$RUN_ID-odbc" --network "$net" --env-file "$TMP/odbc.env" "${MOUNTS[@]}" "$IMAGE")
    if wait_for_listener "$odbc" "$ANY_1600" 120; then
        pass "odbc: shibd listens on 0.0.0.0:1600 after the database came up"
        sleep 20
    else
        fail "odbc: shibd listens on 0.0.0.0:1600 after the database came up"
        docker logs "$odbc" 2>&1 | tail -30 | sed 's/^/      | /'
    fi
    check "odbc: container still running 20 s later" still_running "$odbc"
    check "odbc: shibd runs as the shibd user" docker exec "$odbc" pgrep -u shibd -x shibd
    check "odbc: entrypoint created the storage tables" odbc_tables "$RUN_ID-db"
    check "odbc: shibd loaded the ODBC extension" logs_have "$odbc" odbc-store.so
    check "odbc: no CRIT or ERROR lines in the logs" logs_lack "$odbc" ' (CRIT|ERROR|FATAL) '
fi

echo
if [ "$failures" = 0 ]; then
    echo "All tests passed."
else
    echo "$failures test(s) failed."
    exit 1
fi
