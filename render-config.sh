#!/bin/bash
# Renders /etc/shibboleth/shibboleth2.xml and console.logger from the templates
# and the environment. docker-entrypoint.sh runs it on every start; tests/run.sh
# runs it on its own to check the output without a database or a running shibd.
#
# Template markers (shibboleth2.xml-template and console.logger-template),
# applied before envsubst:
#   ##IF_<FLAG>##<line>  the line is kept (marker removed) only when FLAG is on:
#                        ODBC or MEMORY (SHIBD_STORAGE), and METADATA_URL or
#                        METADATA_FILE (SHIBBOLETH_IDP_METADATA_FILE)
#   ##STORAGE_ID##       id of the StorageService the caches use (db or mem)
# Only fixed strings go through these sed expressions; environment values only
# go through envsubst, so passwords with sed metacharacters are safe.
set -e -o pipefail

die() {
    echo "ERROR: $*" >&2
    exit 1
}

SHIBD_STORAGE=${SHIBD_STORAGE:-odbc}
export SHIBBOLETH_HANDLER_SSL=${SHIBBOLETH_HANDLER_SSL:-false}

case "$SHIBD_STORAGE" in
    odbc)   storage_flag=IF_ODBC;   storage_id=db ;;
    memory) storage_flag=IF_MEMORY; storage_id=mem ;;
    *) die "SHIBD_STORAGE must be \"odbc\" or \"memory\", got \"$SHIBD_STORAGE\"" ;;
esac

case "$SHIBBOLETH_HANDLER_SSL" in
    true|false) ;;
    *) die "SHIBBOLETH_HANDLER_SSL must be \"true\" or \"false\", got \"$SHIBBOLETH_HANDLER_SSL\"" ;;
esac

# Memory mode only: where a login with a lost target lands (ApplicationDefaults
# homeURL). "/" is what the SP does without one. It lands in an XML attribute.
if [ "$SHIBD_STORAGE" = memory ]; then
    export SHIBBOLETH_HOME_URL=${SHIBBOLETH_HOME_URL:-/}
    [[ "$SHIBBOLETH_HOME_URL" =~ ^(/|https://)[A-Za-z0-9._~/%:?=+-]*$ ]] ||
        die "SHIBBOLETH_HOME_URL must be a path starting with / or an https:// URL (letters, digits and . _ ~ / % : ? = + - only), got \"$SHIBBOLETH_HOME_URL\""
fi

# The path lands in an XML attribute, so keep it to plain path characters.
if [ -z "$SHIBBOLETH_IDP_METADATA_FILE" ]; then
    metadata_flag=IF_METADATA_URL
elif [[ "$SHIBBOLETH_IDP_METADATA_FILE" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    metadata_flag=IF_METADATA_FILE
    # The file's metadata is filtered down to this one entity (an XML text node).
    [[ "$SHIBBOLETH_IDP_ENTITY_ID" =~ ^[^[:space:]\<\>\&\"\']+$ ]] ||
        die "SHIBBOLETH_IDP_ENTITY_ID must be set, with no spaces, quotes, < > or &, when SHIBBOLETH_IDP_METADATA_FILE is"
else
    die "SHIBBOLETH_IDP_METADATA_FILE may only contain letters, digits and . _ - /"
fi

if [ -z "$SHIBD_ATTRIBUTE_MAP_URL" ]; then
    ATTRIBUTE_EXTRACTOR='<AttributeExtractor type="XML" validate="true" reloadChanges="false" path="attribute-map.xml"/>'
else
    ATTRIBUTE_EXTRACTOR="<AttributeExtractor type=\"XML\" validate=\"true\" reloadChanges=\"false\" url=\"${SHIBD_ATTRIBUTE_MAP_URL}\" backingFilePath=\"attribute-map.xml\"/>"
fi
# apply_markers TEMPLATE: the template with the markers above applied.
apply_markers() {
    sed -e "s/^##${storage_flag}##//" \
        -e "s/^##${metadata_flag}##//" \
        -e '/^##IF_[A-Z_]*##/d' \
        -e "s/##STORAGE_ID##/${storage_id}/g" \
        "$1"
}
apply_markers /etc/shibboleth/shibboleth2.xml-template | envsubst > /etc/shibboleth/shibboleth2.xml
apply_markers /etc/shibboleth/console.logger-template | envsubst > /etc/shibboleth/console.logger
sed -i "s|##ATTRIBUTE_EXTRACTOR##|$ATTRIBUTE_EXTRACTOR|" /etc/shibboleth/shibboleth2.xml
