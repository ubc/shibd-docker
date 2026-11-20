#!/bin/bash
# Checks SHIBBOLETH_IDP_METADATA_FILE: it exists, shibd can read it, it is
# well-formed XML, and it has an EntityDescriptor whose entityID is exactly
# SHIBBOLETH_IDP_ENTITY_ID (the one entity the Include filter keeps). Without
# that, shibd starts anyway, logs CRIT, and every login fails. On a failure it
# prints one line, with the path and the entityID but nothing from the file,
# and exits 1.
#
# Arguments: the command the container runs, as docker-entrypoint.sh gets it
# (no arguments: the image's CMD, shibd -F -u shibd). When that is shibd with
# -u (and -g) and this runs as root, the file is read as that user (and group),
# as shibd reads it after dropping root. docker-entrypoint.sh runs it before
# starting shibd. After changing the file, check it in the running container:
#   docker exec <container> /check-idp-metadata.sh <its command>
set -e -o pipefail

file=$SHIBBOLETH_IDP_METADATA_FILE
entity_id=$SHIBBOLETH_IDP_ENTITY_ID
md_ns=urn:oasis:names:tc:SAML:2.0:metadata

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

# render-config.sh allows no quotes in the entityID, so it can sit in an XPath
# string; check again for a run by hand.
[ -n "$file" ] && [ -n "$entity_id" ] && [[ "$entity_id" != *\'* ]] ||
    fail "SHIBBOLETH_IDP_METADATA_FILE and SHIBBOLETH_IDP_ENTITY_ID must be set, the entityID without '"

[ $# -gt 0 ] || set -- shibd -F -u shibd
as_shibd=()
who="user $(id -un)"
if [ "$1" = shibd ] && [ "$(id -u)" = 0 ]; then
    user='' group='' prev=''
    for arg in "$@"; do
        case "$prev" in
            -u) user=$arg ;;
            -g) group=$arg ;;
        esac
        prev=$arg
    done
    # shibd -u keeps root's group unless -g is given, and takes on the user's
    # supplementary groups; so does this.
    if [ -n "$user" ]; then
        as_shibd=(setpriv --reuid="$user" ${group:+"--regid=$group"} --init-groups)
        who="user $user, group ${group:-root}"
        "${as_shibd[@]}" true || fail "can't switch to $who to read SHIBBOLETH_IDP_METADATA_FILE"
    fi
fi

problem() { fail "SHIBBOLETH_IDP_METADATA_FILE $file $*"; }
expected="(expected an EntityDescriptor with entityID=\"$entity_id\")"

[ -e "$file" ] || problem "is missing $expected"
# Reads a byte rather than asking access(2), which some mounts answer wrongly.
"${as_shibd[@]}" head -c 1 "$file" > /dev/null 2>&1 ||
    problem "is not readable by $who $expected"

# local-name() and namespace-uri(): any prefix for the metadata namespace.
xpath="count(//*[local-name()='EntityDescriptor' and namespace-uri()='$md_ns' and @entityID='$entity_id'])"
# xmllint's messages quote the file, so they are dropped.
count=$("${as_shibd[@]}" xmllint --nonet --xpath "$xpath" "$file" 2> /dev/null) ||
    problem "is not well-formed XML $expected"
[ "$count" != 0 ] ||
    problem "has no EntityDescriptor with entityID=\"$entity_id\" (SHIBBOLETH_IDP_ENTITY_ID)"
