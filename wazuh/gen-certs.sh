#!/bin/sh
# Creates the Wazuh lab certificates with openssl, offline.
# Same file names and subject DNs as wazuh-certs-tool, so the stock Wazuh configs work.
# Runs inside the wazuh-certs-generator image (it ships openssl); see lab.sh.
set -eu
D=/certificates
SUBJ="/OU=Wazuh/O=Wazuh/L=California/C=US"
cd "$D"

openssl genrsa -out root-ca.key 2048 2>/dev/null
openssl req -x509 -new -key root-ca.key -sha256 -days 3650 -out root-ca.pem \
  -subj "/CN=Wazuh lab root CA$SUBJ" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"
cp root-ca.pem root-ca-manager.pem

issue() {   # issue <file-prefix> <CN>
  openssl genrsa -out "$1-key.pem" 2048 2>/dev/null
  openssl req -new -key "$1-key.pem" -out "$1.csr" -subj "/CN=$2$SUBJ"
  cat > "$1.ext" <<EXT
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,nonRepudiation,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=DNS:$2,DNS:localhost,IP:127.0.0.1
EXT
  openssl x509 -req -in "$1.csr" -CA root-ca.pem -CAkey root-ca.key -CAcreateserial \
    -out "$1.pem" -days 825 -sha256 -extfile "$1.ext" 2>/dev/null
  rm -f "$1.csr" "$1.ext"
}

issue admin admin
issue wazuh.indexer wazuh.indexer
issue wazuh.manager wazuh.manager
issue wazuh.dashboard wazuh.dashboard
rm -f root-ca.srl
chmod 644 ./*.pem ./*.key     # lab only: containers run as different users
ls -1
