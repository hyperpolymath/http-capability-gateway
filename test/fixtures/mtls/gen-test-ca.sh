#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Regenerate the mTLS test fixtures used by test/mtls_test.exs.
#
# THIS IS A TEST CA. The keys in this directory are intentionally committed
# so the suite needs no key material at runtime. They MUST NEVER be used for
# anything other than the gateway test suite. They chain to a throwaway root
# that is trusted by nothing in production.
#
# Subjects are forced to UTF8String (string_mask=utf8only) because the
# gateway's extract_subject_fields/1 only matches {:utf8String, value} RDNs.
#
# Generated artefacts:
#   ca.crt / ca.key                 -- the test root CA
#   server.crt / server.key         -- the gateway's own TLS server cert
#   client-internal.crt/.key        -- client cert, OU="Internal Services"
#   client-auth.crt/.key            -- client cert, ordinary OU (authenticated)
#   rogue-ca.crt / rogue-ca.key     -- an unrelated CA (not the trust root)
#   client-rogue.crt/.key           -- client signed by rogue-ca (must NOT verify)
set -euo pipefail
cd "$(dirname "$0")"

DAYS=3650
SUBJ_BASE="/O=BoJ Test Estate"

cfg() { # $1=cn $2=ou
  cat <<EOF
[req]
distinguished_name = dn
string_mask = utf8only
prompt = no
[dn]
O = BoJ Test Estate
OU = ${2}
CN = ${1}
EOF
}

gen_ca() { # $1=prefix $2=cn
  openssl genrsa -out "${1}.key" 2048 2>/dev/null
  openssl req -x509 -new -key "${1}.key" -days "$DAYS" -utf8 \
    -subj "${SUBJ_BASE}/CN=${2}" -out "${1}.crt"
}

gen_leaf() { # $1=prefix $2=cn $3=ou $4=ca-prefix
  openssl genrsa -out "${1}.key" 2048 2>/dev/null
  openssl req -new -key "${1}.key" -utf8 -config <(cfg "$2" "$3") -out "${1}.csr"
  openssl x509 -req -in "${1}.csr" -CA "${4}.crt" -CAkey "${4}.key" \
    -CAcreateserial -days "$DAYS" -out "${1}.crt" 2>/dev/null
  rm -f "${1}.csr"
}

gen_ca   ca       "BoJ Test Root CA"
gen_ca   rogue-ca "Rogue Untrusted CA"
gen_leaf server          "gateway.test.local"  "Gateway"           ca
gen_leaf client-internal "internal-svc"        "Internal Services" ca
gen_leaf client-auth     "regular-client"      "Application"        ca
gen_leaf client-rogue    "attacker"            "Internal Services" rogue-ca

rm -f ca.srl rogue-ca.srl
echo "Test mTLS fixtures regenerated in $(pwd)"
